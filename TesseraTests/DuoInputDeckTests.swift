import SwiftUI
import UIKit
import XCTest
@testable import Tessera

final class DuoInputDeckTests: XCTestCase {
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
    private let book = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 635), splitsSideBySide: true)

    func testLaptopKeepsContentAboveTheFoldAndRestsTheDeckOnTheHinge() throws {
        let container = CGSize(width: 669, height: 835)
        let expected = try XCTUnwrap(DuoPaneGeometry.deckSplit(container: container, fold: laptop))
        let actual = try XCTUnwrap(DuoInputDeckLayout.split(container: container, fold: laptop))
        XCTAssertEqual(actual.content, expected.content)
        XCTAssertEqual(actual.content.maxY, laptop.frame.minY)
        XCTAssertEqual(actual.deck.minY, laptop.frame.minY)
        XCTAssertEqual(actual.deck.maxY, container.height)
        XCTAssertFalse(actual.content.intersects(laptop.frame))
    }

    func testNoFoldAndBookUseTheOrdinaryStack() {
        let container = CGSize(width: 669, height: 835)
        XCTAssertNil(DuoInputDeckLayout.split(container: container, fold: nil))
        XCTAssertNil(DuoInputDeckLayout.split(container: container, fold: book))
    }

    func testKeyboardShrinksOnlyTheDeckAndNeverMovesOrResizesContent() throws {
        let before = try XCTUnwrap(DuoInputDeckLayout.split(container: CGSize(width: 669, height: 835), fold: laptop))
        let keyboard = try XCTUnwrap(DuoInputDeckLayout.split(container: CGSize(width: 669, height: 520), fold: laptop))
        let atFold = try XCTUnwrap(DuoInputDeckLayout.split(container: CGSize(width: 669, height: 373.5), fold: laptop))
        XCTAssertEqual(before.content, keyboard.content)
        XCTAssertEqual(before.content, atFold.content)
        XCTAssertEqual(keyboard.deck.minY, before.deck.minY)
        XCTAssertEqual(atFold.deck.minY, before.deck.minY)
        XCTAssertEqual(keyboard.deck.maxY, 520)
        XCTAssertEqual(atFold.deck.height, 0)
    }

    func testLaptopKeyboardShowHideChangesNoTerminalSizesAndKeepsDeckAboveKeyboard() throws {
        var contentFrames: [CGRect] = []
        for resizePreference in [false, true] {
            for keyboardHeight: CGFloat in [0, 315, 445, 515, 0] {
                let proposedHeight = 835 - keyboardHeight
                let session = TerminalKeyboardLayoutPolicy.layout(
                    proposedHeight: proposedHeight, retainedHeight: 835,
                    resizesTerminal: resizePreference, foldedLayoutActive: true
                )
                XCTAssertEqual(session.lift, 0)
                XCTAssertEqual(session.height, proposedHeight)
                let split = try XCTUnwrap(DuoInputDeckLayout.split(
                    container: CGSize(width: 669, height: session.height), fold: laptop,
                    minimumDeckHeight: 44, contentReserve: 44
                ))
                contentFrames.append(split.content)
                XCTAssertEqual(split.content.maxY, laptop.frame.minY - 44)
                XCTAssertEqual(split.deck.maxY, proposedHeight)
                XCTAssertGreaterThanOrEqual(split.deck.height, 44)
                XCTAssertEqual(split.deck.minY, min(laptop.frame.minY, proposedHeight) - 44)
                if proposedHeight >= laptop.frame.minY {
                    XCTAssertEqual(split.deck.minY, split.content.maxY, "the bar must not cover the terminal")
                }
            }
        }
        XCTAssertTrue(contentFrames.allSatisfy { $0 == contentFrames.first })
        XCTAssertEqual(zip(contentFrames, contentFrames.dropFirst()).filter { $0 != $1 }.count, 0)
    }

    func testUnfoldedKeyboardLayoutKeepsEveryExistingLiftAndRetainedHeight() {
        for resizePreference in [false, true] {
            for proposed: CGFloat in [835, 520, 390, 835] {
                let actual = TerminalKeyboardLayoutPolicy.layout(
                    proposedHeight: proposed, retainedHeight: 835,
                    resizesTerminal: resizePreference, foldedLayoutActive: false
                )
                XCTAssertEqual(actual.height, resizePreference ? proposed : 835)
                XCTAssertEqual(actual.lift, resizePreference ? 0 : max(0, 835 - proposed))
            }
        }
    }

    /// iOS 27.1 on a partially folded Duo reports the keyboard from the fold's
    /// top and takes touches above its keys, so the deck stays on the hinge.
    func testTheDeckRestsOnTheHingeInEveryKeyboardStateAndTheContentKeepsTheBarClear() throws {
        let hinge = laptop.frame.minY
        for container: CGFloat in [835, 520, hinge] {
            let split = try XCTUnwrap(DuoInputDeckLayout.split(
                container: CGSize(width: 669, height: container), fold: laptop,
                minimumDeckHeight: 52, contentReserve: 52
            ))
            XCTAssertEqual(split.content, CGRect(x: 0, y: 0, width: 669, height: hinge - 52))
            XCTAssertEqual(split.deck.minY, hinge - 52)
            XCTAssertEqual(split.deck.maxY, container)
        }
        let replies = try XCTUnwrap(DuoInputDeckLayout.split(
            container: CGSize(width: 669, height: hinge), fold: laptop,
            minimumDeckHeight: 52 + 56, contentReserve: 52
        ))
        XCTAssertEqual(replies.content.height, hinge - 52, "agent replies overlap the terminal instead of resizing it")
        XCTAssertEqual(replies.deck.minY, hinge - 108)
        let tall = try XCTUnwrap(DuoInputDeckLayout.split(
            container: CGSize(width: 669, height: 300), fold: laptop,
            minimumDeckHeight: 52, contentReserve: 52
        ))
        XCTAssertEqual(tall.content.height, hinge - 52)
        XCTAssertEqual(tall.deck.minY, 248, "a keyboard above the hinge lifts only the deck")
    }

    /// Folding with the keyboard up: the session observes the fold inside a
    /// lift the folded layout then drops. Both passes report one fold.
    func testAFoldSeenThroughTheKeyboardLiftIsReportedOnceAcrossEnteringTheFoldedLayout() {
        let resting = DuoFold(frame: CGRect(x: 0, y: 418, width: 402, height: 26), splitsSideBySide: false)
        var reported: [DuoFold] = []
        for folded in [false, true] {
            let lift = TerminalKeyboardLayoutPolicy.layout(
                proposedHeight: 520, retainedHeight: 835, resizesTerminal: false, foldedLayoutActive: folded
            ).lift
            // The offset moves the view up by the lift, so the region reads lower by as much.
            let observed = DuoFold(frame: resting.frame.offsetBy(dx: 0, dy: lift), splitsSideBySide: false)
            reported.append(observed.removingContentLift(lift))
        }
        XCTAssertEqual(reported, [resting, resting])
    }

    func testReturningToTheSameSettledFoldGivesTheSameFrames() throws {
        let container = CGSize(width: 669, height: 835)
        let before = try XCTUnwrap(DuoInputDeckLayout.split(container: container, fold: laptop))
        XCTAssertNil(DuoInputDeckLayout.split(container: container, fold: nil))
        let after = try XCTUnwrap(DuoInputDeckLayout.split(container: container, fold: laptop))
        XCTAssertEqual(before.content, after.content)
        XCTAssertEqual(before.deck, after.deck)
    }

    func testMovingFoldHoldsThePreviousGeometryUntilOneSettledChange() throws {
        var now: TimeInterval = 0
        var gate = DuoSettleGate(now: { now })
        var settlement = DuoFoldSettlement()
        XCTAssertTrue(settlement.update(current: nil, hinge: .none))
        XCTAssertEqual(gate.hingeChanged(.partiallyOpen), .moving)
        XCTAssertFalse(settlement.update(current: laptop, hinge: gate.state))
        XCTAssertNil(DuoInputDeckLayout.split(container: CGSize(width: 669, height: 835), fold: settlement.fold))

        now = 0.2
        XCTAssertNil(gate.hingeChanged(.partiallyOpen))
        let moving = DuoFold(frame: CGRect(x: 0, y: 350, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertFalse(settlement.update(current: moving, hinge: gate.state))
        now = 0.49
        XCTAssertNil(gate.settle())
        now = 0.51
        XCTAssertEqual(gate.settle(), .settled(.partiallyOpen))
        XCTAssertTrue(settlement.update(current: laptop, hinge: gate.state))
        let settled = try XCTUnwrap(DuoInputDeckLayout.split(container: CGSize(width: 669, height: 835), fold: settlement.fold))
        XCTAssertEqual(settled.content.height, 373.5)
        XCTAssertFalse(settlement.update(current: laptop, hinge: gate.state))
        XCTAssertNil(gate.settle())
    }

    // MARK: Laptop bar: pill while typing, desk after

    private func frames(
        open: Bool, keyboardUp: Bool, edge: HorizontalEdge = .trailing, replies: CGFloat = 0
    ) throws -> DuoDeckFrames {
        let placement = DuoDeckPlacement.resolve(DuoDeckBar(openWhileTyping: open, edge: edge), keyboardUp: keyboardUp)
        let hinge = laptop.frame.minY
        return try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: keyboardUp ? hinge : 835), fold: laptop, placement: placement,
            deckSize: CGSize(width: placement.isPill ? 100 : 669, height: 52), deskHeight: replies
        ))
    }

    func testTheBarFoldsToThePillOnlyWhileTypingWithTheBarClosed() {
        let closed = DuoDeckBar(openWhileTyping: false, edge: .leading)
        let open = DuoDeckBar(openWhileTyping: true, edge: .leading)
        XCTAssertEqual(DuoDeckPlacement.resolve(closed, keyboardUp: true), DuoDeckPlacement(bar: .pill, keyboardUp: true, edge: .leading))
        XCTAssertEqual(DuoDeckPlacement.resolve(closed, keyboardUp: false).bar, .desk)
        XCTAssertEqual(DuoDeckPlacement.resolve(open, keyboardUp: true).bar, .hinge)
        XCTAssertEqual(DuoDeckPlacement.resolve(open, keyboardUp: false).bar, .desk, "reading, the bar covers nothing")
        XCTAssertTrue(DuoDeckPlacement.resolve(closed, keyboardUp: true).hidesDesk)
        XCTAssertFalse(DuoDeckPlacement.resolve(closed, keyboardUp: false).hidesDesk)
        XCTAssertFalse(DuoDeckPlacement.resolve(open, keyboardUp: true).hidesDesk)
    }

    /// No accessory bar means no pill to fold to and no dot on it, so the
    /// replies must not vanish while typing.
    func testWithTheAccessoryBarOffTheRepliesKeepTheHingeWhileTyping() {
        let appearance = AppearancePreferences()
        let saved = (appearance.showAccessoryBar, appearance.duoBarOpenWhileTyping)
        defer {
            appearance.showAccessoryBar = saved.0
            appearance.duoBarOpenWhileTyping = saved.1
        }
        appearance.duoBarOpenWhileTyping = false
        appearance.showAccessoryBar = false
        let typing = DuoDeckPlacement.resolve(DuoDeckBar(appearance), keyboardUp: true)
        XCTAssertEqual(typing.bar, .hinge)
        XCTAssertFalse(typing.hidesDesk)
        appearance.showAccessoryBar = true
        XCTAssertEqual(DuoDeckPlacement.resolve(DuoDeckBar(appearance), keyboardUp: true).bar, .pill)
    }

    /// An older build stored the open bar, which then covered the terminal's
    /// bottom rows every time the keyboard rose. Typing starts at the pill.
    func testABarOpenedWhileTypingIsNotKeptForTheNextKeyboard() {
        let key = "tessera.pref.duoBarOpenWhileTyping"
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let appearance = AppearancePreferences()
        XCTAssertFalse(appearance.duoBarOpenWhileTyping)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertEqual(DuoDeckPlacement.resolve(DuoDeckBar(appearance), keyboardUp: true).bar, .pill)

        appearance.duoBarOpenWhileTyping = true
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "the chevron's choice is never stored")
    }

    /// A context on the desk covers the overlay below the fold; the floating
    /// puck's canvas stops there, in the overlay's own terms.
    func testTheFloatingPuckKeepsAboveTheDeskFloor() {
        let overlay = CGRect(x: 84, y: 120, width: 649, height: 800)
        let size = overlay.size
        XCTAssertEqual(SwipePadOverlay.floatingCanvas(size, in: overlay, floor: nil), size)
        XCTAssertEqual(SwipePadOverlay.floatingCanvas(size, in: overlay, floor: 455.5),
                       CGSize(width: 649, height: 335.5))
        XCTAssertEqual(SwipePadOverlay.floatingCanvas(size, in: overlay, floor: 2000), size, "never taller than the overlay")
        XCTAssertEqual(SwipePadOverlay.floatingCanvas(size, in: overlay, floor: 60).height, 0)
    }

    /// Neither the keyboard nor the bar resizes the terminal: it keeps the
    /// whole top half, and the open bar floats over its bottom rows.
    func testNeitherTheKeyboardNorTheBarResizesTheContent() throws {
        let hinge = laptop.frame.minY
        for open in [false, true] {
            for replies: CGFloat in [0, 56] {
                for keyboardUp in [false, true] {
                    let frames = try frames(open: open, keyboardUp: keyboardUp, replies: replies)
                    XCTAssertEqual(frames.content, CGRect(x: 0, y: 0, width: 669, height: hinge))
                }
            }
        }
    }

    func testThePillRestsAboveTheHingeAtItsEdge() throws {
        let hinge = laptop.frame.minY
        let trailing = try frames(open: false, keyboardUp: true)
        XCTAssertEqual(trailing.deck, CGRect(x: 669 - 8 - 100, y: hinge - 6 - 52, width: 100, height: 52))
        let leading = try frames(open: false, keyboardUp: true, edge: .leading)
        XCTAssertEqual(leading.deck, CGRect(x: 8, y: hinge - 6 - 52, width: 100, height: 52))
        XCTAssertTrue(trailing.content.contains(trailing.deck), "the pill floats over the terminal")
    }

    func testTheClosedBarOpensAtTheTopOfTheDeskWithRepliesBelowIt() throws {
        let desk = try frames(open: false, keyboardUp: false, replies: 56)
        XCTAssertEqual(desk.deck, CGRect(x: 0, y: laptop.frame.maxY, width: 669, height: 52))
        XCTAssertEqual(desk.desk, CGRect(x: 0, y: laptop.frame.maxY + 52, width: 669, height: 835 - laptop.frame.maxY - 52))
        XCTAssertFalse(desk.deck.intersects(laptop.frame))
    }

    /// While typing, the open bar and the replies over it float across the
    /// terminal's bottom rows; with the keyboard down they open on the desk.
    func testTheOpenBarFloatsOnTheHingeWhileTypingAndOpensOnTheDeskAfter() throws {
        let hinge = laptop.frame.minY
        let typing = try frames(open: true, keyboardUp: true, replies: 56)
        XCTAssertEqual(typing.deck.minY, hinge - 52)
        XCTAssertEqual(typing.desk, CGRect(x: 0, y: hinge - 52 - 56, width: 669, height: 56))
        XCTAssertTrue(typing.content.contains(typing.deck), "the open bar floats over the terminal")
        let resting = try frames(open: true, keyboardUp: false, replies: 56)
        XCTAssertEqual(resting.deck, CGRect(x: 0, y: laptop.frame.maxY, width: 669, height: 52))
        XCTAssertEqual(resting.desk?.minY, laptop.frame.maxY + 52)
        XCTAssertEqual(resting.desk?.maxY, 835)
        XCTAssertFalse(resting.content.intersects(resting.deck))
    }

    /// The terminal slides up only as far as its caret needs, and keeps its
    /// bottom rows in view when it cannot follow the caret.
    func testTheTerminalLiftsOnlyAsFarAsTheCaretNeedsUnderTheOpenBar() {
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 0, below: 0), 0)
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 0, below: nil), 0, "nothing covers the terminal")
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 52, below: 200), 0, "the caret is well clear")
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 52, below: 34), 18, "one row for a prompt above a footer")
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 52, below: 0), 52, "a caret on the last row clears the bar")
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 52, below: -3), 52)
        XCTAssertEqual(DuoDeckCaretPolicy.lift(cover: 108, below: nil), 108, "a full-screen app keeps its bottom rows")
    }

    /// A composer rides the hinge while typing with its replies above it and
    /// the content ending above both; after, it opens at the desk's top.
    func testAComposerRestsOnTheHingeWhileTypingAndOpensOnTheDeskAfter() throws {
        let hinge = laptop.frame.minY
        let typing = DuoDeckPlacement.resolve(.composer, keyboardUp: true)
        XCTAssertEqual(typing.bar, .hinge)
        XCTAssertTrue(typing.clearsContent)
        XCTAssertFalse(typing.hidesDesk)
        XCTAssertEqual(DuoDeckPlacement.resolve(.composer, keyboardUp: false).bar, .desk)

        let up = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: hinge), fold: laptop, placement: typing,
            deckSize: CGSize(width: 669, height: 58), deskHeight: 56
        ))
        XCTAssertEqual(up.deck, CGRect(x: 0, y: hinge - 58, width: 669, height: 58))
        XCTAssertEqual(up.desk, CGRect(x: 0, y: hinge - 58 - 56, width: 669, height: 56))
        XCTAssertEqual(up.content, CGRect(x: 0, y: 0, width: 669, height: hinge - 58 - 56), "nothing reads under the composer")

        let down = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: 835), fold: laptop,
            placement: DuoDeckPlacement.resolve(.composer, keyboardUp: false),
            deckSize: CGSize(width: 669, height: 58), deskHeight: 56
        ))
        XCTAssertEqual(down.content, CGRect(x: 0, y: 0, width: 669, height: hinge))
        XCTAssertEqual(down.deck, CGRect(x: 0, y: laptop.frame.maxY, width: 669, height: 58))
        XCTAssertEqual(down.desk, CGRect(x: 0, y: laptop.frame.maxY + 58, width: 669, height: 835 - laptop.frame.maxY - 58))
    }

    /// Agent Center's laptop viewer: its composer docks just above the fold
    /// in both keyboard states, at its own height, with the transcript ending
    /// above it. The desk is the thread list, a page of its own: it fills the
    /// desk with the keyboard down and waits under the keyboard, hidden, while
    /// typing, so nothing stacks over the hinge.
    func testTheViewerComposerRestsOnTheHingeAndTheListWaitsUnderTheKeyboard() throws {
        let hinge = laptop.frame.minY
        let typing = DuoDeckPlacement.resolve(.viewerComposer, keyboardUp: true)
        let resting = DuoDeckPlacement.resolve(.viewerComposer, keyboardUp: false)
        XCTAssertEqual(typing.bar, .hinge)
        XCTAssertEqual(resting.bar, .hinge, "docked at the bottom of the viewer, not at the top of the desk")
        XCTAssertTrue(typing.hidesDesk)
        XCTAssertFalse(resting.hidesDesk)
        XCTAssertFalse(typing.stacksDeskOverHinge)
        XCTAssertTrue(typing.clearsContent)
        XCTAssertEqual(DuoDeckPlacement.resolve(.composer, keyboardUp: false).bar, .desk,
                       "a plain composer still opens at the desk's top")

        let down = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: 835), fold: laptop, placement: resting,
            deckSize: CGSize(width: 669, height: 58), deskHeight: 0
        ))
        XCTAssertEqual(down.deck, CGRect(x: 0, y: hinge - 58, width: 669, height: 58))
        XCTAssertEqual(down.content, CGRect(x: 0, y: 0, width: 669, height: hinge - 58))
        XCTAssertEqual(down.desk, CGRect(x: 0, y: laptop.frame.maxY, width: 669, height: 835 - laptop.frame.maxY))

        let up = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: hinge), fold: laptop, placement: typing,
            deckSize: CGSize(width: 669, height: 58), deskHeight: 835 - laptop.frame.maxY
        ))
        XCTAssertEqual(up.deck, down.deck, "the keyboard never moves the composer")
        XCTAssertEqual(up.content, down.content)
        XCTAssertEqual(up.desk, down.desk, "the list keeps its resting size under the keyboard")

        // A hardware keyboard's shortcut bar shortens the container without
        // reaching the fold: the list stays where it was.
        let shortcutBar = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: 835 - 70), fold: laptop, placement: resting,
            deckSize: CGSize(width: 669, height: 58), deskHeight: 0
        ))
        XCTAssertEqual(shortcutBar.deck, down.deck)
        XCTAssertEqual(shortcutBar.desk, CGRect(x: 0, y: laptop.frame.maxY, width: 669, height: 835 - 70 - laptop.frame.maxY))

        // With no composer (answering a prompt in words, a candidate, no
        // thread) the viewer reaches the hinge.
        let none = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: CGSize(width: 669, height: hinge), fold: laptop, placement: typing,
            deckSize: CGSize(width: 669, height: 0), deskHeight: 0
        ))
        XCTAssertEqual(none.content, CGRect(x: 0, y: 0, width: 669, height: hinge))
    }

    /// iOS reports the keyboard from the fold's top in laptop pose, so only a
    /// proposal ending above the fold's bottom is typing.
    func testTheProposalShowsTheKeyboardOnlyWhenItReachesTheFold() {
        XCTAssertTrue(DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: 669, height: 373.5), fold: laptop))
        XCTAssertFalse(DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: 669, height: 835), fold: laptop))
        XCTAssertFalse(DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: 669, height: 835 - 70), fold: laptop),
                       "a hardware keyboard's shortcut bar")
        XCTAssertFalse(DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: 867, height: 300), fold: book))
        XCTAssertFalse(DuoInputDeckLayout.keyboardCoversDesk(container: CGSize(width: 669, height: 300), fold: nil))
    }

    func testRepliesWaitUnderTheKeyboardBehindThePill() throws {
        let pill = try frames(open: false, keyboardUp: true, replies: 56)
        XCTAssertEqual(pill.desk?.minY, laptop.frame.maxY)
    }

    func testTheConversationDeckStillRestsOnTheHinge() throws {
        let container = CGSize(width: 669, height: 835)
        let split = try XCTUnwrap(DuoInputDeckLayout.split(container: container, fold: laptop, minimumDeckHeight: 60))
        let frames = try XCTUnwrap(DuoInputDeckLayout.frames(
            container: container, fold: laptop, placement: DuoDeckPlacement(bar: .hinge, keyboardUp: false),
            deckSize: CGSize(width: 669, height: 60), deskHeight: nil
        ))
        XCTAssertEqual(frames.content, split.content)
        XCTAssertEqual(frames.deck, split.deck)
        XCTAssertNil(frames.desk)
        XCTAssertNil(DuoInputDeckLayout.frames(
            container: container, fold: book, placement: DuoDeckPlacement(bar: .pill, keyboardUp: true),
            deckSize: CGSize(width: 100, height: 52), deskHeight: 0
        ))
    }

    func testAPillDroppedPastTheMiddleTakesThatEdge() {
        XCTAssertEqual(SessionAccessoryBar.pillEdge(releasedAt: 120, deckWidth: 669, current: .trailing), .leading)
        XCTAssertEqual(SessionAccessoryBar.pillEdge(releasedAt: 400, deckWidth: 669, current: .trailing), .trailing)
        XCTAssertEqual(SessionAccessoryBar.pillEdge(releasedAt: 500, deckWidth: 669, current: .leading), .trailing)
        XCTAssertEqual(SessionAccessoryBar.pillEdge(releasedAt: 500, deckWidth: 0, current: .leading), .leading)
    }

    @MainActor
    func testNilAndOptionlessPromptsHaveNoReplies() {
        XCTAssertTrue(DuoAgentRepliesRow(prompt: nil, onReply: { _ in XCTFail("nil prompt replied") }).options.isEmpty)
        let empty = AgentPrompt(signature: "empty", summary: "working", options: [])
        XCTAssertTrue(DuoAgentRepliesRow(prompt: empty, onReply: { _ in XCTFail("empty prompt replied") }).options.isEmpty)
    }

    @MainActor
    func testRepliesKeepEveryOptionInOrderAndPassTheOriginalMacroToTheCaller() {
        let options = [
            AgentPromptOption(id: 1, label: "Yes", responseMacro: "y", isDefault: true),
            AgentPromptOption(id: 2, label: "Always allow", responseMacro: "p", isDefault: false),
            AgentPromptOption(id: 3, label: "No", responseMacro: "esc", isDefault: false),
            AgentPromptOption(id: 4, label: "Other", responseMacro: "4↵", isDefault: false),
            AgentPromptOption(id: 5, label: "More", responseMacro: "5↵", isDefault: false)
        ]
        let prompt = AgentPrompt(signature: "s", summary: "continue?", options: options)
        var replies: [AgentPromptOption] = []
        let row = DuoAgentRepliesRow(prompt: prompt) { replies.append($0) }
        XCTAssertEqual(row.options, options)
        row.reply(options[2])
        XCTAssertEqual(replies, [options[2]])
        XCTAssertEqual(replies.first?.responseMacro, "esc")
    }

    @MainActor
    func testReplyTintUsesTheSharedNegativeAndCautionRules() {
        let options = [
            AgentPromptOption(id: 1, label: "No, quit", responseMacro: "n", isDefault: true),
            AgentPromptOption(id: 2, label: "Yes, don't ask again", responseMacro: "p", isDefault: true),
            AgentPromptOption(id: 3, label: "Yes", responseMacro: "y", isDefault: true),
            AgentPromptOption(id: 4, label: "Other", responseMacro: "o", isDefault: false)
        ]
        XCTAssertEqual(options.map(DuoAgentRepliesRow.tint(for:)), [.negative, .caution, .affirmative, .neutral])
    }
}

@MainActor
final class DuoInputDeckMountTests: XCTestCase {
    private final class Surface {
        var mounts = 0
        var sizes: [CGSize] = []
        weak var view: UIView?
        /// The `duoDeckCover` the content last read.
        var cover: CGFloat = 0
    }

    private final class RecordingView: UIView {
        var onLayout: ((CGSize) -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?(bounds.size)
        }
    }

    private struct LiveSurface: UIViewRepresentable {
        let surface: Surface
        func makeUIView(context: Context) -> UIView {
            surface.mounts += 1
            let view = RecordingView()
            view.onLayout = { surface.sizes.append($0) }
            surface.view = view
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private struct Host: View {
        var fold: DuoFold?
        let ordinary: Bool
        let content: Surface
        let deck: Surface
        var useDisabledWrapper = false

        var body: some View {
            if ordinary {
                VStack(spacing: 0) { terminal; accessory }
            } else if useDisabledWrapper {
                DuoFoldedInputLayout(isEnabled: false) { terminal } deck: { accessory }
            } else {
                DuoFoldedInputLayout(isEnabled: true, fold: fold) { terminal } deck: { accessory }
            }
        }

        private var terminal: some View {
            LiveSurface(surface: content).frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var accessory: some View {
            LiveSurface(surface: deck).frame(width: 150, height: 44)
        }
    }

    private struct KeyboardHost: View {
        let fold: DuoFold?
        let availableHeight: CGFloat
        let content: Surface
        let deck: Surface
        var isEnabled = true
        var contentReserve: CGFloat = 0
        /// A session's laptop bar, with a 100 pt pill and a 56 pt desk.
        var bar: DuoDeckBar?
        var desk: Surface?

        var body: some View {
            VStack(spacing: 0) {
                if let bar {
                    DuoFoldedInputLayout(isEnabled: isEnabled, fold: fold, bar: bar) {
                        terminal
                    } deck: {
                        LiveSurface(surface: deck).frame(width: 100, height: 44)
                    } desk: {
                        if let desk { LiveSurface(surface: desk).frame(height: 56) }
                    }
                } else {
                    DuoFoldedInputLayout(isEnabled: isEnabled, fold: fold, contentReserve: contentReserve) {
                        terminal
                    } deck: {
                        LiveSurface(surface: deck).frame(height: 44)
                    }
                }
            }
            // Mirrors SessionView and ContentView: a session ignores the bottom
            // safe area inside and outside the keyboard layout. Without that,
            // the deck is centred over the home-indicator inset at full height
            // and lands 17 pt above where the keyboard heights put it.
            .ignoresSafeArea(.container, edges: .bottom)
            .terminalKeyboardLayout(
                resizesTerminal: false,
                foldedLayoutActive: isEnabled && fold?.splitsSideBySide == false,
                caretClearance: { nil }
            )
            .frame(height: availableHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .bottom)
        }

        private var terminal: some View {
            LiveSurface(surface: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Compact tmux observes this same SwiftUI geometry edge;
                // record it even if UIKit coalesces two layout passes.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { content.sizes.append($0) }
                .background(CoverProbe(surface: content))
        }
    }

    private struct CoverProbe: View {
        let surface: Surface
        @Environment(\.duoDeckCover) private var cover

        var body: some View {
            Color.clear.onChange(of: cover, initial: true) { _, cover in surface.cover = cover }
        }
    }

    func testSessionKeyboardLayoutEntersAndLeavesLaptopPoseWithoutIntermediateTerminalHeights() throws {
        let content = Surface(), deck = Surface()
        let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
        let controller = UIHostingController(rootView: KeyboardHost(
            fold: nil, availableHeight: 520, content: content, deck: deck
        ))
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try mount(controller, height: 835)
        window.makeKeyAndVisible()
        defer { unmount(window); previousKeyWindow?.makeKey() }
        settle(controller)
        let ordinary = try frame(content, in: controller)
        XCTAssertEqual(ordinary.height, 835 - 44, accuracy: 1)

        for fold: DuoFold? in [laptop, nil, laptop, nil] {
            content.sizes = []
            controller.rootView = KeyboardHost(fold: fold, availableHeight: 520, content: content, deck: deck)
            settle(controller)
            let expectedHeight = fold == nil ? ordinary.height : laptop.frame.minY
            XCTAssertEqual(try frame(content, in: controller).height, expectedHeight, accuracy: 1)
            XCTAssertFalse(content.sizes.isEmpty, "the terminal must report the pose's new size")
            XCTAssertTrue(content.sizes.allSatisfy { abs($0.height - expectedHeight) < 1 },
                          "a settled pose must go straight to its final grid: \(content.sizes)")
            XCTAssertEqual(content.mounts, 1)
            XCTAssertEqual(deck.mounts, 1)
        }
    }

    func testDisabledSessionKeepsOrdinaryKeyboardLayoutWithASuppliedLaptopFold() throws {
        let content = Surface(), deck = Surface()
        let controller = UIHostingController(rootView: KeyboardHost(
            fold: nil, availableHeight: 520, content: content, deck: deck, isEnabled: false
        ))
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try mount(controller, height: 835)
        window.makeKeyAndVisible()
        defer { unmount(window); previousKeyWindow?.makeKey() }
        settle(controller)
        let ordinary = try frame(content, in: controller)
        let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
        content.sizes = []
        controller.rootView = KeyboardHost(
            fold: laptop, availableHeight: 520, content: content, deck: deck, isEnabled: false
        )
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), ordinary)
        XCTAssertTrue(content.sizes.allSatisfy { $0 == ordinary.size })
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)
    }

    func testSessionKeyboardModifierKeepsLaptopGridAndFoldStationaryAcrossShowHide() throws {
        let content = Surface(), deck = Surface()
        let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
        let controller = UIHostingController(rootView: KeyboardHost(
            fold: laptop, availableHeight: 835, content: content, deck: deck
        ))
        let window = try mount(controller, height: 835)
        defer { unmount(window) }
        settle(controller)
        let initial = try frame(content, in: controller)
        content.sizes = []
        for height: CGFloat in [520, 390, 320, 835] {
            controller.rootView = KeyboardHost(fold: laptop, availableHeight: height, content: content, deck: deck)
            settle(controller)
            XCTAssertEqual(try frame(content, in: controller), initial)
            let deckFrame = try frame(deck, in: controller)
            XCTAssertEqual(deckFrame.maxY, min(height, laptop.frame.minY), accuracy: 1)
        }
        XCTAssertTrue(content.sizes.allSatisfy { $0 == initial.size }, "keyboard changes must send no grid resize")
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)
    }

    func testFoldedDeckStaysOnTheHingeWhenTheKeyboardInsetStartsAtTheFold() throws {
        let content = Surface(), deck = Surface()
        let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
        func host(_ height: CGFloat) -> KeyboardHost {
            KeyboardHost(fold: laptop, availableHeight: height, content: content, deck: deck, contentReserve: 44)
        }
        let controller = UIHostingController(rootView: host(835))
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try mount(controller, height: 835)
        window.makeKeyAndVisible()
        defer { unmount(window); previousKeyWindow?.makeKey() }
        settle(controller)
        let initial = try frame(content, in: controller)
        XCTAssertEqual(initial.maxY, laptop.frame.minY - 44, accuracy: 1)
        content.sizes = []

        // Hidden, and docked from the fold's top as iOS reports it.
        for height: CGFloat in [835, 373.5, 835] {
            controller.rootView = host(height)
            settle(controller)
            let bar = try frame(deck, in: controller)
            XCTAssertEqual(bar.minY, initial.maxY, accuracy: 1, "the bar must sit right under the terminal")
            XCTAssertEqual(bar.maxY, laptop.frame.minY, accuracy: 1)
            XCTAssertEqual(try frame(content, in: controller), initial)
        }
        XCTAssertTrue(content.sizes.allSatisfy { $0 == initial.size }, "keyboard changes must send no grid resize")
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)
    }

    /// The closed bar folds to a pill over the terminal while typing; the
    /// open bar floats on the hinge over its bottom rows. Either opens at the
    /// top of the desk after. Neither the keyboard nor the bar remounts or
    /// resizes anything, and the content learns how far the open bar covers it.
    func testLaptopBarMovesBetweenPillDeskAndHingeWithoutEverResizingTheTerminal() throws {
        let content = Surface(), deck = Surface(), desk = Surface()
        let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)
        func host(_ height: CGFloat, open: Bool, edge: HorizontalEdge = .trailing) -> KeyboardHost {
            KeyboardHost(
                fold: laptop, availableHeight: height, content: content, deck: deck,
                bar: DuoDeckBar(openWhileTyping: open, edge: edge), desk: desk
            )
        }
        let controller = UIHostingController(rootView: host(835, open: false))
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        let window = try mount(controller, height: 835)
        window.makeKeyAndVisible()
        defer { unmount(window); previousKeyWindow?.makeKey() }
        settle(controller)

        // Closed: the terminal keeps the whole top half in both keyboard states.
        let closed = try frame(content, in: controller)
        XCTAssertEqual(closed.maxY, laptop.frame.minY, accuracy: 1)
        XCTAssertEqual(try frame(deck, in: controller).minY, laptop.frame.maxY, accuracy: 1, "the bar opens below the hinge")
        XCTAssertEqual(try frame(desk, in: controller).minY, laptop.frame.maxY + 44, accuracy: 1)
        content.sizes = []
        for edge: HorizontalEdge in [.trailing, .leading] {
            controller.rootView = host(laptop.frame.minY, open: false, edge: edge)
            settle(controller)
            let pill = try frame(deck, in: controller)
            XCTAssertEqual(pill.maxY, laptop.frame.minY - DuoInputDeckLayout.pillGap, accuracy: 1)
            // From the deck's own edges: the test window may inset the layout.
            XCTAssertEqual(edge == .trailing ? closed.maxX - pill.maxX : pill.minX - closed.minX,
                           DuoInputDeckLayout.pillInset, accuracy: 1, "\(edge) pill \(pill) in \(closed)")
            XCTAssertEqual(try frame(content, in: controller), closed)
        }
        controller.rootView = host(835, open: false)
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), closed)
        XCTAssertTrue(content.sizes.allSatisfy { $0 == closed.size }, "the keyboard must not resize the terminal: \(content.sizes)")

        XCTAssertEqual(content.cover, 0, "the pill covers no row")

        // Open: the bar floats over the terminal while typing; nothing resizes.
        controller.rootView = host(835, open: true)
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), closed)
        XCTAssertEqual(try frame(deck, in: controller).minY, laptop.frame.maxY, accuracy: 1, "reading, the bar opens below the hinge")
        XCTAssertEqual(content.cover, 0)
        controller.rootView = host(laptop.frame.minY, open: true)
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), closed)
        let bar = try frame(deck, in: controller)
        XCTAssertEqual(bar.minY, laptop.frame.minY - 44, accuracy: 1)
        XCTAssertEqual(content.cover, 44 + 56, accuracy: 1, "the bar and the replies stacked on it")
        controller.rootView = host(835, open: true)
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), closed)
        XCTAssertEqual(try frame(desk, in: controller).minY, laptop.frame.maxY + 44, accuracy: 1, "replies sit under the bar")
        XCTAssertEqual(content.cover, 0)
        XCTAssertTrue(content.sizes.allSatisfy { $0 == closed.size }, "the bar must not resize the terminal: \(content.sizes)")
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)
        XCTAssertEqual(desk.mounts, 1)
    }

    func testFallbackFramesMatchVStackForNormalAndKeyboardSizedContainers() throws {
        for height: CGFloat in [835, 520] {
            for fold: DuoFold? in [nil, DuoFold(frame: CGRect(x: 300, y: 0, width: 40, height: height), splitsSideBySide: true)] {
                let expectedContent = Surface(), expectedDeck = Surface()
                let actualContent = Surface(), actualDeck = Surface()
                let expected = UIHostingController(rootView: Host(fold: nil, ordinary: true, content: expectedContent, deck: expectedDeck))
                let actual = UIHostingController(rootView: Host(fold: fold, ordinary: false, content: actualContent, deck: actualDeck))
                let expectedWindow = try mount(expected, height: height)
                let actualWindow = try mount(actual, height: height)
                defer { unmount(expectedWindow); unmount(actualWindow) }
                settle(expected); settle(actual)
                XCTAssertEqual(try frame(expectedContent, in: expected), try frame(actualContent, in: actual))
                XCTAssertEqual(try frame(expectedDeck, in: expected), try frame(actualDeck, in: actual))
            }
        }
    }

    func testDisabledFoldedWrapperKeepsOrdinaryTerminalAndAccessoryFrames() throws {
        for height: CGFloat in [835, 520] {
            let expectedContent = Surface(), expectedDeck = Surface()
            let actualContent = Surface(), actualDeck = Surface()
            let expected = UIHostingController(rootView: Host(
                fold: nil, ordinary: true, content: expectedContent, deck: expectedDeck
            ))
            let actual = UIHostingController(rootView: Host(
                fold: nil, ordinary: false, content: actualContent, deck: actualDeck, useDisabledWrapper: true
            ))
            let expectedWindow = try mount(expected, height: height)
            let actualWindow = try mount(actual, height: height)
            defer { unmount(expectedWindow); unmount(actualWindow) }
            settle(expected); settle(actual)
            XCTAssertEqual(try frame(expectedContent, in: expected), try frame(actualContent, in: actual))
            XCTAssertEqual(try frame(expectedDeck, in: expected), try frame(actualDeck, in: actual))
        }
    }

    func testFoldChangesAndKeyboardProposalsKeepTheTerminalMounted() throws {
        let content = Surface(), deck = Surface()
        let controller = UIHostingController(rootView: Host(fold: nil, ordinary: false, content: content, deck: deck))
        let window = try mount(controller, height: 835)
        defer { unmount(window) }
        settle(controller)
        let ordinaryDeckCenter = try frame(deck, in: controller).midX
        let laptop = DuoFold(frame: CGRect(x: 0, y: 300, width: 669, height: 40), splitsSideBySide: false)
        controller.rootView = Host(fold: laptop, ordinary: false, content: content, deck: deck)
        settle(controller)
        let foldedFrame = try frame(content, in: controller)
        XCTAssertEqual(foldedFrame.height, 300, accuracy: 1)
        XCTAssertEqual(try frame(deck, in: controller).midX, ordinaryDeckCenter, accuracy: 1)
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)

        window.frame.size.height = 520
        settle(controller)
        XCTAssertEqual(try frame(content, in: controller), foldedFrame)
        XCTAssertEqual(content.mounts, 1)

        controller.rootView = Host(fold: nil, ordinary: false, content: content, deck: deck)
        settle(controller)
        XCTAssertGreaterThan(try frame(content, in: controller).height, foldedFrame.height)
        XCTAssertEqual(content.mounts, 1)
        XCTAssertEqual(deck.mounts, 1)
    }

    func testEmptyRepliesOccupyNoHeightAndVisibleRepliesHave44PointTargets() throws {
        let empty = UIHostingController(rootView: DuoAgentRepliesRow(prompt: nil) { _ in })
        XCTAssertEqual(empty.sizeThatFits(in: CGSize(width: 382, height: 835)).height, 0)
        let prompt = AgentPrompt(signature: "s", summary: "continue?", options: [
            AgentPromptOption(id: 1, label: "Yes", responseMacro: "y", isDefault: true)
        ])
        let visible = UIHostingController(rootView: DuoAgentRepliesRow(prompt: prompt) { _ in })
        let size = visible.sizeThatFits(in: CGSize(width: 382, height: 835))
        XCTAssertGreaterThanOrEqual(size.height, 44)
        XCTAssertLessThan(size.height, 100, "a single row must not consume the deck's remaining height")
    }

    /// The folds above are in the layout's own space, as the fold reader
    /// reports them, so the layout has to start at the window's top. A window
    /// at the screen's origin inherits the device's safe area (62 pt on an
    /// iPhone, arriving a few passes late), which would push it down.
    private func mount<Content: View>(_ controller: UIHostingController<Content>, height: CGFloat) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 669, height: height)
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func frame(_ surface: Surface, in controller: UIViewController) throws -> CGRect {
        let view = try XCTUnwrap(surface.view)
        return view.convert(view.bounds, to: controller.view)
    }

    private func settle(_ controller: UIViewController) {
        for _ in 0..<5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }
}
