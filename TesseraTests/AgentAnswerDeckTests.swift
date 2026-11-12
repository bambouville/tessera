import SwiftUI
import UIKit
import XCTest
import TesseraCore
@testable import Tessera

@MainActor
final class AgentAnswerDeckPolicyTests: XCTestCase {
    private let hostID = UUID()
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
    private let book = DuoFold(frame: CGRect(x: 413.5, y: 0, width: 40, height: 553), splitsSideBySide: true)

    func testOneTapAnswersSkipTypedOptionsAndLeaveTheRestToTheOverflow() {
        let prompt = prompt(options: [
            option("1"), option("2", acceptsText: true), option("3"), option("4"), option("5")
        ])
        XCTAssertEqual(AgentAnswerDeckPolicy.oneTapOptions(prompt).map(\.id), ["1", "3", "4"])
        XCTAssertEqual(AgentAnswerDeckPolicy.overflowOptions(prompt).map(\.id), ["5"])
        XCTAssertTrue(AgentAnswerDeckPolicy.overflows(prompt))

        let three = self.prompt(options: [option("1"), option("2"), option("3"), option("t", acceptsText: true)])
        XCTAssertEqual(AgentAnswerDeckPolicy.oneTapOptions(three).map(\.id), ["1", "2", "3"])
        XCTAssertTrue(AgentAnswerDeckPolicy.overflowOptions(three).isEmpty)
        XCTAssertFalse(AgentAnswerDeckPolicy.overflows(three), "a typed option is never overflow")
    }

    func testOnlyTheOpenControlBecomesAnAnswerButton() {
        XCTAssertNil(AgentAnswerDeckPolicy.openControl(prompt(options: [option("1")])))
        XCTAssertNil(AgentAnswerDeckPolicy.openControl(prompt(controls: [.init(kind: .skip, label: "Skip")])))
        let open = prompt(controls: [.init(kind: .skip, label: "Skip"), .init(kind: .open, label: "Open")])
        XCTAssertEqual(AgentAnswerDeckPolicy.openControl(open)?.kind, .open)
    }

    func testTheLatestPromptIsTheFirstInTheNewestMessageThatHasOne() {
        let old = prompt(options: [option("old")])
        let first = prompt(options: [option("first")])
        let second = prompt(options: [option("second")])
        let messages = [
            message("a", [.actionPrompt(old)]),
            message("b", [.text("thinking"), .actionPrompt(first), .actionPrompt(second)]),
            message("c", [.text("still thinking")])
        ]
        XCTAssertEqual(AgentAnswerDeckPolicy.latestPrompt(in: messages), first)
        XCTAssertNil(AgentAnswerDeckPolicy.latestPrompt(in: [message("c", [.text("no prompt")])]))
        XCTAssertNil(AgentAnswerDeckPolicy.latestPrompt(in: []))
    }

    /// Laptop pose stacks the thread over the list across the whole width,
    /// even where the inner screen would fit two columns; nothing else changes.
    func testOnlyLaptopPoseLaysTheThreadOverTheList() {
        XCTAssertTrue(AgentAnswerDeckPolicy.isLaptop(laptop))
        XCTAssertFalse(AgentAnswerDeckPolicy.isLaptop(book))
        XCTAssertFalse(AgentAnswerDeckPolicy.isLaptop(nil))
        for width: CGFloat in [393, 669, 867, 1194] {
            for sidebar in [false, true] {
                for rail in [false, true] {
                    let wide = AgentRailPolicy.usesTwoColumns(width: width, includesNavigationSidebar: sidebar, railMode: rail)
                    XCTAssertEqual(
                        AgentAnswerDeckPolicy.layout(width: width, includesNavigationSidebar: sidebar, railMode: rail, laptop: false),
                        wide ? .twoColumns : .narrow
                    )
                    XCTAssertEqual(
                        AgentAnswerDeckPolicy.layout(width: width, includesNavigationSidebar: sidebar, railMode: rail, laptop: true),
                        .laptop
                    )
                }
            }
        }
        XCTAssertTrue(AgentRailPolicy.usesTwoColumns(width: 669, includesNavigationSidebar: false, railMode: false),
                      "the laptop's inner width alone would pick two columns")
    }

    /// The narrow stack shows the list or a thread; two columns and laptop
    /// pose show the selected thread beside the list whether or not a route
    /// is pushed.
    func testOnlyTheNarrowStackHidesTheThreadBehindTheList() {
        let shown = threadID("shown")
        XCTAssertFalse(AgentAnswerDeckPolicy.detailVisible(layout: .narrow, pushed: false))
        XCTAssertTrue(AgentAnswerDeckPolicy.detailVisible(layout: .narrow, pushed: true))
        for layout: AgentCenterLayout in [.twoColumns, .laptop] {
            XCTAssertTrue(AgentAnswerDeckPolicy.detailVisible(layout: layout, pushed: false))
            XCTAssertTrue(AgentAnswerDeckPolicy.detailVisible(layout: layout, pushed: true))
            XCTAssertEqual(AgentAnswerDeckPolicy.threadShownBeside(layout: layout, shown: shown), shown)
        }
        XCTAssertNil(AgentAnswerDeckPolicy.threadShownBeside(layout: .narrow, shown: shown),
                     "a pushed thread covers the list instead of sharing the screen")
        XCTAssertNil(AgentAnswerDeckPolicy.threadShownBeside(layout: .laptop, shown: nil))
    }

    // MARK: Answers on rows

    func testWaitingRowsShowTheirAnswersUnlessTheirThreadIsOpenBeside() {
        let folds = AgentRowAnswerFolds()
        let key = foldKey("a", token: "t1")
        XCTAssertTrue(folds.isOpen(key, shownBeside: false), "open by default")
        XCTAssertFalse(folds.isOpen(key, shownBeside: true), "the prompt is already on screen beside the list")
        XCTAssertTrue(AgentRowAnswerFolds.pointsToDetail(isOpen: false, shownBeside: true))
        XCTAssertFalse(AgentRowAnswerFolds.pointsToDetail(isOpen: true, shownBeside: true))
        XCTAssertFalse(AgentRowAnswerFolds.pointsToDetail(isOpen: false, shownBeside: false),
                       "a row folded by hand points nowhere")
    }

    func testTheChevronFoldsOrOpensARowForThatPromptOnly() {
        var folds = AgentRowAnswerFolds()
        let open = foldKey("a", token: "t1"), beside = foldKey("b", token: "t9")
        folds.flip(open, shownBeside: false)
        folds.flip(beside, shownBeside: true)
        XCTAssertFalse(folds.isOpen(open, shownBeside: false), "folded by hand")
        XCTAssertTrue(folds.isOpen(beside, shownBeside: true), "opened by hand while its thread is beside")
        XCTAssertTrue(folds.isOpen(foldKey("c", token: "t1"), shownBeside: false),
                      "another thread's row with the same token keeps its own state")

        folds.flip(open, shownBeside: false)
        XCTAssertTrue(folds.isOpen(open, shownBeside: false), "a second tap opens it again")
    }

    /// The fold lasts for the question wherever its thread is shown: opening
    /// a thread whose row was folded by hand keeps it folded, and a row
    /// opened by hand beside the thread stays open once another is opened.
    func testAHandFoldLastsWhenTheThreadMovesBesideTheList() {
        var folds = AgentRowAnswerFolds()
        let folded = foldKey("a", token: "t1"), opened = foldKey("b", token: "t2")
        folds.flip(folded, shownBeside: false)
        folds.flip(opened, shownBeside: true)
        XCTAssertFalse(folds.isOpen(folded, shownBeside: true))
        XCTAssertFalse(AgentRowAnswerFolds.pointsToDetail(isOpen: folds.isOpen(folded, shownBeside: false), shownBeside: false))
        XCTAssertTrue(folds.isOpen(opened, shownBeside: false))
    }

    func testTheAgentsNextPromptArrivesInItsDefaultState() {
        var folds = AgentRowAnswerFolds()
        folds.flip(foldKey("a", token: "t1"), shownBeside: false)
        let next = foldKey("a", token: "t2")
        XCTAssertTrue(folds.isOpen(next, shownBeside: false))
        XCTAssertFalse(folds.isOpen(next, shownBeside: true))

        folds.flip(next, shownBeside: true)
        XCTAssertEqual(folds.chosen, [next: true], "an older prompt's choice is spent once the next is flipped")
        XCTAssertTrue(folds.isOpen(foldKey("a", token: "t1"), shownBeside: false))
    }

    func testThreadsLeavingTheListTakeTheirFoldsWithThem() {
        var folds = AgentRowAnswerFolds()
        folds.flip(foldKey("a", token: "t1"), shownBeside: false)
        folds.flip(foldKey("b", token: "t2"), shownBeside: false)
        folds.prune(retaining: [threadID("b"), threadID("c")])
        XCTAssertEqual(folds.chosen, [foldKey("b", token: "t2"): false])
        folds.prune(retaining: [])
        XCTAssertTrue(folds.chosen.isEmpty)
    }

    /// The detail is rebuilt when the pose changes; its prompt card reads the
    /// typed answer back from the root, per thread and prompt.
    func testTypedPromptAnswersAreKeptPerThreadAndPrompt() {
        let drafts = AgentPromptAnswerDrafts()
        let a1 = AgentPromptAnswerDrafts.Key(thread: threadID("a"), token: "t1")
        let a2 = AgentPromptAnswerDrafts.Key(thread: threadID("a"), token: "t2")
        let b1 = AgentPromptAnswerDrafts.Key(thread: threadID("b"), token: "t1")
        XCTAssertEqual(drafts[a1], .init(), "an untouched card starts closed and empty")
        drafts[a1] = .init(isOpen: true, text: "keep the 2024 thumbnails")
        XCTAssertEqual(drafts[a1].text, "keep the 2024 thumbnails")
        XCTAssertEqual(drafts[a2], .init(), "the thread's next prompt starts empty")
        XCTAssertEqual(drafts[b1], .init(), "the same screen in another thread starts empty")
        drafts.prune(retaining: [threadID("b")])
        XCTAssertEqual(drafts[a1], .init(), "a thread leaving the list takes its answers with it")
    }

    // MARK: Laptop pose

    /// iOS reports the keyboard from the fold's top in laptop pose: only a
    /// proposal ending above the fold's bottom covers the desk. A session's
    /// own keyboard report counts as well.
    func testTheDeskIsCoveredOnlyByAKeyboardReachingTheFold() {
        let fold = DuoFold(frame: CGRect(x: 0, y: 431.5, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertFalse(AgentLaptopPolicy.isTyping(keyboardUp: false, container: CGSize(width: 669, height: 893), fold: fold))
        XCTAssertFalse(AgentLaptopPolicy.isTyping(keyboardUp: false, container: CGSize(width: 669, height: 893 - 70), fold: fold),
                       "a hardware keyboard's shortcut bar leaves the list standing")
        XCTAssertTrue(AgentLaptopPolicy.isTyping(keyboardUp: false, container: CGSize(width: 669, height: 431.5), fold: fold))
        XCTAssertTrue(AgentLaptopPolicy.isTyping(keyboardUp: true, container: CGSize(width: 669, height: 893), fold: fold))
        XCTAssertEqual(AgentLaptopPolicy.restingDeskHeight(container: CGSize(width: 669, height: 893), fold: fold), 893 - 471.5)
        XCTAssertEqual(AgentLaptopPolicy.restingDeskHeight(container: CGSize(width: 669, height: 300), fold: fold), 0)
    }

    /// The hinge holds the composer, the list's search while it is open, and
    /// nothing while a prompt is answered in words: its card rides there.
    func testTheHingeHoldsOneInputAtATime() {
        typealias Focus = AgentCenterV2PresentationModel.KeyboardFocus
        for focus: Focus in [.none, .list, .search, .composer, .promptAnswer, .action] {
            for typing in [false, true] {
                XCTAssertEqual(AgentLaptopPolicy.hingeRow(searchOpen: true, focus: focus, typing: typing), .search)
            }
            XCTAssertEqual(AgentLaptopPolicy.hingeRow(searchOpen: false, focus: focus, typing: false), .composer,
                           "a hardware keyboard needs nothing to move")
            XCTAssertEqual(AgentLaptopPolicy.hingeRow(searchOpen: false, focus: focus, typing: true),
                           focus == .promptAnswer ? .promptCard : .composer)
        }
    }

    func testSearchMatchesFillTheViewerOnlyWhileTheKeyboardCoversTheList() {
        XCTAssertTrue(AgentLaptopPolicy.showsSearchMatchesAbove(row: .search, typing: true, query: "retry"))
        XCTAssertFalse(AgentLaptopPolicy.showsSearchMatchesAbove(row: .search, typing: true, query: ""))
        XCTAssertFalse(AgentLaptopPolicy.showsSearchMatchesAbove(row: .search, typing: false, query: "retry"),
                       "with the list in view, its own matches are enough")
        XCTAssertFalse(AgentLaptopPolicy.showsSearchMatchesAbove(row: .composer, typing: true, query: "retry"))
    }

    // MARK: Fixtures

    private func threadID(_ session: String) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: .claude, providerSessionID: session)!
    }

    private func foldKey(_ session: String, token: String) -> AgentRowAnswerFolds.Key {
        AgentRowAnswerFolds.Key(thread: threadID(session), token: AgentActionToken(token)!)
    }

    private func prompt(
        options: [TesseraCore.AgentPromptOption] = [], controls: [AgentPromptControl]? = nil
    ) -> AgentActionPrompt {
        AgentActionPrompt(title: "Allow?", options: options, token: AgentActionToken(UUID().uuidString)!,
                          question: "Run the migration?", controls: controls)
    }

    private func option(_ id: String, acceptsText: Bool? = nil) -> TesseraCore.AgentPromptOption {
        TesseraCore.AgentPromptOption(id: id, label: "Option \(id)", acceptsText: acceptsText)
    }

    private func message(_ id: String, _ blocks: [AgentBlock]) -> AgentMessage {
        AgentMessage(recordID: id, role: .assistant, displayTime: nil, blocks: blocks)
    }
}

