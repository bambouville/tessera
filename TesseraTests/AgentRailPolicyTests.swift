import SwiftUI
import XCTest
import TesseraCore
@testable import Tessera

@MainActor
final class AgentRailPolicyTests: XCTestCase {
    private let hostID = UUID()
    private let sessionID = UUID()

    func testBoardAlwaysOffersNewAgent() {
        let entries = AgentRailPolicy.items(screen: .board, hasSwitcher: true)
        XCTAssertEqual(entries.map(\.item), [.switcher, .newAgent])
        XCTAssertTrue(entries.allSatisfy(\.isEnabled))
        XCTAssertEqual(entries.map(\.priority), [.high, .automatic])
    }

    func testThreadHasContextAndNeverOffersBoardLaunch() {
        let entries = AgentRailPolicy.items(screen: .thread, hasSwitcher: true, hasContext: true)
        XCTAssertEqual(entries.map(\.item), [.switcher, .context])
        XCTAssertTrue(entries.allSatisfy(\.isEnabled))
        XCTAssertEqual(entries.map(\.priority), [.high, .high])
        XCTAssertEqual(AgentRailPolicy.items(screen: .candidate, hasSwitcher: true).map(\.item), [.switcher])
    }

    func testFilesOpenThroughTheAgentsOwnSessionElseAnotherToItsHost() {
        let other = UUID()
        let elsewhere = UUID()
        let binding = makeBinding()
        XCTAssertEqual(AgentRailPolicy.filesSessionID(
            binding: binding, hostID: hostID, connected: [(other, hostID), (sessionID, hostID)]), sessionID)
        XCTAssertEqual(AgentRailPolicy.filesSessionID(
            binding: binding, hostID: hostID, connected: [(elsewhere, UUID()), (other, hostID)]), other)
        XCTAssertEqual(AgentRailPolicy.filesSessionID(
            binding: nil, hostID: hostID, connected: [(other, hostID)]), other)
        // The agent's session on another host never opens this host's Files.
        XCTAssertNil(AgentRailPolicy.filesSessionID(
            binding: binding, hostID: hostID, connected: [(sessionID, UUID()), (elsewhere, nil)]))
        XCTAssertNil(AgentRailPolicy.filesSessionID(binding: binding, hostID: nil, connected: [(sessionID, hostID)]))
    }

    func testUnavailableSwitcherIsDisabledAndOnePaneHasNoContext() {
        let entries = AgentRailPolicy.items(screen: .thread, hasSwitcher: false)
        XCTAssertEqual(entries.map(\.item), [.switcher])
        XCTAssertTrue(entries.allSatisfy { !$0.isEnabled })
    }

    func testStopRequiresWorkingStatusActionsAndInterruptCapability() {
        for status in TesseraAgentCore.AgentStatus.allCases {
            let entries = threadItems(snapshot(status: status))
            XCTAssertEqual(entries.contains { $0.item == .stop }, status == .working, status.rawValue)
        }
        XCTAssertFalse(threadItems(snapshot(actions: false)).contains { $0.item == .stop })
        XCTAssertFalse(threadItems(snapshot(capabilities: [.observe, .tmux])).contains { $0.item == .stop })
        let unbound = AgentThreadSnapshot(summary: snapshot().summary, messages: [], cursor: nil, hasMore: false, binding: nil)
        XCTAssertFalse(threadItems(unbound).contains { $0.item == .stop })
    }

    func testForkRequiresProviderSupportAndAnAvailableBoundTmuxTarget() throws {
        for provider in [AgentProviderID.claude] {
            let fork = try XCTUnwrap(threadItems(snapshot(provider: provider)).first { $0.item == .fork })
            XCTAssertTrue(fork.isEnabled)
            XCTAssertEqual(fork.priority, .automatic)
        }
        for provider in [AgentProviderID.codex, .kimi, .custom] {
            XCTAssertFalse(threadItems(snapshot(provider: provider)).contains { $0.item == .fork })
        }
        for thread in [snapshot(fork: false), snapshot(actions: false), snapshot(capabilities: [.observe, .interrupt])] {
            XCTAssertFalse(try XCTUnwrap(threadItems(thread).first { $0.item == .fork }).isEnabled)
        }
        let noTarget = AgentRailPolicy.threadItems(snapshot(), hasSwitcher: true, hasContext: true, hasForkTarget: false)
        XCTAssertFalse(try XCTUnwrap(noTarget.first { $0.item == .fork }).isEnabled)
    }

    func testSwitcherContextAndStopHaveHighPriorityAndEveryItemHasATitleAndSymbol() {
        let entries = threadItems(snapshot())
        XCTAssertEqual(entries.map(\.item), [.switcher, .context, .stop, .fork])
        XCTAssertEqual(entries.map(\.priority), [.high, .high, .high, .automatic])
        for item in AgentRailPolicy.Item.allCases {
            XCTAssertNotEqual(item.title, LocalizedStringKey(""))
            XCTAssertFalse(item.systemImage.isEmpty)
        }
        XCTAssertEqual(AgentRailPolicy.Item.stop.systemImage, "stop.fill")
    }

    func testToolbarDispatchesOnlyVisibleEnabledActions() {
        var calls: [String] = []
        let thread = AgentRailToolbar(
            items: threadItems(snapshot()), onOpenSwitcher: { calls.append("switcher") },
            onNewAgent: { calls.append("new") }, onToggleContext: { calls.append("context") },
            onStop: { calls.append("stop") }, onFork: { calls.append("fork") }
        )
        for item in [AgentRailPolicy.Item.switcher, .newAgent, .context, .stop, .fork] { thread.perform(item) }
        XCTAssertEqual(calls, ["switcher", "context", "stop", "fork"])

        let board = AgentRailToolbar(
            items: AgentRailPolicy.items(screen: .board, hasSwitcher: false),
            onOpenSwitcher: { calls.append("unavailable") }, onNewAgent: { calls.append("new") }
        )
        board.perform(.switcher)
        board.perform(.newAgent)
        board.perform(.stop)
        XCTAssertEqual(calls, ["switcher", "context", "stop", "fork", "new"])
    }

    func testRailForcesStackAtEveryWidthAndNonRailKeepsExistingThresholds() {
        for sidebar in [false, true] {
            for width: CGFloat in [0, 382, 619, 620, 669, 867, 919, 920, 1600] {
                XCTAssertFalse(AgentRailPolicy.usesTwoColumns(width: width, includesNavigationSidebar: sidebar, railMode: true))
                XCTAssertEqual(
                    AgentRailPolicy.usesTwoColumns(width: width, includesNavigationSidebar: sidebar, railMode: false),
                    width >= (sidebar ? 920 : 620)
                )
            }
        }
    }

    func testAgentArtifactsStayInTheMatchingWorkspaceAndOtherHostsUseTheExistingRoute() {
        XCTAssertEqual(AgentRailPolicy.artifactDestination(
            requestHostID: hostID, threadHostID: hostID, hasWorkspace: true, isContextShown: true, isSwapped: false
        ), .context(reveal: false))
        XCTAssertEqual(AgentRailPolicy.artifactDestination(
            requestHostID: UUID(), threadHostID: hostID, hasWorkspace: true, isContextShown: true, isSwapped: false
        ), .inherited)
        XCTAssertEqual(AgentRailPolicy.artifactDestination(
            requestHostID: hostID, threadHostID: hostID, hasWorkspace: false, isContextShown: false, isSwapped: false
        ), .inherited)
    }

    func testOpeningAnAgentArtifactRevealsHiddenContextAndKeepsASwappedContextFullScreen() {
        XCTAssertEqual(AgentRailPolicy.artifactDestination(
            requestHostID: hostID, threadHostID: hostID, hasWorkspace: true, isContextShown: false, isSwapped: false
        ), .context(reveal: true))
        XCTAssertEqual(AgentRailPolicy.artifactDestination(
            requestHostID: hostID, threadHostID: hostID, hasWorkspace: true, isContextShown: false, isSwapped: true
        ), .context(reveal: false))
    }

    func testNewThreadDefaultsToFilesWithTheContextAvailable() {
        let state = AgentRailThreadStateStore()[threadID()]
        XCTAssertEqual(state.workspace, DuoWorkspaceState())
        XCTAssertEqual(state.selection, .extra("files"))
    }

    func testReturningFromBoardOrAnotherThreadRetainsEveryPaneControlAndSelection() {
        let first = threadID(), second = threadID(session: "other")
        var store = AgentRailThreadStateStore()
        let workspace = DuoWorkspaceState(contextHidden: true, fullScreen: true, swapped: true, deskTraded: true)
        store[first].workspace = workspace
        store[first].selection = .tab("plan")
        store[second].workspace.toggleContext(arrangement: .sideBySide)
        store[second].selection = .extra("terminal")
        store.prune(retaining: [first, second])
        XCTAssertEqual(store[first].workspace, workspace)
        XCTAssertEqual(store[first].selection, .tab("plan"))
        XCTAssertTrue(store[second].workspace.contextHidden)
        XCTAssertEqual(store[second].selection, .extra("terminal"))
    }

    func testPruningRemovedThreadsPreservesOthersAndReappearanceStartsAtFiles() {
        let first = threadID(), second = threadID(session: "other")
        var store = AgentRailThreadStateStore()
        store[first].workspace.swap()
        store[first].selection = .automatic
        store[second].selection = .tab("report")
        store.prune(retaining: [second])
        XCTAssertEqual(store[first].workspace, DuoWorkspaceState())
        XCTAssertEqual(store[first].selection, .extra("files"))
        XCTAssertEqual(store[second].selection, .tab("report"))
        // A dismissing sheet's late write cannot reinsert a removed thread.
        store[first].selection = .extra("terminal")
        XCTAssertEqual(store[first].selection, .extra("files"))
        store.prune(retaining: [first, second])
        store[first].selection = .automatic
        XCTAssertEqual(store[first].selection, .automatic)
    }

    func testStateIsScopedToTheFullHostProviderAndConversationIdentity() {
        let first = threadID(), otherHost = threadID(host: UUID()), otherProvider = threadID(provider: .codex)
        var store = AgentRailThreadStateStore()
        store[first].selection = .tab("plan")
        XCTAssertEqual(store[otherHost].selection, .extra("files"))
        XCTAssertEqual(store[otherProvider].selection, .extra("files"))
        store.prune(retaining: [])
        XCTAssertEqual(store[first].selection, .extra("files"))
    }

    func testCoreSuccessorInheritsEveryPaneControlOnItsFirstRead() {
        let first = threadID(), successor = threadID(session: "successor")
        let lineage = succession([first: successor])
        var store = AgentRailThreadStateStore()
        let workspace = DuoWorkspaceState(contextHidden: true, fullScreen: true, swapped: true, deskTraded: true)
        store[first].workspace = workspace
        store[first].selection = .tab("held-page")
        store.prune(retaining: [first])

        // Bindings read before the root's onChange migrates or prunes.
        XCTAssertEqual(store[successor, inheriting: lineage].workspace, workspace)
        XCTAssertEqual(store[successor, inheriting: lineage].selection, .tab("held-page"))
        // The old retained-ID guard must admit a successor's first write.
        store[successor, inheriting: lineage].selection = .tab("next-page")
        XCTAssertEqual(store[successor, inheriting: lineage].workspace, workspace)
        XCTAssertEqual(store[successor].selection, .tab("next-page"))
        XCTAssertEqual(store[first].selection, .tab("held-page"))
    }

    func testPruneMigratesASuccessorBeforeItsSnapshotOrListRowExists() {
        let first = threadID(), successor = threadID(session: "pending")
        let lineage = succession([first: successor])
        var store = AgentRailThreadStateStore()
        store[first].workspace.swap()
        store[first].selection = .tab("held-page")
        let inherited = store[first]

        // Core named the successor, but neither snapshot nor list contains it.
        store.prune(retaining: [], inheriting: lineage)
        XCTAssertEqual(store[successor], inherited)
        store[successor].workspace.contextHidden = true
        XCTAssertTrue(store[successor].workspace.contextHidden)
        XCTAssertEqual(store[successor].selection, .tab("held-page"))
        store[first].selection = .tab("late-outgoing-write")
        XCTAssertEqual(store[first], AgentRailThreadStateStore.State())
        store.prune(retaining: [successor], inheriting: lineage)
        XCTAssertTrue(store[successor].workspace.contextHidden)

        store.prune(retaining: []) // successor removed without another replacement
        XCTAssertEqual(store[successor], AgentRailThreadStateStore.State())
    }

    func testSuccessionChainsReadAndMigrateBeforeDroppingTheirOrigins() {
        let first = threadID(), middle = threadID(session: "middle"), last = threadID(session: "last")
        var lineage = succession([first: middle, middle: last])
        var store = AgentRailThreadStateStore()
        store[first].workspace.toggleFullScreen()
        store[first].selection = .tab("held-page")
        let inherited = store[first]
        XCTAssertEqual(store[last, inheriting: lineage], inherited)
        store.prune(retaining: [], inheriting: lineage)
        XCTAssertEqual(store[last], inherited)
        // A later publish can drop the intermediate record after migration.
        lineage.migrated()
        store.prune(retaining: [last], inheriting: lineage)
        XCTAssertEqual(store[last], inherited)
        XCTAssertEqual(store[middle], AgentRailThreadStateStore.State())
    }

    func testExplicitNavigationAndASuccessorsOwnStateRemainIndependent() {
        let first = threadID(), second = threadID(session: "second"), third = threadID(session: "third")
        var store = AgentRailThreadStateStore()
        store[first].selection = .tab("held-page")
        store[first].workspace.swap()
        XCTAssertEqual(store[second], AgentRailThreadStateStore.State(), "choosing another row has no Core origin")
        store[second].selection = .extra("terminal")
        let own = store[second]
        let lineage = succession([first: second])
        XCTAssertEqual(store[second, inheriting: lineage], own)
        store.prune(retaining: [second, third], inheriting: lineage)
        XCTAssertEqual(store[second], own)
        XCTAssertEqual(store[third], AgentRailThreadStateStore.State())
        XCTAssertEqual(store[first], AgentRailThreadStateStore.State())
    }

    func testCoalescedSuccessionsKeepWritesToTheImmediatePredecessor() {
        for migrateFirst in [false, true] {
            let first = threadID(), middle = threadID(session: "middle"), last = threadID(session: "last")
            var store = AgentRailThreadStateStore()
            store[first].selection = .tab("first-page")
            store[first].workspace.swap()
            var lineage = succession([first: middle])
            if migrateFirst { store.prune(retaining: [], inheriting: lineage) }
            // Edits before the next prune belong to the intermediate successor.
            store[middle, inheriting: lineage].selection = .tab("new-page")
            store[middle, inheriting: lineage].workspace.fullScreen = true
            let latest = store[middle]
            lineage.record([middle: last], following: middle, removed: [middle], retaining: [])
            XCTAssertEqual(store[last, inheriting: lineage], latest)
            store.prune(retaining: [], inheriting: lineage)
            XCTAssertEqual(store[last], latest)
            XCTAssertEqual(store[middle], AgentRailThreadStateStore.State())
            store.prune(retaining: [])
            lineage.migrated()
            let unrelated = threadID(session: "unrelated")
            lineage.record([first: unrelated], following: first, removed: [first], retaining: [])
            XCTAssertEqual(store[unrelated, inheriting: lineage], AgentRailThreadStateStore.State())
        }
    }

    func testReturningBySuccessionContinuesThePredecessorBeforeAndAfterPrune() {
        for changesPage in [false, true] {
            let first = threadID(), middle = threadID(session: "middle")
            var store = AgentRailThreadStateStore()
            store[first].selection = .tab("P")
            store[first].workspace.swap()
            var lineage = succession([first: middle])
            store.prune(retaining: [middle], inheriting: lineage)
            lineage.migrated()
            if changesPage { store[middle, inheriting: lineage].selection = .tab("Q") }
            let expected = store[middle, inheriting: lineage]
            lineage.record([middle: first], following: middle, removed: [middle], retaining: [])
            XCTAssertEqual(store[first, inheriting: lineage], expected)
            store.prune(retaining: [], inheriting: lineage)
            XCTAssertEqual(store[first], expected)
            lineage.migrated()
            XCTAssertEqual(store[first, inheriting: lineage], expected)
        }
    }

    func testCoalescedReturnUsesTheIntermediateStateInsteadOfTheOriginalsOldState() {
        for changesPage in [false, true] {
            let first = threadID(), middle = threadID(session: "middle")
            var store = AgentRailThreadStateStore()
            store[first].selection = .tab("P")
            var lineage = succession([first: middle])
            // A's old record still exists; it belongs to the departed incarnation.
            if changesPage { store[middle, inheriting: lineage].selection = .tab("Q") }
            let expected = changesPage ? DuoContextSelection.tab("Q") : .tab("P")
            lineage.record([middle: first], following: middle, removed: [middle], retaining: [])
            XCTAssertEqual(store[first, inheriting: lineage].selection, expected)
            store.prune(retaining: [], inheriting: lineage)
            XCTAssertEqual(store[first].selection, expected)
        }
    }

    func testSeveralPredecessorsPreferTheFollowedThreadInEitherInsertionOrder() {
        let root = threadID(provider: .codex, session: "root")
        let child = threadID(provider: .codex, session: "child")
        let next = threadID(provider: .codex, session: "next")
        for _ in 0..<100 {
            for reversed in [false, true] {
                let pairs = reversed ? [(child, next), (root, next)] : [(root, next), (child, next)]
                let replacements = Dictionary(uniqueKeysWithValues: pairs)
                for followed in [root, child] {
                    var store = AgentRailThreadStateStore()
                    store[root].selection = .tab("P")
                    if followed == child { store[child].selection = .tab("R") }
                    let lineage = succession(replacements, following: followed)
                    let expected = followed == root ? DuoContextSelection.tab("P") : .tab("R")
                    XCTAssertEqual(store[next, inheriting: lineage].selection, expected)
                    store.prune(retaining: [], inheriting: lineage)
                    XCTAssertEqual(store[next].selection, expected)
                }
            }
        }
    }

    func testSeveralPredecessorsFallBackToTheFirstWithStateInIdentityOrder() {
        let first = threadID(session: "a"), second = threadID(session: "b"), third = threadID(session: "c")
        let next = threadID(session: "next")
        for reversed in [false, true] {
            let pairs = reversed ? [(third, next), (second, next), (first, next)]
                : [(first, next), (second, next), (third, next)]
            let lineage = succession(Dictionary(uniqueKeysWithValues: pairs))
            var store = AgentRailThreadStateStore()
            store[second].selection = .tab("second")
            store[third].selection = .tab("third")
            XCTAssertEqual(store[next, inheriting: lineage].selection, .tab("second"))
        }
    }

    func testFollowedPredecessorKeepsFilesWhenOnlyAnotherPredecessorHasState() {
        let first = threadID(), other = threadID(session: "other"), next = threadID(session: "next")
        let lineage = succession([first: next, other: next], following: first)
        var store = AgentRailThreadStateStore()
        store[other].selection = .tab("other-page")
        XCTAssertEqual(store[next, inheriting: lineage].selection, .extra("files"))
        store.prune(retaining: [], inheriting: lineage)
        XCTAssertEqual(store[next].selection, .extra("files"))
    }

    func testResumedBranchWritesCannotOverrideAnotherBranchsSuccessor() {
        for migrateFirst in [false, true] {
            let first = threadID(), middle = threadID(session: "middle"), last = threadID(session: "last")
            var store = AgentRailThreadStateStore()
            store[first].selection = .tab("P")
            var lineage = succession([first: middle])
            if migrateFirst {
                store.prune(retaining: [middle], inheriting: lineage)
                lineage.migrated()
            }
            // Core lists A again on a different pane while B keeps running.
            lineage.record([:], following: first, removed: [], retaining: [first, middle])
            store.prune(retaining: [first, middle], inheriting: lineage)
            store[first, inheriting: lineage].selection = .tab("Q")
            lineage.record([first: last], following: first, removed: [first], retaining: [middle])
            XCTAssertEqual(store[last, inheriting: lineage].selection, .tab("Q"))
            XCTAssertEqual(store[middle, inheriting: lineage].selection, .tab("P"))
            store.prune(retaining: [middle], inheriting: lineage)
            XCTAssertEqual(store[last].selection, .tab("Q"))
            XCTAssertEqual(store[middle].selection, .tab("P"))
        }
    }

    func testAnEmptyPredecessorCannotGainStateRetroactivelyFromItsResumedBranch() {
        let first = threadID(), next = threadID(session: "next")
        var store = AgentRailThreadStateStore()
        var lineage = succession([first: next])
        lineage.record([:], following: first, removed: [], retaining: [first, next])
        store[first, inheriting: lineage].selection = .tab("Q")
        XCTAssertEqual(store[next, inheriting: lineage].selection, .extra("files"))
        store.prune(retaining: [first, next], inheriting: lineage)
        XCTAssertEqual(store[next].selection, .extra("files"))
    }

    func testDepartedBindingsCannotWriteBeforePruneOrThroughAnOlderSuccession() {
        let first = threadID(), middle = threadID(session: "middle"), last = threadID(session: "last")
        var store = AgentRailThreadStateStore()
        store[first].selection = .tab("P")
        var lineage = succession([first: middle])
        store[first, inheriting: lineage].selection = .tab("late-first")
        XCTAssertEqual(store[middle, inheriting: lineage].selection, .tab("P"))
        store.prune(retaining: [], inheriting: lineage)
        let oldLineage = lineage
        lineage.record([middle: last], following: middle, removed: [middle], retaining: [])
        store.prune(retaining: [], inheriting: lineage)
        store[middle, inheriting: oldLineage].selection = .tab("late-middle")
        XCTAssertEqual(store[middle].selection, .extra("files"))
        XCTAssertEqual(store[last].selection, .tab("P"))
    }

    func testResetClearsInheritedAndWrittenStateBeforeTheNextPrune() {
        let first = threadID(), next = threadID(session: "next")
        var store = AgentRailThreadStateStore()
        store[first].selection = .tab("P")
        var lineage = succession([first: next])
        store.prune(retaining: [], inheriting: lineage)
        lineage = AgentThreadSuccession()
        XCTAssertEqual(store[next, inheriting: lineage].selection, .extra("files"))
        store.prune(retaining: [], inheriting: lineage)
        XCTAssertEqual(store.recordCount, 0)
    }

    func testThousandSuccessionsKeepOnlyTheCurrentStateAfterMigration() {
        var current = threadID()
        var store = AgentRailThreadStateStore()
        var lineage = AgentThreadSuccession()
        store[current].selection = .tab("P")
        for index in 0..<1_000 {
            let next = threadID(session: "next-\(index)")
            lineage.record([current: next], following: current, removed: [current], retaining: [])
            XCTAssertEqual(store[next, inheriting: lineage].selection, .tab("P"))
            store.prune(retaining: [], inheriting: lineage)
            lineage.migrated()
            XCTAssertEqual(store[next, inheriting: lineage].selection, .tab("P"))
            XCTAssertEqual(store.recordCount, 1)
            XCTAssertEqual(lineage.recordCount, 1)
            current = next
        }
    }

    func testUnmigratedLineageAndIntermediateWritesHaveHardCaps() {
        var current = threadID()
        var store = AgentRailThreadStateStore()
        var lineage = AgentThreadSuccession()
        store[current].selection = .tab("P")
        for index in 0..<1_000 {
            let next = threadID(session: "next-\(index)")
            lineage.record([current: next], following: current, removed: [current], retaining: [])
            store[next, inheriting: lineage].selection = .tab("P")
            XCTAssertLessThanOrEqual(lineage.recordCount, AgentThreadSuccession.maximumRecords)
            XCTAssertLessThanOrEqual(store.recordCount, AgentRailThreadStateStore.maximumRecords)
            current = next
        }
        store.prune(retaining: [], inheriting: lineage)
        lineage.migrated()
        XCTAssertEqual(store[current, inheriting: lineage].selection, .tab("P"))
        XCTAssertEqual(store.recordCount, 1)
        XCTAssertEqual(lineage.recordCount, 1)
    }

    private func succession(_ successors: [AgentThreadID: AgentThreadID], following: AgentThreadID? = nil) -> AgentThreadSuccession {
        var lineage = AgentThreadSuccession()
        lineage.record(successors, following: following, removed: Set(successors.keys),
                       retaining: [])
        return lineage
    }

    func testMarkedPathsComeOnlyFromEditsAndAreDeduplicated() {
        let messages = [message([
            .text("/srv/project/not-edited.swift"), .toolCall(name: "Read", preview: "/srv/project/read.swift"),
            .edit(path: "/srv/project/a.swift", diff: "+a"), .edit(path: "/srv/project/a.swift", diff: "+b"),
            .edit(path: "/srv/project/docs/PLAN.md", diff: nil), .edit(path: nil, diff: "+no path"),
            .edit(path: "", diff: nil), .edit(path: "  \n", diff: nil), .edit(path: "/bad\0path", diff: nil)
        ])]
        XCTAssertEqual(AgentRailPolicy.markedPaths(in: messages), ["/srv/project/a.swift", "/srv/project/docs/PLAN.md"])
    }

    func testRelativeEditsRequireKnownAbsoluteCwdAndKeepLiteralSpaces() {
        let messages = [message([
            .edit(path: "./src/a.swift", diff: nil), .edit(path: "docs/my plan.md", diff: nil),
            .edit(path: "~/private.txt", diff: nil), .edit(path: "/srv/project/src/../b.swift", diff: nil)
        ])]
        XCTAssertEqual(AgentRailPolicy.markedPaths(in: messages), ["/srv/project/b.swift"])
        XCTAssertEqual(AgentRailPolicy.markedPaths(in: messages, directory: "~/project"), ["/srv/project/b.swift"])
        XCTAssertEqual(AgentRailPolicy.markedPaths(in: messages, directory: "/srv/project/"), [
            "/srv/project/src/a.swift", "/srv/project/docs/my plan.md", "/srv/project/b.swift"
        ])
        XCTAssertTrue(AgentRailPolicy.markedPaths(in: []).isEmpty)
    }

    func testSavedHostLookupUsesOnlyTheThreadHostAndPassesNilForUnsavedHosts() {
        let id = threadID()
        XCTAssertEqual(AgentRailPolicy.savedHostID(for: id, savedHostIDs: [hostID, UUID()]), hostID)
        XCTAssertNil(AgentRailPolicy.savedHostID(for: id, savedHostIDs: [UUID()]))
        XCTAssertNil(AgentRailPolicy.savedHostID(for: id, savedHostIDs: []))
    }

    func testTerminalExtraRequiresAnObservedBindingAndItsExistingLiveSession() {
        let binding = makeBinding()
        XCTAssertTrue(AgentRailPolicy.hasTerminalExtra(binding: binding, liveSessionIDs: [sessionID]))
        XCTAssertFalse(AgentRailPolicy.hasTerminalExtra(binding: binding, liveSessionIDs: [UUID()]))
        XCTAssertFalse(AgentRailPolicy.hasTerminalExtra(binding: nil, liveSessionIDs: [sessionID]))
        XCTAssertFalse(AgentRailPolicy.hasTerminalExtra(binding: makeBinding(capabilities: [.interrupt]), liveSessionIDs: [sessionID]))
    }

    func testTmuxDirectoryRequiresTheExactPaneAndWindowAndAcceptsTmuxPrefixes() {
        for transport in [AgentTransportKind.sshTmux, .moshTmux] {
            let binding = makeBinding(transport: transport)
            XCTAssertEqual(AgentRailPolicy.workingDirectory(binding: binding, activeWindowID: "@3", activePaneID: "%7", directory: "/srv/project"), "/srv/project")
            XCTAssertNil(AgentRailPolicy.workingDirectory(binding: binding, activeWindowID: "@3", activePaneID: "%8", directory: "/other"))
            XCTAssertNil(AgentRailPolicy.workingDirectory(binding: binding, activeWindowID: "@4", activePaneID: "%7", directory: "/other"))
            XCTAssertNil(AgentRailPolicy.workingDirectory(binding: binding, activeWindowID: "@3", activePaneID: nil, directory: "/other"))
        }
    }

    func testDirectoryNeverGuessesFromRelativePathsOrMissingTmuxProof() {
        let binding = makeBinding(capabilities: [.observe, .interrupt])
        XCTAssertNil(AgentRailPolicy.workingDirectory(binding: binding, activeWindowID: "3", activePaneID: "7", directory: "/srv/project"))
        for directory in [nil, "project", "~/project", "/bad\0path"] as [String?] {
            XCTAssertNil(AgentRailPolicy.workingDirectory(binding: makeBinding(), activeWindowID: "3", activePaneID: "7", directory: directory))
        }
        for transport in [AgentTransportKind.ssh, .mosh] {
            XCTAssertEqual(AgentRailPolicy.workingDirectory(binding: makeBinding(transport: transport), activeWindowID: nil, activePaneID: nil, directory: "/srv/project"), "/srv/project")
        }
    }

    private func threadID(host: UUID? = nil, provider: AgentProviderID = .claude, session: String = "conversation") -> AgentThreadID {
        AgentThreadID(hostID: host ?? hostID, providerID: provider, providerSessionID: session)!
    }

    private func makeBinding(
        transport: AgentTransportKind = .sshTmux,
        capabilities: AgentTerminalCapabilities = [.observe, .interrupt, .tmux]
    ) -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1, incarnation: AgentIncarnationToken("test")!,
                             transport: transport, tmuxSession: "work", windowID: "3", paneID: "7", agentPID: 42,
                             capabilities: capabilities)
    }

    private func snapshot(
        status: TesseraAgentCore.AgentStatus = .working, provider: AgentProviderID = .claude, actions: Bool = true,
        fork: Bool = true, capabilities: AgentTerminalCapabilities = [.observe, .interrupt, .tmux]
    ) -> AgentThreadSnapshot {
        AgentThreadSnapshot(
            summary: AgentThreadSummary(id: threadID(provider: provider), providerName: provider.rawValue, status: status,
                                        availability: .init(content: true, status: true, actions: actions, spawn: true, fork: fork, search: true)),
            messages: [], cursor: nil, hasMore: false, binding: makeBinding(capabilities: capabilities)
        )
    }

    private func threadItems(_ thread: AgentThreadSnapshot) -> [AgentRailPolicy.Entry] {
        AgentRailPolicy.threadItems(thread, hasSwitcher: true, hasContext: true, hasForkTarget: true)
    }

    private func message(_ blocks: [AgentBlock]) -> AgentMessage {
        AgentMessage(recordID: "edits", role: .assistant, displayTime: nil, blocks: blocks)
    }
}
