import XCTest
import SwiftUI
import UIKit
import TesseraCore
@testable import Tessera

@MainActor
final class AgentThreadPresentationViewTests: XCTestCase {
    func testContainerReplacementHoldsTheHistoryAnchorAndExpandedTools() throws {
        // A pan toward older rows the reader last made is retained with
        // them; it reveals nothing until a new gesture resumes paging.
        for (atLiveHead, demand) in [(true, ""), (false, ""), (true, "before"), (false, "before")] {
            let model = try makeModel(messageCount: 100, atLiveHead: atLiveHead)
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            var held = AgentThreadPresentationState()
            held.historyDemand = demand
            held.followingLatest = false
            held.visibleRowID = "m20#0"
            held.renderedLowerID = "m10#0"
            held.renderedUpperID = "m40#0"
            held.expandedToolEntries = ["tools#0"]
            held.positionedThread = threadID
            held.windowAtLiveHead = atLiveHead
            seed(held, for: threadID, in: store)
            var pins: [String?] = []
            model.onAction = { if case .viewportAnchor(_, let recordID) = $0 { pins.append(recordID) } }
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
            let window = try mount(controller)
            defer { unmount(window) }
            settle(controller)
            let anchor = try XCTUnwrap(pins.last ?? nil, "a held reader must pin a retained record, rather than follow the tail")
            XCTAssertEqual(anchor, "m20")
            pins = []
            controller.rootView = Host(model: model, store: store, wide: true)
            settle(controller)
            XCTAssertEqual(try XCTUnwrap(pins.last ?? nil), anchor)
            controller.rootView = Host(model: model, store: store, wide: false, shown: false)
            settle(controller)
            let saved = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertFalse(saved.followingLatest)
            XCTAssertEqual(saved.expandedToolEntries, ["tools#0"])
            XCTAssertEqual(saved.visibleRowID, "m20#0")
            // The reader's row lands before paging reads the edges, so no
            // restore takes the unscrolled top for an exposed one and
            // reveals rows above the range they held.
            XCTAssertEqual(saved.renderedLowerID, "m10#0", "demand \(demand)")
        }
    }

    /// A reader halfway down a reply that spans screens returns there, not
    /// to its first line, after narrow → wide → narrow and a hide.
    func testATallQuestionLandsAtItsTopOnceAndAShortOneStaysOnTheTail() throws {
        // 300 pt is about the laptop's upper half for the whole detail. A
        // reply taller than the viewport above the question puts the reader
        // inside it after the move, which must be kept to the point.
        for (options, height, lands, tall) in [(9, CGFloat(300), true, false), (9, CGFloat(300), true, true),
                                               (2, CGFloat(700), false, false)] {
            let model = try makeModel(messageCount: 40, atLiveHead: true, tallIndex: tall ? 39 : nil,
                                      prompt: question(options: options))
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            let card = CardBox()
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false, height: height, card: card))
            let window = try mount(controller)
            defer { unmount(window) }
            for _ in 0..<3 { settle(controller) }
            let scroll = try transcriptScroll(in: controller.view)
            let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
            let bottom = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            let offset = scroll.contentOffset.y
            let cardHeight = try XCTUnwrap(card.frame?.height, "the card reports its frame")
            XCTAssertEqual(cardHeight > viewport - 2 * AgentPromptLanding.margin, lands, "\(options) options: \(cardHeight) in \(viewport)")
            if lands {
                // The card's top sits a margin below the viewport's: below
                // the card only its timestamp and the stack's padding remain.
                let below = bottom - offset - (cardHeight + AgentPromptLanding.margin - viewport)
                XCTAssertGreaterThanOrEqual(below, -1, "the card's top is on screen")
                XCTAssertLessThan(below, 80, "the landing is the card's top, not somewhere above it")
            } else {
                XCTAssertEqual(offset, bottom, accuracy: 1, "a question that fits stays on the tail")
            }
            if lands {
                // Read on into the question without a pan: hidden and shown
                // again, the reader is where they were inside it.
                let inside = min(bottom, offset + 60)
                scroll.contentOffset.y = inside
                settle(controller)
                controller.rootView = Host(model: model, store: store, wide: false, height: height, shown: false, card: card)
                settle(controller)
                controller.rootView = Host(model: model, store: store, wide: false, height: height, card: card)
                for _ in 0..<3 { settle(controller) }
                XCTAssertEqual(try transcriptScroll(in: controller.view).contentOffset.y, inside, accuracy: 4,
                               "the reader's place inside the question they landed on")
            }
            // Only once: the reader may scroll on, and layout never pulls
            // them back to the card. VoiceOver and a keyboard scroll with no
            // pan, as this does.
            let moved = max(0, offset - 400)
            let reading = try transcriptScroll(in: controller.view)
            reading.contentOffset.y = moved
            settle(controller)
            if lands {
                XCTAssertEqual(reading.contentOffset.y, moved, accuracy: 1)
                // Hidden and shown again, the reader returns to the row they
                // moved to, not to the question that landed them.
                controller.rootView = Host(model: model, store: store, wide: false, height: height, shown: false, card: card)
                settle(controller)
                controller.rootView = Host(model: model, store: store, wide: false, height: height, card: card)
                for _ in 0..<3 { settle(controller) }
                let returned = try transcriptScroll(in: controller.view).contentOffset.y
                if tall {
                    XCTAssertEqual(returned, moved, accuracy: 4, "the reader returns to their place inside the long reply")
                } else {
                    // The viewport top may have been in the gap above that row.
                    XCTAssertLessThanOrEqual(returned, moved + 8, "the reader's top row, at most a row gap below where they were")
                    XCTAssertGreaterThan(returned, moved - 150, "the reader returns to their row, not one far above it")
                }
            }
            controller.rootView = Host(model: model, store: store, wide: false, height: height, shown: false, card: card)
            settle(controller)
            let state = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertEqual(state.followingLatest, !lands, "\(options) options")
            if lands {
                let row = try XCTUnwrap(state.visibleRowID)
                XCTAssertFalse(["question#0", "tools#0"].contains(row), "\(row): the reader moved on from the landing")
                if tall {
                    XCTAssertEqual(row, "m39#0")
                    XCTAssertGreaterThan(state.visibleRowFraction ?? 0, 0, "how far into the long reply the reader was")
                }
            }
        }
    }

    /// L-11 across a pose: a reader the tall question landed on in book,
    /// off the tail, keeps that place when laptop rebuilds the detail in its
    /// shorter upper half, which can lay out first at no height while the
    /// pose changes; it never opens at the conversation's top.
    func testALandedReaderKeepsItsPlaceWhenTheDetailMovesIntoAShorterContainer() throws {
        for (passesThroughZero, returnedFromHistory) in [(false, false), (true, false), (false, true)] {
            let model = try makeModel(messageCount: 40, atLiveHead: true, prompt: question(options: 9))
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            if returnedFromHistory {
                // Return to latest follows the tail again and leaves the
                // scroll position on the history row the reader had reached.
                var held = AgentThreadPresentationState()
                held.followingLatest = true
                held.visibleRowID = "m5#0"
                seed(held, for: threadID, in: store)
            }
            let card = CardBox()
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false, height: 700, card: card))
            let window = try mount(controller)
            defer { unmount(window) }
            for _ in 0..<3 { settle(controller) }
            let book = try transcriptScroll(in: controller.view)
            XCTAssertGreaterThan(book.contentOffset.y, 200, "the question landed well below the conversation's top")
            XCTAssertLessThan(book.contentOffset.y, maximumOffset(book) - 1, "the landing left the tail")
            if passesThroughZero {
                controller.rootView = Host(model: model, store: store, wide: true, height: 0, card: card)
                settle(controller)
            }
            controller.rootView = Host(model: model, store: store, wide: true, height: 300, card: card)
            for _ in 0..<3 { settle(controller) }
            let laptop = try transcriptScroll(in: controller.view)
            XCTAssertFalse(laptop === book, "the detail was rebuilt")
            let cardFrame = try XCTUnwrap(card.frame, "the card reports its frame")
            // The row stack spans the scroll content, so the card's top below
            // the viewport's is its row-stack top less the visible top.
            let cardTop = cardFrame.minY - laptop.contentOffset.y - laptop.adjustedContentInset.top
            XCTAssertGreaterThan(laptop.contentOffset.y, 200,
                                 "through zero \(passesThroughZero): the reader opened at the top, not where it was")
            XCTAssertGreaterThan(cardTop, -1, "through zero \(passesThroughZero): the card's top is on screen")
            XCTAssertLessThan(cardTop, 40, "through zero \(passesThroughZero): the reader is on the card's top")
            controller.rootView = Host(model: model, store: store, wide: true, height: 300, shown: false, card: card)
            settle(controller)
            let state = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertFalse(state.followingLatest)
            XCTAssertEqual(state.visibleRowID, "question#0", "returned from history \(returnedFromHistory): the landed row is the held one")
        }
    }

    func testThePromptLandingIsDecidedOncePerPrompt() {
        let token = AgentActionToken("landing")!
        let tall = AgentPromptCardFrame(token: token, frame: CGRect(x: 0, y: 900, width: 300, height: 500))
        let short = AgentPromptCardFrame(token: token, frame: CGRect(x: 0, y: 900, width: 300, height: 120))
        func decide(_ card: AgentPromptCardFrame?, decided: AgentActionToken? = nil, waiting: Bool = true,
                    following: Bool = true, positioned: Bool = true, height: CGFloat = 240) -> AgentPromptLanding? {
            AgentPromptLanding.decide(card, decided: decided, waiting: waiting, following: following,
                                      positioned: positioned, viewportHeight: height)
        }
        XCTAssertEqual(decide(tall), AgentPromptLanding(token: token, rowY: 900))
        XCTAssertEqual(decide(short), AgentPromptLanding(token: token, rowY: nil))
        XCTAssertEqual(decide(short, height: 120), AgentPromptLanding(token: token, rowY: 900))
        XCTAssertNil(decide(tall, decided: token))
        XCTAssertNil(decide(tall, waiting: false))
        XCTAssertNil(decide(tall, following: false))
        XCTAssertNil(decide(tall, positioned: false))
        XCTAssertNil(decide(nil))
        XCTAssertNil(decide(tall, height: 0))
    }

    func testAHeldReaderReturnsToTheSamePlaceInsideALongReply() throws {
        let model = try makeModel(messageCount: 30, tallIndex: 20)
        let threadID = try XCTUnwrap(model.selectedThreadID)
        let store = AgentThreadPresentationStore()
        var held = AgentThreadPresentationState()
        held.followingLatest = false
        held.visibleRowID = "m20#0"
        held.positionedThread = threadID
        held.windowAtLiveHead = true
        seed(held, for: threadID, in: store)
        let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
        let window = try mount(controller)
        defer { unmount(window) }
        settle(controller)
        let scroll = try transcriptScroll(in: controller.view)
        scroll.contentOffset.y += 1_500
        settle(controller)
        controller.rootView = Host(model: model, store: store, wide: false, shown: false)
        settle(controller)
        let before = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
        XCTAssertEqual(before.visibleRowID, "m20#0", "the long reply is still the top row")
        let fraction = try XCTUnwrap(before.visibleRowFraction)
        XCTAssertGreaterThan(fraction, 0.15)
        XCTAssertLessThan(fraction, 0.9)

        seed(before, for: threadID, in: store)
        for wide in [false, true, false] {
            controller.rootView = Host(model: model, store: store, wide: wide)
            settle(controller)
        }
        controller.rootView = Host(model: model, store: store, wide: false, shown: false)
        settle(controller)
        let after = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
        XCTAssertEqual(after.visibleRowID, "m20#0")
        XCTAssertEqual(try XCTUnwrap(after.visibleRowFraction), fraction, accuracy: 0.05)
    }

    /// A search result opens with its match's first line at the top of the
    /// viewport, also a reply taller than the viewport (a phone, a narrow
    /// Duo pane), whichever side of the viewport it was on: a loaded row
    /// above a following reader, one below a reader at the top, and the page
    /// read around it into a detail that opened empty. Scrolling the least
    /// amount to a tall row above the viewport shows its end.
    func testASearchLandingStartsATallMatchAtItsTop() throws {
        for (approach, count, match) in [("above", 40, 10), ("below", 40, 30), ("seek", 0, 110)] {
            let model = try makeModel(messageCount: count, tallIndex: approach == "seek" ? nil : match)
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            if approach == "below" {
                var held = AgentThreadPresentationState()
                held.followingLatest = false
                held.visibleRowID = "m0#0"
                held.positionedThread = threadID
                held.windowAtLiveHead = true
                seed(held, for: threadID, in: store)
            }
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
            let window = try mount(controller)
            defer { unmount(window) }
            settle(controller)
            XCTAssertTrue(model.beginSearchLanding(.init(threadID: threadID, recordID: "m\(match)", excerpt: "message")))
            if approach == "seek" {
                model.loadingTranscriptThreads.insert(threadID)
                settle(controller)
                let current = try XCTUnwrap(model.threadSnapshots[threadID])
                let page = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"""
                    {"version":2,"epoch":"e","viewportSegmentIDs":["k"],"headSegmentID":"s",
                     "before":"b100","after":"a140","hasOlder":true,"hasNewer":true,"atLiveHead":false,
                     "transition":"seek","retainsOutgoing":false,"olderPageFits":false}
                    """#.utf8))
                model.apply(thread: .init(summary: current.summary, messages: (100..<140).map { index in
                    AgentMessage(recordID: "m\(index)", role: .assistant, displayTime: nil,
                        blocks: [.text("message \(index) · " + String(repeating: "retained prose ", count: index == match ? 900 : 8))])
                }, cursor: "b100", hasMore: true, binding: current.binding, ingestionWindow: page))
                model.loadingTranscriptThreads.remove(threadID)
            }
            settle(controller)
            settle(controller)
            XCTAssertNil(model.searchLanding, "\(approach): the landing finished")
            controller.rootView = Host(model: model, store: store, wide: false, shown: false)
            settle(controller)
            let saved = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertEqual(saved.visibleRowID, "m\(match)#0", approach)
            XCTAssertEqual(saved.visibleRowFraction ?? 1, 0, accuracy: 0.01, "\(approach): the reader starts at the match's first line")
        }
    }

    /// A page read around a match into a detail that opened empty shows its
    /// newest rows for at least a frame before the match lands. The edge
    /// reveals that range set off must not pin it back over the landing's,
    /// which left the match outside the rendered rows (iPad cold 3a: the
    /// detail rested on a later record, with the match never drawn). Only
    /// the wide layout orders the tasks that way today.
    func testASeekPageLandsAtItsMatchWhenItsNewestRowsShowFirst() throws {
        for wide in [false, true] {
            let model = try makeModel(messageCount: 0)
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: wide))
            let window = try mount(controller)
            defer { unmount(window) }
            settle(controller)
            // Rows of even height, far more than the rendered budget holds,
            // with the match mid-page, as m9-long's.
            XCTAssertTrue(model.beginSearchLanding(.init(threadID: threadID, recordID: "m1025", excerpt: "m9 record 1025")))
            model.loadingTranscriptThreads.insert(threadID)
            settle(controller)
            let current = try XCTUnwrap(model.threadSnapshots[threadID])
            let page = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"""
                {"version":2,"epoch":"e","viewportSegmentIDs":["k"],"headSegmentID":"s",
                 "before":"b1000","after":"a1050","hasOlder":true,"hasNewer":true,"atLiveHead":false,
                 "transition":"seek","retainsOutgoing":false,"olderPageFits":false}
                """#.utf8))
            model.apply(thread: .init(summary: current.summary, messages: (1000...1050).map { index in
                AgentMessage(recordID: "m\(index)", role: .user, displayTime: nil,
                    blocks: [.text("m9 record \(index) " + String(repeating: "x", count: 2_900))])
            }, cursor: "b1000", hasMore: true, binding: current.binding, ingestionWindow: page))
            model.loadingTranscriptThreads.remove(threadID)
            for _ in 0..<3 { settle(controller) }
            XCTAssertNil(model.searchLanding, "wide \(wide): the landing finished")
            controller.rootView = Host(model: model, store: store, wide: wide, shown: false)
            settle(controller)
            let saved = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertEqual(saved.visibleRowID, "m1025#0", "wide \(wide)")
            func record(_ id: String?) -> Int? { id.flatMap { Int($0.dropFirst().prefix { $0 != "#" }) } }
            let lower = try XCTUnwrap(record(saved.renderedLowerID), "wide \(wide)")
            let upper = record(saved.renderedUpperID) ?? 1050
            XCTAssertTrue((lower...upper).contains(1025), "wide \(wide): rendered \(lower)...\(upper) must hold the match")
        }
    }

    /// A notification opens the detail at the newest page whatever place its
    /// reader kept: mounted with that request or shown when it comes, the
    /// detail follows the newest page and reports no old row for a later
    /// connection to read.
    func testANotificationOpensTheDetailAtTheNewestPage() throws {
        for mounted in [false, true] {
            let model = try makeModel(messageCount: 40)
            let threadID = try XCTUnwrap(model.selectedThreadID)
            let store = AgentThreadPresentationStore()
            var held = AgentThreadPresentationState()
            held.followingLatest = false
            held.visibleRowID = "m20#0"
            held.positionedThread = threadID
            held.windowAtLiveHead = true
            seed(held, for: threadID, in: store)
            var pins: [String?] = []
            model.onAction = { if case .viewportAnchor(_, let recordID) = $0 { pins.append(recordID) } }
            if !mounted { model.requestLatestOpening(threadID) }
            let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
            let window = try mount(controller)
            defer { unmount(window) }
            settle(controller)
            if mounted {
                XCTAssertEqual(pins.last, "m20", "the kept place shows until the notification")
                model.requestLatestOpening(threadID)
                settle(controller)
            }
            settle(controller)
            XCTAssertNil(model.latestOpening, "mounted \(mounted): the detail took the request")
            XCTAssertFalse(pins.isEmpty, "mounted \(mounted)")
            XCTAssertEqual(pins.last, String?.none, "mounted \(mounted): following, so no row to read later")
            if !mounted { XCTAssertFalse(pins.contains("m20"), "the old row is never reported") }
            controller.rootView = Host(model: model, store: store, wide: false, shown: false)
            settle(controller)
            let saved = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
            XCTAssertTrue(saved.followingLatest, "mounted \(mounted)")
        }
    }

    /// Single-block disclosures are the detail's state: an open result stays
    /// open across a container swap, and only that block opens.
    func testOpenBlockDisclosuresSurviveTheContainerSwap() throws {
        let model = try makeModel(messageCount: 3)
        let threadID = try XCTUnwrap(model.selectedThreadID)
        let store = AgentThreadPresentationStore()
        var held = AgentThreadPresentationState()
        held.expandedToolEntries = ["tools#0"]
        held.expandedBlocks = ["tools#0"]
        seed(held, for: threadID, in: store)
        let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
        let window = try mount(controller)
        defer { unmount(window) }
        settle(controller)
        controller.rootView = Host(model: model, store: store, wide: true)
        settle(controller)
        controller.rootView = Host(model: model, store: store, wide: false, shown: false)
        settle(controller)
        let saved = try XCTUnwrap(store.mountReader(for: threadID, owner: UUID(), snapshot: { .init() }))
        XCTAssertEqual(saved.expandedBlocks, ["tools#0"])

        // The card reads the detail's set: open is taller than closed.
        func height(_ open: Set<String>) -> CGFloat {
            let disclosures = AgentBlockDisclosures()
            disclosures.expanded = open
            let message = AgentMessage(recordID: "tools", role: .assistant, displayTime: nil,
                                       blocks: [.toolResult(preview: String(repeating: "result line\n", count: 12), truncated: false)])
            let view = AgentMessageView(message: message, model: model, promptActionsAvailable: false, isCompact: true,
                                        artifactHostID: threadID.hostID, artifactSessionID: nil)
                .environment(\.agentBlockDisclosures, disclosures)
            return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 600, height: 2_000)).height
        }
        XCTAssertGreaterThan(height(["tools#0"]), height([]) + 60)
        XCTAssertEqual(height(["tools#1"]), height([]), accuracy: 0.5)
    }

    func testRemountDoesNotRestartShortTranscriptPaging() throws {
        let model = try makeModel(messageCount: 1)
        let threadID = try XCTUnwrap(model.selectedThreadID)
        let store = AgentThreadPresentationStore()
        var held = AgentThreadPresentationState()
        held.positionedThread = threadID
        held.windowAtLiveHead = true
        held.requestedCursor = "before"
        held.historyDemand = "before"
        held.automaticPages = 4
        held.fillPages = 3
        seed(held, for: threadID, in: store)
        var requests = 0
        model.onAction = {
            switch $0 {
            case .requestOlderPage, .fillOlderPage, .requestNewerPage, .retainBridgedRows:
                requests += 1
            default: break
            }
        }
        let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
        let window = try mount(controller)
        defer { unmount(window) }
        settle(controller)
        controller.rootView = Host(model: model, store: store, wide: true)
        settle(controller)
        XCTAssertEqual(requests, 0, "layout is not a fresh history gesture")
    }

    func testRootKeepsVisibilityAndRefreshTaskAcrossTheColumnSwap() throws {
        let model = try makeModel(messageCount: 1)
        model.pendingNarrowThreadNavigation = try XCTUnwrap(model.selectedThreadID)
        var refreshes: [TimeInterval] = []
        var visibility: [Bool] = []
        model.onAction = {
            if case .refreshTranscript = $0 { refreshes.append(ProcessInfo.processInfo.systemUptime) }
            if case .detailVisibility(_, let visible) = $0 { visibility.append(visible) }
        }
        let controller = UIHostingController(rootView: RootHost(model: model, wide: false))
        let window = try mount(controller)
        defer { unmount(window) }
        settle(controller)
        XCTAssertFalse(refreshes.isEmpty)
        XCTAssertEqual(visibility, [true])
        controller.rootView = RootHost(model: model, wide: true)
        settle(controller)
        controller.rootView = RootHost(model: model, wide: false)
        settle(controller)
        for (earlier, later) in zip(refreshes, refreshes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, 2.9, "the same root-owned task keeps its original poll deadline")
        }
        XCTAssertEqual(visibility, [true], "rotation must not cancel an in-flight history read")
    }

    func testAccessibilityTypeLeavesTheLaptopViewerItsTranscript() throws {
        // Wrapped at accessibility sizes, the header's chips left the
        // transcript above a laptop fold about 10 pt; on one line they fit.
        var heights: [DynamicTypeSize: CGFloat] = [:]
        var chipLines: [DynamicTypeSize: UIScrollView] = [:]
        for size in [DynamicTypeSize.large, .accessibility3] {
            let model = try makeModel(messageCount: 40, metadata: true)
            let controller = UIHostingController(rootView: LaptopViewerHost(model: model, typeSize: size))
            let window = try mount(controller)
            defer { unmount(window) }
            for _ in 0..<3 { settle(controller) }
            heights[size] = try transcriptScroll(in: controller.view).bounds.height
            chipLines[size] = chipLine(in: controller.view)
        }
        let standard = try XCTUnwrap(heights[.large]), largest = try XCTUnwrap(heights[.accessibility3])
        XCTAssertGreaterThan(standard, 180, "the standard size reads \(standard) pt")
        XCTAssertGreaterThan(largest, 140, "accessibility3 reads \(largest) pt of 300 against \(standard) pt at the standard size")
        XCTAssertNil(chipLines[.large], "the standard size wraps its chips")
        // The chips are still all there, side by side: wider than the viewer
        // and no taller than the line that shows them.
        let line = try XCTUnwrap(chipLines[.accessibility3], "accessibility3 shows its chips on a line that scrolls")
        XCTAssertGreaterThan(line.contentSize.width, line.bounds.width, "the chips read \(line.contentSize.width) pt wide")
        XCTAssertLessThanOrEqual(line.contentSize.height, line.bounds.height + 1, "the chips stay on one line")
        XCTAssertGreaterThan(line.bounds.height, 10, "the chip line reads \(line.bounds.height) pt")
    }

    func testFocusedComposerAndModelOwnedDraftSurviveOnlyForTheSameThread() throws {
        let model = try makeModel(messageCount: 1)
        let threadID = try XCTUnwrap(model.selectedThreadID)
        let store = AgentThreadPresentationStore()
        model.setDraft("unfinished draft\nsecond line", for: threadID)
        let controller = UIHostingController(rootView: Host(model: model, store: store, wide: false))
        let window = try mount(controller)
        defer { unmount(window) }
        settle(controller)
        let original = try composer(in: controller.view)
        XCTAssertTrue(original.becomeFirstResponder())
        settle(controller)
        XCTAssertEqual(model.keyboardFocus, .composer)
        controller.rootView = Host(model: model, store: store, wide: true)
        settle(controller)
        let replacement = try composer(in: controller.view)
        XCTAssertFalse(original === replacement, "exercise the container remount")
        XCTAssertTrue(replacement.isFirstResponder)
        XCTAssertEqual(replacement.text, "unfinished draft\nsecond line")
        XCTAssertEqual(model.draftBinding(for: threadID), replacement.text)
        XCTAssertEqual(model.keyboardFocus, .composer)
        XCTAssertTrue(replacement.resignFirstResponder())
        settle(controller)
        controller.rootView = Host(model: model, store: store, wide: false)
        settle(controller)
        XCTAssertFalse(try composer(in: controller.view).isFirstResponder, "an unfocused composer must not open a keyboard on rotation")
    }

    // Match the two structural locations in the root: a pushed narrow detail
    // and a wide HStack child. The real detail, composer and transcript run.
    private struct Host: View {
        let model: AgentCenterV2PresentationModel
        let store: AgentThreadPresentationStore
        let wide: Bool
        var height: CGFloat = 700
        var shown = true
        var card: CardBox?

        var body: some View {
            Group {
                if !shown {
                    Color.clear
                } else if wide {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 300)
                        AgentThreadDetailView(model: model, isCompact: false)
                    }
                } else {
                    NavigationStack {
                        AgentThreadDetailView(model: model, isCompact: true)
                    }
                }
            }
            .environment(store)
            .onPreferenceChange(AgentPromptCardPreference.self) { card?.frame = $0?.frame }
            .frame(width: wide ? 940 : 600, height: height)
        }
    }

    private final class CardBox { var frame: CGRect? }

    /// The viewer above a laptop-folded Duo's fold, at an iPhone's width.
    private struct LaptopViewerHost: View {
        let model: AgentCenterV2PresentationModel
        let typeSize: DynamicTypeSize

        var body: some View {
            AgentThreadDetailView(model: model, isCompact: true, isLaptopViewer: true)
                .environment(AgentThreadPresentationStore())
                .dynamicTypeSize(typeSize)
                .frame(width: 402, height: 300)
        }
    }

    private struct RootHost: View {
        let model: AgentCenterV2PresentationModel
        let wide: Bool

        var body: some View {
            AgentCenterV2RootView(model: model, includesNavigationSidebar: false) { EmptyView() }
                .frame(width: wide ? 940 : 600, height: 700)
        }
    }

    private func makeModel(messageCount: Int, atLiveHead: Bool = true, tallIndex: Int? = nil,
                           prompt: AgentActionPrompt? = nil, metadata: Bool = false) throws -> AgentCenterV2PresentationModel {
        let model = AgentCenterV2PresentationModel()
        let id = AgentThreadID(hostID: UUID(), providerID: .claude, providerSessionID: "presentation")!
        var summary = AgentThreadSummary(id: id, providerName: "claude", status: prompt == nil ? .idle : .waitingForInput,
            availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true))
        if metadata {
            // Every chip the header shows, as a busy thread has them.
            summary.model = "opus"
            summary.permissionMode = .plan
            summary.projectBasename = "tessera"
            summary.branch = "fix/files-flicker"
            summary.context = .init(percentUsed: 62)
            summary.cost = .init(totalCost: Decimal(string: "1.24"))
        }
        let binding = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 1,
            incarnation: AgentIncarnationToken("presentation")!, transport: .sshTmux, tmuxSession: "test",
            windowID: "1", paneID: "1", agentPID: 42, capabilities: [.observe, .send, .tmux])
        let window = try JSONDecoder().decode(AgentIngestionWindowSnapshot.self, from: Data(#"""
            {"version":1,"epoch":"e","viewportSegmentIDs":["s"],"headSegmentID":"s",
             "before":"before","after":"after","hasOlder":true,"hasNewer":false,"atLiveHead":\#(atLiveHead),
             "transition":"bootstrap","retainsOutgoing":false,"olderPageFits":\#(atLiveHead)}
            """#.utf8))
        let messages = (0..<messageCount).map { index in
            AgentMessage(recordID: "m\(index)", role: .assistant, displayTime: nil,
                blocks: [.text("message \(index) · " + String(repeating: "retained prose ", count: index == tallIndex ? 900 : 8))])
        } + [AgentMessage(recordID: "tools", role: .assistant, displayTime: nil,
                          blocks: [.toolCall(name: "Read", preview: "test.swift")])]
          + (prompt.map { [AgentMessage(recordID: "question", role: .assistant, displayTime: nil, blocks: [.actionPrompt($0)])] } ?? [])
        model.apply(list: .init(threads: [summary]))
        model.apply(thread: .init(summary: summary, messages: messages, cursor: "before", hasMore: true,
                                  binding: binding, ingestionWindow: window))
        return model
    }

    private func question(options count: Int) -> AgentActionPrompt {
        AgentActionPrompt(title: "Features", options: (1...count).map {
            .init(id: "\($0)", label: "Option \($0)", detail: "What option \($0) ships.")
        }, token: AgentActionToken("landing-\(count)")!, kind: .question, question: "Which ship first?",
           controls: [.init(kind: .cancel, label: "Cancel")], isBlocking: true)
    }

    private func seed(_ state: AgentThreadPresentationState, for thread: AgentThreadID, in store: AgentThreadPresentationStore) {
        let owner = UUID()
        _ = store.mountReader(for: thread, owner: owner, snapshot: { state })
        store.unmountReader(for: thread, owner: owner)
    }

    private func maximumOffset(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
    }

    private func transcriptScroll(in view: UIView) throws -> UIScrollView {
        func find(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height * 2 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view))
    }

    /// The header's sideways chip scroller: the scroll view laid out wider than tall.
    private func chipLine(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.contentSize.height { return scroll }
        return view.subviews.lazy.compactMap(chipLine).first
    }

    private func composer(in view: UIView) throws -> AgentComposerTextView.ComposerTextView {
        func find(_ view: UIView) -> AgentComposerTextView.ComposerTextView? {
            if let composer = view as? AgentComposerTextView.ComposerTextView { return composer }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view))
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 940, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func settle(_ controller: UIViewController) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }
}
