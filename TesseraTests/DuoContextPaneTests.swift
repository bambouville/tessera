import Foundation
import Observation
import SwiftUI
import Testing
import TesseraArtifactsCore
import TesseraCore
import WebKit
@testable import Tessera

struct DuoContextPaneTests {
    private let hostID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherHostID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func opensRouteOnlyToTheSelectedSessionsHostWhereTheContextDocks() {
        let sessionID = UUID()
        #expect(DuoContextPolicy.openDestination(docksContext: true, selectedSessionID: sessionID,
            selectedHostID: hostID, requestHostID: hostID, arrangement: .single) == .artifacts)
        for arrangement in [DuoPaneArrangement.single, .sideBySide, .stacked] {
            #expect(DuoContextPolicy.openDestination(docksContext: true, selectedSessionID: sessionID,
                selectedHostID: hostID, requestHostID: hostID, arrangement: arrangement)
                == (arrangement == .single ? .artifacts : .context(sessionID: sessionID)))
            #expect(DuoContextPolicy.openDestination(docksContext: false, selectedSessionID: sessionID,
                selectedHostID: hostID, requestHostID: hostID, arrangement: arrangement) == .artifacts)
            #expect(DuoContextPolicy.openDestination(docksContext: true, selectedSessionID: sessionID,
                selectedHostID: hostID, requestHostID: otherHostID, arrangement: arrangement) == .artifacts)
            #expect(DuoContextPolicy.openDestination(docksContext: true, selectedSessionID: nil,
                selectedHostID: hostID, requestHostID: hostID, arrangement: arrangement) == .artifacts)
            #expect(DuoContextPolicy.openDestination(docksContext: true, selectedSessionID: sessionID,
                selectedHostID: nil, requestHostID: hostID, arrangement: arrangement) == .artifacts)
        }
    }

    @Test func openingRevealsTheContextAndKeepsTheSwap() {
        let hidden = DuoWorkspaceState(contextHidden: true, fullScreen: true, swapped: true, deskTraded: true)
        let revealed = DuoContextPolicy.revealingContext(hidden)
        #expect(!revealed.contextHidden)
        #expect(!revealed.fullScreen)
        #expect(revealed.swapped)
        #expect(revealed.deskTraded)
        #expect(DuoContextPolicy.revealingContext(revealed) == revealed)
    }

    @Test func pickerSortsByRecencyChecksTheResolvedItemAndExcludesOtherHosts() {
        let ordered = DuoContextPolicy.orderedTabs(hostID: hostID, tabs: [
            tab("old", viewedAt: 1), tab("foreign", host: otherHostID, viewedAt: 100),
            tab("new", viewedAt: 5), tab("tie-b", viewedAt: 3), tab("tie-a", viewedAt: 3)
        ])
        #expect(ordered.map(\.id) == ["new", "tie-a", "tie-b", "old"])
        let automatic = resolve(.automatic, tabs: ordered)
        #expect(ordered.filter { automatic == .tab($0.id) }.map(\.id) == ["new"])
        let picked = resolve(.tab("old"), tabs: ordered)
        #expect(ordered.filter { picked == .tab($0.id) }.map(\.id) == ["old"])
        #expect(resolve(.tab("foreign"), tabs: ordered) == .tab("new"))
        #expect(DuoContextPolicy.orderedTabs(hostID: nil, tabs: ordered).isEmpty)
        #expect(DuoContextPolicy.orderedTabs(hostID: otherHostID, tabs: ordered).isEmpty)
    }

    @Test func automaticFallsBackFromRecentTabToExtraToEmptyAndRepairsStaleChoices() {
        #expect(resolve(.automatic, tabs: [tab("recent")]) == .tab("recent"))
        #expect(resolve(.automatic, tabs: []) == .extra("files"))
        #expect(resolve(.automatic, tabs: [], fallback: nil) == .automatic)
        #expect(resolve(.automatic, tabs: [], fallback: "missing") == .automatic)
        #expect(resolve(.tab("closed"), tabs: []) == .extra("files"))
        #expect(resolve(.extra("removed"), tabs: [tab("recent")]) == .tab("recent"))
        #expect(resolve(.extra("files"), tabs: [tab("recent")]) == .extra("files"))
    }

    @Test @MainActor func pickingATabSelectsItInTheStoreAndCannotPickAnotherHost() {
        let store = DuoContextTestStore(tabs: [tab("own"), tab("foreign", host: otherHostID)])
        #expect(DuoContextPane.pickTab("foreign", hostID: hostID, store: store) == nil)
        #expect(store.state.selectedID == nil)
        #expect(DuoContextPane.pickTab("own", hostID: hostID, store: store) == .tab("own"))
        #expect(store.state.selectedID == "own")
    }

    @Test func anExplicitQuickOpenOnAnotherHostKeepsItsTargetForNormalOpenRouting() {
        let targets: [(ArtifactsTarget, ArtifactOpenRequest.Target)] = [
            (.file(path: "/docs/plan.md"), .file(path: "/docs/plan.md")),
            (.page(scheme: "https", port: 8_443, path: "/app?q=1#part"),
             .page(scheme: "https", port: 8_443, path: "/app?q=1#part")),
            (.change(path: "/src/a.swift", diff: "+line", summary: "+1"),
             .change(path: "/src/a.swift", diff: "+line", summary: "+1"))
        ]
        for (target, expected) in targets {
            let request = DuoContextPolicy.quickOpenRequest(for: tab("foreign", host: otherHostID, target: target))
            #expect(request?.hostID == otherHostID)
            #expect(request?.target == expected)
            #expect(request?.origin == .quickOpen)
            #expect(request?.tabID == "foreign", "the full browser reveals the tab Quick Open made, not an older twin")
        }
    }

    @Test func closingASessionPrunesOnlyItsContextSelection() {
        let live = UUID(), closed = UUID()
        let selections: [UUID: DuoContextSelection] = [live: .tab("doc"), closed: .extra("files")]
        #expect(DuoContextPolicy.retainedSelections(selections, liveSessionIDs: [live]) == [live: .tab("doc")])
        #expect(DuoContextPolicy.retainedSelections(selections, liveSessionIDs: []).isEmpty)
    }

    @Test func theSlotShowsBesideAnotherPaneOrSwappedIntoTheMainOne() {
        #expect(!slot(.single, shown: false))
        #expect(!slot(.single, shown: true))
        #expect(slot(.single, shown: false, swapped: true))
        for arrangement in [DuoPaneArrangement.sideBySide, .stacked] {
            #expect(slot(arrangement, shown: true))
            #expect(!slot(arrangement, shown: false))
            #expect(slot(arrangement, shown: false, swapped: true))
        }
        #expect(DuoContextPolicy.slotVisible(arrangement: nil, isContextShown: false, isSwapped: false))
    }

    @Test func locksCoveringSheetsAndHiddenSurfacesSuspendVisibility() {
        func visible(surface: Bool = true, slot: Bool = true, locked: Bool = false,
                     obscured: Bool = false, sheet: Bool = false) -> Bool {
            DuoContextPolicy.isVisible(surfaceVisible: surface, slotVisible: slot,
                                       isLocked: locked, isObscured: obscured, hasSheet: sheet)
        }
        #expect(visible())
        #expect(!visible(surface: false))
        #expect(!visible(slot: false))
        #expect(!visible(locked: true))
        #expect(!visible(obscured: true))
        #expect(!visible(sheet: true))
    }

    @Test func aCoveringSheetPreferenceKeepsAnyPresentedChildObscured() {
        var obscured = ArtifactCoveringSheetPreferenceKey.defaultValue
        ArtifactCoveringSheetPreferenceKey.reduce(value: &obscured, nextValue: { false })
        #expect(!obscured)
        ArtifactCoveringSheetPreferenceKey.reduce(value: &obscured, nextValue: { true })
        ArtifactCoveringSheetPreferenceKey.reduce(value: &obscured, nextValue: { false })
        #expect(obscured)
    }

    @Test @MainActor func aHiddenOrDisappearingContextDoesNotClearTheArtifactsSectionsClaim() {
        let store = DuoContextTestStore(tabs: [tab("context"), tab("section")])
        let context = ArtifactVisibilitySession(), section = ArtifactVisibilitySession()
        context.update(nil, store: store)
        #expect(store.visibleCalls.isEmpty)
        section.update("section", store: store, priority: 1)
        context.update("context", store: store)
        #expect(store.visibleCalls == ["section"])
        context.update(nil, store: store)
        context.release()
        #expect(store.visibleCalls == ["section"])
        section.release()
        #expect(store.visibleCalls == ["section", nil])
    }

    @Test @MainActor func visibilityHandoffsRestoreTheRemainingSurfaceAndReassertAfterStoreSelection() {
        let store = DuoContextTestStore(tabs: [tab("context"), tab("section")])
        let context = ArtifactVisibilitySession(), section = ArtifactVisibilitySession()
        context.update("context", store: store)
        section.update("section", store: store, priority: 1)
        section.release()
        #expect(store.visibleCalls == ["context", "section", "context"])
        context.update("context", store: store, force: true)
        #expect(store.visibleCalls == ["context", "section", "context", "context"])
        context.release()
        #expect(store.visibleCalls.last == .some(nil))
    }

    @Test @MainActor func sharedPageSessionRetainsTheModelAcrossMetadataAndRefresh() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.contents[page.id] = .forwardedPage(url: URL(string: "http://127.0.0.1:50991/")!, ruleLabel: "dev", isEphemeral: true)
        let session = ArtifactPageSession()
        session.updatePageSession(for: page, store: store)
        let original = try #require(session.webModel(for: page, store: store))
        var renamed = page
        renamed.title = "learned title"
        renamed.viewedAt = 100
        session.updatePageSession(for: renamed, store: store)
        session.refresh(renamed, store: store)
        #expect(session.webModel(for: renamed, store: store) === original)
        #expect(store.refreshCalls == [page.id])
        session.stop()
        session.updatePageSession(for: renamed, store: store)
        #expect(session.webModel(for: renamed, store: store) === original)

        let context = ArtifactPageSession()
        context.updatePageSession(for: page, store: store)
        #expect(context.webModel(for: page, store: store) !== original)
        context.stop()
    }

    @Test @MainActor func theWorkspaceSlotKeepsOnePageThroughHideShowAndPoseChanges() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.contents[page.id] = .forwardedPage(url: URL(string: "http://127.0.0.1:50991/")!,
                                                ruleLabel: "dev", isEphemeral: true)
        let owner = DuoContextPageOwner(), ownerID = UUID()
        owner.adopt(ownerID)
        owner.update(page, store: store, ownerID: ownerID)
        let original = try #require(owner.pageSession.webModel(for: page, store: store))
        var slotEnvironment = EnvironmentValues()
        slotEnvironment.duoContextPageOwner = owner

        for (arrangement, shown) in [
            (DuoPaneArrangement.sideBySide, true), (.sideBySide, false), (.sideBySide, true),
            (.single, false), (.single, true), (.stacked, true)
        ] {
            let slotVisible = slot(arrangement, shown: shown)
            // The page's lifetime belongs to the retained slot, including
            // while it is hidden. Visibility still owns no claim.
            owner.update(page, store: store, ownerID: ownerID)
            #expect(slotEnvironment.duoContextPageOwner?.pageSession.webModel(for: page, store: store) === original)
            if !shown || arrangement == .single { #expect(!slotVisible) }
        }
        let section = ArtifactPageSession()
        section.updatePageSession(for: page, store: store)
        #expect(section.webModel(for: page, store: store) !== original)
        #expect(store.visibleCalls.isEmpty)
        #expect(store.refreshCalls.isEmpty)
        owner.release(ownerID)
        section.end()
    }

    @Test @MainActor func hiddenPagesEndOnCloseSelectionAndForwardIdentityChanges() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        let firstURL = URL(string: "http://127.0.0.1:50991/")!
        store.contents[page.id] = .forwardedPage(url: firstURL, ruleLabel: "dev", isEphemeral: true)
        let owner = DuoContextPageOwner(), ownerID = UUID()
        owner.adopt(ownerID)
        owner.update(page, store: store, ownerID: ownerID)
        let original = try #require(owner.pageSession.session?.model)
        store.contents[page.id] = .forwardedPage(url: firstURL, ruleLabel: "renamed", isEphemeral: false)
        owner.update(page, store: store, ownerID: ownerID)
        #expect(owner.pageSession.session?.model === original)

        let newURL = URL(string: "http://127.0.0.1:50992/")!
        store.contents[page.id] = .forwardedPage(url: newURL, ruleLabel: "dev", isEphemeral: true)
        owner.update(page, store: store, ownerID: ownerID)
        #expect(owner.pageSession.session?.model !== original)
        #expect(owner.pageSession.session?.model.initialURL == newURL)
        let replaced = try #require(owner.pageSession.session?.model)
        owner.update(nil, store: store, ownerID: ownerID) // picking an extra ends the page
        #expect(owner.pageSession.session == nil)
        owner.update(page, store: store, ownerID: ownerID)
        #expect(owner.pageSession.session?.model !== replaced)
        store.close(page.id)
        owner.update(store.tab(page.id), store: store, ownerID: ownerID)
        #expect(owner.pageSession.session == nil)
        #expect(store.visibleCalls.isEmpty)
        #expect(store.refreshCalls.isEmpty)
    }

    @Test @MainActor func aReplacementWorkspaceSelectionRejectsLateUpdatesAndReleasesFromTheOldSlot() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.contents[page.id] = .forwardedPage(url: URL(string: "http://127.0.0.1:50991/")!,
                                                ruleLabel: "dev", isEphemeral: true)
        let owner = DuoContextPageOwner(), oldSlot = UUID(), nextSlot = UUID()
        owner.adopt(oldSlot)
        owner.update(page, store: store, ownerID: oldSlot)
        let previous = try #require(owner.pageSession.session?.model)
        owner.adopt(nextSlot)
        #expect(owner.pageSession.session == nil)
        owner.update(page, store: store, ownerID: nextSlot)
        let next = try #require(owner.pageSession.session?.model)
        #expect(next !== previous)
        owner.release(oldSlot)
        owner.update(nil, store: store, ownerID: oldSlot)
        #expect(owner.pageSession.session?.model === next)
        owner.release(nextSlot)
        #expect(owner.pageSession.session == nil)
    }

    /// Agent Center's pose swap replaces its pushed thread with two columns,
    /// then rebuilds it. The section's held page waits for the rebuilt pane;
    /// a pop, or another route, ends it.
    @Test @MainActor func aHeldPageOutlivesItsPaneOnlyWhileItsRouteWouldReturn() async throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        // No registration: this inert URL cannot issue a WebKit request.
        store.contents[page.id] = .forwardedPage(url: URL(string: "tessera-lifetime://fixture/index.html")!,
                                                ruleLabel: "fixture", isEphemeral: true)
        let route = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "route"))
        let other = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "other"))
        let holder = AgentRailPageHolder()
        holder.pushes(route)
        let owner = holder.owner(for: route)
        #expect(holder.owner(for: other) !== owner)
        let narrow = UUID()
        owner.adopt(narrow)
        owner.update(page, store: store, ownerID: narrow)
        let original = try #require(owner.pageSession.session?.model)

        owner.release(narrow) // two columns replace the destination
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.pageSession.session?.model === original)
        let rebuilt = UUID()
        owner.adopt(rebuilt)
        owner.update(page, store: store, ownerID: rebuilt)
        #expect(holder.owner(for: route) === owner)
        #expect(owner.pageSession.session?.model === original)

        // On a quick round trip, appear can precede the outgoing disappear.
        let overlapping = UUID()
        owner.adopt(overlapping)
        #expect(owner.pageSession.session?.model === original)
        owner.release(rebuilt)
        owner.update(nil, store: store, ownerID: rebuilt)
        #expect(owner.isOwned)
        #expect(owner.pageSession.session?.model === original)
        owner.update(page, store: store, ownerID: overlapping)
        #expect(owner.pageSession.session?.model === original)

        // A pane rebuilt within the same update adopts before the check runs.
        owner.release(overlapping)
        let sameTurn = UUID()
        owner.adopt(sameTurn)
        holder.pushes(nil) // the pending release must still respect the newer UUID
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.pageSession.session?.model === original)
        holder.pushes(route)

        // Popping leaves the outgoing pane its page until the pane goes.
        holder.pushes(nil)
        #expect(owner.pageSession.session?.model === original)
        owner.release(sameTurn)
        try await Task.sleep(for: .milliseconds(50))
        #expect(owner.pageSession.session == nil)

        // A page held without a pane ends as soon as its route does.
        holder.pushes(route)
        let returned = holder.owner(for: route)
        let pane = UUID()
        returned.adopt(pane)
        returned.update(page, store: store, ownerID: pane)
        returned.release(pane)
        try await Task.sleep(for: .milliseconds(50))
        #expect(returned.pageSession.session != nil)
        holder.pushes(other)
        #expect(returned.pageSession.session == nil)
        #expect(holder.owner(for: route) !== returned)
        #expect(store.visibleCalls.isEmpty)
        #expect(store.refreshCalls.isEmpty)
    }

    @Test @MainActor func anUnownedHeldPageEndsWhenItsTabClosesOrStopsBeingTheSamePage() throws {
        let page = tab("page", target: .file(path: "/srv/index.html"))
        let route = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "route"))
        for change in ["close", "non-page", "url", "handler"] {
            let store = DuoContextTestStore(tabs: [page])
            let url = URL(string: "tessera-lifetime://fixture/index.html")!
            let registration = ArtifactWebSchemeRegistration(scheme: "tessera-lifetime", handler: DuoContextSchemeHandler())
            store.contents[page.id] = .servedPage(url: url, registration: registration)
            let holder = AgentRailPageHolder()
            holder.pushes(route)
            let owner = holder.owner(for: route), pane = UUID()
            owner.adopt(pane)
            owner.update(page, store: store, ownerID: pane)
            let original = try #require(owner.pageSession.session?.model)
            owner.release(pane)
            holder.reconcile(routeID: route, selectedTabID: page.id, store: store)
            #expect(owner.pageSession.session?.model === original)

            switch change {
            case "close": store.close(page.id)
            case "non-page": store.contents[page.id] = .loading
            case "url": store.contents[page.id] = .servedPage(
                url: URL(string: "tessera-lifetime://fixture/next.html")!, registration: registration)
            default: store.contents[page.id] = .servedPage(url: url, registration: .init(
                scheme: "tessera-lifetime", handler: DuoContextSchemeHandler()))
            }
            holder.reconcile(routeID: route, selectedTabID: page.id, store: store)
            #expect(owner.pageSession.session == nil, "unreconciled change: \(change)")
            #expect(store.visibleCalls.isEmpty)
            #expect(store.refreshCalls.isEmpty)
        }
    }

    @Test @MainActor func aHeldPagesThreadSelectionInheritsOnlyForCoreSuccession() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.contents[page.id] = .forwardedPage(url: URL(string: "tessera-lifetime://fixture/index.html")!,
                                                ruleLabel: "fixture", isEphemeral: true)
        let route = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "route"))
        let successor = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "successor"))
        let other = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "other"))
        let holder = AgentRailPageHolder()
        holder.pushes(route)
        let owner = holder.owner(for: route), pane = UUID()
        owner.adopt(pane)
        owner.update(page, store: store, ownerID: pane)
        let original = try #require(owner.pageSession.session?.model)
        owner.release(pane)
        var states = AgentRailThreadStateStore()
        states[route].selection = .tab(page.id)
        func selectedTab(_ selection: DuoContextSelection) -> String? {
            let resolved = DuoContextPolicy.resolvedSelection(selection, tabs: store.state.tabs,
                extraIDs: ["files", "terminal"], fallbackExtraID: "files")
            if case let .tab(id) = resolved { return id }
            return nil
        }
        var lineage = AgentThreadSuccession()
        lineage.record([route: successor], following: route, removed: [route], retaining: [])
        // The first render precedes the root's migration and the first snapshot.
        holder.reconcile(routeID: route, selectedTabID: selectedTab(states[successor, inheriting: lineage].selection), store: store)
        #expect(owner.pageSession.session?.model === original)
        states.prune(retaining: [], inheriting: lineage)
        holder.reconcile(routeID: route, selectedTabID: selectedTab(states[successor].selection), store: store)
        #expect(owner.pageSession.session?.model === original)

        // Core then removes that thread without a successor and selects a row.
        states.prune(retaining: [other])
        holder.reconcile(routeID: route, selectedTabID: selectedTab(states[other].selection), store: store)
        #expect(owner.pageSession.session == nil)
    }

    @Test @MainActor func aHeldPageSurvivesSuccessionBackToItsOriginalConversation() throws {
        for changesPage in [false, true] {
            let firstPage = tab("P", target: .page(scheme: "http", port: 5_173, path: "/"))
            let secondPage = tab("Q", target: .page(scheme: "http", port: 5_173, path: "/next"))
            let store = DuoContextTestStore(tabs: [firstPage, secondPage])
            for page in [firstPage, secondPage] {
                store.contents[page.id] = .forwardedPage(url: URL(string: "tessera-lifetime://fixture/\(page.id).html")!,
                                                        ruleLabel: "fixture", isEphemeral: true)
            }
            let first = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "A"))
            let next = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "B"))
            let holder = AgentRailPageHolder()
            holder.pushes(first)
            let owner = holder.owner(for: first), pane = UUID()
            owner.adopt(pane)
            owner.update(firstPage, store: store, ownerID: pane)
            owner.release(pane)
            var states = AgentRailThreadStateStore()
            states[first].selection = .tab(firstPage.id)
            var lineage = AgentThreadSuccession()
            lineage.record([first: next], following: first, removed: [first], retaining: [])
            states.prune(retaining: [], inheriting: lineage)
            lineage.migrated()
            if changesPage {
                states[next, inheriting: lineage].selection = .tab(secondPage.id)
                owner.adopt(pane)
                owner.update(secondPage, store: store, ownerID: pane)
                owner.release(pane)
            }
            let held = try #require(owner.pageSession.session?.model)
            let expectedPage = changesPage ? secondPage.id : firstPage.id
            lineage.record([next: first], following: next, removed: [next], retaining: [])
            func reconcile() {
                let selection = states[first, inheriting: lineage].selection
                #expect(selection == .tab(expectedPage))
                let selectedID: String?
                if case let .tab(id) = selection { selectedID = id } else { selectedID = nil }
                holder.reconcile(routeID: first, selectedTabID: selectedID, store: store)
                #expect(owner.pageSession.session?.model === held)
            }
            reconcile()
            states.prune(retaining: [], inheriting: lineage)
            lineage.migrated()
            reconcile()
        }
    }

    @Test @MainActor func holderReconciliationLeavesMountedPanesInCharge() throws {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.contents[page.id] = .forwardedPage(url: URL(string: "tessera-lifetime://fixture/index.html")!,
                                                ruleLabel: "fixture", isEphemeral: true)
        let route = try #require(AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: "route"))
        let holder = AgentRailPageHolder()
        holder.pushes(route)
        let owner = holder.owner(for: route), pane = UUID()
        owner.adopt(pane)
        owner.update(page, store: store, ownerID: pane)
        let original = try #require(owner.pageSession.session?.model)
        store.close(page.id)
        holder.reconcile(routeID: route, selectedTabID: nil, store: store)
        #expect(owner.isOwned)
        #expect(owner.pageSession.session?.model === original)
        // Once the pane disappears, the same invalidation must take effect.
        owner.release(pane)
        holder.reconcile(routeID: route, selectedTabID: nil, store: store)
        #expect(owner.pageSession.session == nil)
    }

    @Test @MainActor func destroyingTheWorkspaceOwnerReleasesItsDetachedPage() async {
        let page = tab("page", target: .page(scheme: "http", port: 5_173, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        // No registration: this inert URL cannot issue a WebKit request.
        store.contents[page.id] = .forwardedPage(url: URL(string: "tessera-lifetime://fixture/index.html")!,
                                                ruleLabel: "fixture", isEphemeral: true)
        var owner: DuoContextPageOwner? = DuoContextPageOwner()
        let ownerID = UUID()
        weak var model: ArtifactWebViewModel?
        weak var webView: WKWebView?
        autoreleasepool {
            owner?.adopt(ownerID)
            owner?.update(page, store: store, ownerID: ownerID)
            model = owner?.pageSession.session?.model
            guard let model else { Issue.record("missing page model"); return }
            let coordinator = ArtifactWebSurface.Coordinator(model: model)
            let surface = coordinator.makeUIView(openExternalURL: { _ in })
            webView = surface.webView
            ArtifactWebSurface.dismantleUIView(surface, coordinator: coordinator)
        }
        #expect(model != nil)
        #expect(webView != nil)
        autoreleasepool { owner = nil }
        #expect(model == nil)
        #expect(await webViewReleased { webView == nil })
    }

    @Test @MainActor func pageIdentityIncludesTabURLAndServedHandlerAndClearsForNonPages() throws {
        let first = tab("first", target: .file(path: "/report/index.html"))
        let second = tab("second", target: .file(path: "/other/index.html"))
        let store = DuoContextTestStore(tabs: [first, second])
        let url = URL(string: "tessera-artifact://fixture/index.html")!
        let firstHandler = DuoContextSchemeHandler(), nextHandler = DuoContextSchemeHandler()
        store.contents[first.id] = .servedPage(url: url, registration: .init(scheme: "tessera-artifact", handler: firstHandler))
        let session = ArtifactPageSession()
        session.updatePageSession(for: first, store: store)
        let original = try #require(session.session?.model)
        session.refresh(first, store: store)
        session.updatePageSession(for: first, store: store)
        #expect(session.session?.model === original)

        store.contents[first.id] = .servedPage(url: url, registration: .init(scheme: "tessera-artifact", handler: nextHandler))
        #expect(session.webModel(for: first, store: store) == nil)
        session.updatePageSession(for: first, store: store)
        let replaced = try #require(session.session?.model)
        #expect(replaced !== original)
        store.contents[second.id] = store.contents[first.id]
        session.updatePageSession(for: second, store: store)
        #expect(session.session?.model !== replaced)
        let previous = try #require(session.session?.model)
        // An edited address on the same origin loads in the tab's web view,
        // keeping its history for back.
        let newURL = URL(string: "tessera-artifact://fixture/next.html")!
        store.contents[second.id] = .servedPage(url: newURL, registration: .init(scheme: "tessera-artifact", handler: nextHandler))
        session.updatePageSession(for: second, store: store)
        #expect(session.session?.model === previous)
        #expect(session.session?.model.url == newURL)
        // Another origin is another page, in a web view of its own.
        let otherOrigin = URL(string: "tessera-artifact://elsewhere/index.html")!
        store.contents[second.id] = .servedPage(url: otherOrigin, registration: .init(scheme: "tessera-artifact", handler: nextHandler))
        session.updatePageSession(for: second, store: store)
        #expect(session.session?.model !== previous)
        #expect(session.session?.model.initialURL == otherOrigin)
        store.contents[second.id] = .loading
        session.updatePageSession(for: second, store: store)
        #expect(session.session == nil)
        session.updatePageSession(for: nil, store: store)
        #expect(session.session == nil)
        #expect(firstHandler.startCalls == 0)
        #expect(nextHandler.startCalls == 0)
    }

    @Test @MainActor func offlinePageRefreshDoesNotRequestAConnectionOrRefresh() {
        let page = tab("page", target: .page(scheme: "http", port: 3_000, path: "/"))
        let store = DuoContextTestStore(tabs: [page])
        store.live = false
        ArtifactPageSession().refresh(page, store: store)
        #expect(store.refreshCalls.isEmpty)
    }

    @Test @MainActor func filesStayOfflineForEveryNonConnectedBridgeWithoutConnecting() async {
        let listing = DuoFilesListing()
        await listing.load(directory: "/work", bridge: nil)
        #expect(listing.isOffline)
        for state in [FileBridgeState.idle, .connecting, .dropped, .failed("offline")] {
            let bridge = DuoContextTestBridge(state: state)
            await listing.load(directory: "/work", bridge: bridge)
            #expect(listing.isOffline)
            #expect(listing.entries.isEmpty)
            #expect(!listing.isLoading)
            #expect(bridge.connectCalls == 0)
            #expect(bridge.listCalls.isEmpty)
        }
    }

    @Test @MainActor func filesUseOneExistingListingAndBoundRetainedEntries() async {
        let bridge = DuoContextTestBridge(state: .connected)
        bridge.entries = (0..<(DuoFilesListing.maximumEntries + 1)).map { index in
            RemoteFileEntry(name: "\(index)", path: "/work/\(index)", kind: .file,
                            size: 1, modified: nil, permissions: nil)
        }
        let listing = DuoFilesListing()
        await listing.load(directory: "/work", bridge: bridge)
        #expect(!listing.isOffline)
        #expect(!listing.isLoading)
        #expect(listing.isTruncated)
        #expect(listing.entries.count == DuoFilesListing.maximumEntries)
        #expect(bridge.listCalls == ["/work"])
        #expect(bridge.connectCalls == 0)
        await listing.load(directory: nil, bridge: bridge)
        #expect(bridge.listCalls == ["/work", "/home/test"])
        await listing.load(directory: "/work", bridge: nil)
        #expect(listing.isOffline)
        #expect(listing.entries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor func aSupersededFilesReplyCannotReplaceANewerDirectory() async {
        let bridge = DuoContextTestBridge(state: .connected)
        bridge.blockedPath = "/old"
        let listing = DuoFilesListing()
        var first: Task<Void, Never>?
        await withCheckedContinuation { started in
            bridge.onBlocked = { started.resume() }
            first = Task { await listing.load(directory: "/old", bridge: bridge) }
        }
        await listing.load(directory: "/new", bridge: bridge)
        bridge.pending?.resume(returning: [.init(name: "old", path: "/old/file", kind: .file,
                                                 size: 1, modified: nil, permissions: nil)])
        bridge.pending = nil
        await first?.value
        #expect(listing.directory == "/new")
        #expect(listing.entries.isEmpty)
        #expect(!listing.isLoading)
        #expect(bridge.connectCalls == 0)
    }

    @Test func filesUseTheLiveHostsExactRouteAndNeverAnAmbiguousOrStaleBridge() {
        let live = FileBridgeKey(hostID: hostID, user: "user", address: "host", port: 22, jumpPath: ["current"])
        let stale = FileBridgeKey(hostID: hostID, user: "user", address: "host", port: 22, jumpPath: ["old"])
        let foreign = FileBridgeKey(hostID: otherHostID, user: "user", address: "host", port: 22)
        #expect(DuoContextPolicy.fileBridgeKeys(hostID: hostID, sessionKeys: [live, live],
            existingKeys: [stale, live, foreign]) == [live])
        #expect(DuoContextPolicy.fileBridgeKeys(hostID: hostID, sessionKeys: [live], existingKeys: [stale]).isEmpty)
        #expect(DuoContextPolicy.fileBridgeKeys(hostID: hostID, sessionKeys: [], existingKeys: [live, foreign]) == [live])
        #expect(DuoContextPolicy.fileBridgeKeys(hostID: hostID, sessionKeys: [], existingKeys: [stale, live]).isEmpty)
        #expect(DuoContextPolicy.fileBridgeKeys(hostID: hostID, sessionKeys: [], existingKeys: [foreign]).isEmpty)
    }

    /// The pane's picker lists the most recent first, which moves with each
    /// pick; its chords walk the strip's order, so ⌘⇧] reaches every tab.
    @Test func thePanesTabChordsWalkTheStripsOrderNotTheMostRecent() {
        var tabs = [tab("a", viewedAt: 3), tab("b", viewedAt: 2), tab("foreign", host: otherHostID, viewedAt: 9), tab("c", viewedAt: 1)]
        #expect(DuoContextPane.shortcutOrder(hostID: hostID, tabs: tabs).map(\.id) == ["a", "b", "c"])
        var selected = "a"
        var visited: [String] = []
        for step in 1...3 {
            let order = DuoContextPane.shortcutOrder(hostID: hostID, tabs: tabs)
            guard let next = ArtifactsBrowserPresentation.adjacentTabID(tabs: order, selectedID: selected, offset: 1) else { break }
            visited.append(next)
            selected = next
            // Selecting makes it the most recent, as the store does.
            if let i = tabs.firstIndex(where: { $0.id == next }) { tabs[i].viewedAt = Int64(10 + step) }
        }
        #expect(visited == ["b", "c", "a"])
        #expect(ArtifactsBrowserPresentation.tabID(forDigit: 3, tabs: DuoContextPane.shortcutOrder(hostID: hostID, tabs: tabs)) == "c")
        #expect(DuoContextPane.shortcutOrder(hostID: nil, tabs: tabs).isEmpty)
    }

    @Test func theFilesSlotOpensThePanelUnlessConnectingWouldAsk() {
        for bridge in [false, true] {
            for unprompted in [false, true] {
                #expect(DuoContextPolicy.filesSlot(panelOpen: true, panelBridgeConnected: bridge,
                                                   connectsUnprompted: unprompted) == .panel)
            }
        }
        #expect(DuoContextPolicy.filesSlot(panelOpen: false, panelBridgeConnected: true, connectsUnprompted: false) == .opensPanel)
        #expect(DuoContextPolicy.filesSlot(panelOpen: false, panelBridgeConnected: false, connectsUnprompted: true) == .opensPanel)
        #expect(DuoContextPolicy.filesSlot(panelOpen: false, panelBridgeConnected: true, connectsUnprompted: true) == .opensPanel)
        // A terminal still connecting, or a host behind Face ID: the listing's
        // prompt waits for a tap.
        #expect(DuoContextPolicy.filesSlot(panelOpen: false, panelBridgeConnected: false, connectsUnprompted: false) == .listing)
    }

    @Test func filesConnectByThemselvesOnlyWhenNoKeyOnTheRouteCanAskForFaceID() {
        func unprompted(_ connected: Bool = true, faceID: Bool, session: Bool = false, chain: Bool = false) -> Bool {
            DuoContextPolicy.filesConnectUnprompted(terminalConnected: connected, keyFaceIDEnabled: faceID,
                                                    sessionNeedsFaceID: session, hasJumpChain: chain)
        }
        // The global setting off: no key asks, whatever the route.
        #expect(unprompted(faceID: false))
        #expect(unprompted(faceID: false, chain: true))
        // On: a direct route whose key ran without Face ID.
        #expect(unprompted(faceID: true))
        #expect(!unprompted(faceID: true, session: true))
        // A bastion's key carries its own setting, unknown here.
        #expect(!unprompted(faceID: true, chain: true))
        // A terminal not yet up dials nothing.
        #expect(!unprompted(false, faceID: false))
    }

    @Test func leavingFilesReturnsToTheHostsLastViewedTabOrStaysWithoutOne() {
        let tabs = [tab("older", viewedAt: 1), tab("latest", viewedAt: 3),
                    tab("elsewhere", host: otherHostID, viewedAt: 9)]
        #expect(DuoContextPolicy.tabLeavingFiles(hostID: hostID, tabs: tabs) == "latest")
        #expect(DuoContextPolicy.tabLeavingFiles(hostID: hostID, tabs: [tab("elsewhere", host: otherHostID)]) == nil)
        #expect(DuoContextPolicy.tabLeavingFiles(hostID: hostID, tabs: []) == nil)
        #expect(DuoContextPolicy.tabLeavingFiles(hostID: nil, tabs: tabs) == nil)
    }

    @Test func fileNavigationStopsAtRoot() {
        #expect(DuoContextPolicy.parentDirectory("/work/docs") == "/work")
        #expect(DuoContextPolicy.parentDirectory("/work") == "/")
        #expect(DuoContextPolicy.parentDirectory("/") == nil)
        #expect(DuoContextPolicy.parentDirectory("relative") == nil)
    }

    private func tab(_ id: String, host: UUID? = nil, viewedAt: Int64 = 1,
                     target: ArtifactsTarget = .file(path: "/docs/plan.md")) -> ArtifactTab {
        ArtifactTab(id: id, hostID: (host ?? hostID).uuidString, hostLabel: "host", target: target,
                    title: id, openedAt: 1, viewedAt: viewedAt, cache: .init(fetchedAt: 1, size: 1))
    }

    private func resolve(_ selection: DuoContextSelection, tabs: [ArtifactTab], fallback: String? = "files") -> DuoContextSelection {
        DuoContextPolicy.resolvedSelection(selection, tabs: tabs, extraIDs: ["files"], fallbackExtraID: fallback)
    }

    private func slot(_ arrangement: DuoPaneArrangement, shown: Bool, swapped: Bool = false) -> Bool {
        DuoContextPolicy.slotVisible(arrangement: arrangement, isContextShown: shown, isSwapped: swapped)
    }
}

@MainActor @Observable
private final class DuoContextTestStore: ArtifactsBrowserStore {
    var state: ArtifactsState
    var contents: [String: ArtifactContent] = [:]
    var live = true
    var visibleCalls: [String?] = []
    var refreshCalls: [String] = []
    var selectedTab: ArtifactTab? { state.selectedID.flatMap(tab) }
    var showsBrowserOverview = false
    var quickOpenHosts: [ArtifactsQuickOpenHost] { [] }

    init(tabs: [ArtifactTab]) { state = ArtifactsState(tabs: tabs) }
    func tab(_ id: String) -> ArtifactTab? { state.tabs.first { $0.id == id } }
    func overview(query: String) -> ArtifactsOverview { .make(state, filter: state.filter, query: query) }
    func content(for tabID: String) -> ArtifactContent { contents[tabID] ?? .unavailable(.offline) }
    func presentation(for tabID: String) -> ArtifactsCachePresentation {
        ArtifactsCachePolicy.presentation(tab(tabID)!, liveConnection: live, nowMillis: 1)
    }
    func isLive(hostID: String) -> Bool { live }
    func select(_ tabID: String) { state.selectedID = tabID }
    func close(_ tabID: String) {
        state.tabs.removeAll { $0.id == tabID }
        contents[tabID] = nil
        if state.selectedID == tabID { state.selectedID = nil }
    }
    func closeAll(hostID: String) {}
    func setPinned(_ tabID: String, _ pinned: Bool) {}
    func setFilter(_ filter: ArtifactsFilter) {}
    func refresh(_ tabID: String) { refreshCalls.append(tabID) }
    func noteVisible(_ tabID: String?) { visibleCalls.append(tabID) }
    func titleLearned(_ tabID: String, _ title: String) {}
    func canKeepAsRule(_ tabID: String) -> Bool { false }
    func keepAsRule(_ tabID: String) {}
    func quickOpenSuggestions(_ input: String, currentHostID: String?) -> [ArtifactsSuggestion] { [] }
    func quickOpen(_ input: String, currentHostID: String?, placement: ArtifactOpenPlacement) async -> ArtifactQuickOpenOutcome { .failed("unused") }
}

private final class DuoContextSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var startCalls = 0
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) { startCalls += 1 }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

@MainActor @Observable
private final class DuoContextTestBridge: FileBridging {
    let key = FileBridgeKey(user: "test", address: "unused.invalid", port: 22)
    var state: FileBridgeState
    let homeDirectory: String? = "/home/test"
    var suppressIdleTeardown = false
    var connectCalls = 0
    var listCalls: [String] = []
    var entries: [RemoteFileEntry] = []
    var blockedPath: String?
    @ObservationIgnored var pending: CheckedContinuation<[RemoteFileEntry], Error>?
    @ObservationIgnored var onBlocked: (() -> Void)?

    init(state: FileBridgeState) { self.state = state }
    func connect() async throws { connectCalls += 1; Issue.record("the context must never connect"); throw FileBridgeError.notConnected }
    func disconnect() async {}
    func listDirectory(_ path: String) async throws -> [RemoteFileEntry] {
        listCalls.append(path)
        if path == blockedPath {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                onBlocked?()
            }
        }
        return entries
    }
    func realPath(_ path: String) async throws -> String { path }
    func createDirectory(_ path: String) async throws {}
    func setPermissions(_ permissions: UInt16, at path: String) async throws {}
    func rename(from oldPath: String, to newPath: String) async throws {}
    func removeFile(_ path: String) async throws {}
    func removeDirectory(_ path: String) async throws {}
    func download(remotePath: String, to localURL: URL, progress: TransferProgressHandler?) async throws {}
    func upload(localURL: URL, to remotePath: String, progress: TransferProgressHandler?) async throws {}
    func exec(_ command: String, inShell: Bool) async throws -> String { "" }
}
