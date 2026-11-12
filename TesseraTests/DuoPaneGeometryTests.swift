import XCTest
@testable import Tessera

final class DuoPaneGeometryTests: XCTestCase {
    private let wide = CGSize(width: 867, height: 553)
    private let tall = CGSize(width: 669, height: 787)
    private let book = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 553), splitsSideBySide: true)
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)

    private func request(_ size: CGSize, fold: DuoFold? = nil) -> DuoPaneRequest {
        DuoPaneRequest(
            container: size, fold: fold, contextHidden: false, fullScreen: false,
            swapped: false, mainTakesInput: true, mainIdealWidth: 524
        )
    }

    func testClosedAndTentAreOnePaneOverTheMeasuredOuterContent() {
        for _ in ["closed", "tent"] {
            let size = CGSize(width: 382, height: 644)
            let layout = DuoPaneGeometry.layout(request(size))
            XCTAssertEqual(layout.arrangement, .single)
            XCTAssertEqual(layout.mainSlot, CGRect(origin: .zero, size: size))
            XCTAssertNil(layout.contextSlot)
        }
    }

    /// T-12: as the Duo closes, the book's hinge is still reported for the
    /// outer display's containers, measured at 594 × 466 (landscape) and
    /// 382 wide. It is no fold there, so a swapped session stays hidden at its
    /// book size instead of shrinking into a 98.5 pt slot and resizing the
    /// remote to a dozen columns. Closing from laptop reported a side-by-side
    /// hinge at x 182.5 in the outer 594 pt for a moment: its 182.5 pt
    /// leading slot resized the remote to 21 columns.
    func testTheBooksHingeOnTheClosingOuterDisplayLeavesOnePane() {
        let bookHinge = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), splitsSideBySide: true)
        let lifted = DuoFold(frame: CGRect(x: 455.5, y: -203, width: 40, height: 669), splitsSideBySide: true)
        let closingLaptop = DuoFold(frame: CGRect(x: 182.5, y: 0, width: 40, height: 669), splitsSideBySide: true)
        for (outer, fold) in [(CGSize(width: 594, height: 466), bookHinge), (CGSize(width: 594, height: 466), lifted),
                              (CGSize(width: 382, height: 644), bookHinge),
                              (CGSize(width: 594, height: 432), closingLaptop), (CGSize(width: 594, height: 466), closingLaptop)] {
            let layout = DuoPaneGeometry.layout(request(outer, fold: fold))
            XCTAssertEqual(layout.arrangement, .single, "\(outer)")
            XCTAssertEqual(layout.mainSlot, CGRect(origin: .zero, size: outer))
            XCTAssertNil(layout.contextSlot)

            let bookSize = CGSize(width: 371.5, height: 553)
            let placement = DuoWorkspacePlacement.resolve(
                layout: layout, swapped: true, lastPrimarySize: bookSize, lastSecondarySize: nil
            )
            XCTAssertFalse(placement.primaryVisible)
            XCTAssertEqual(placement.primary.size, bookSize)
            XCTAssertTrue(placement.secondaryVisible)
            XCTAssertFalse(DuoWorkspaceActions.offersFullScreen(arrangement: layout.arrangement, onTheDesk: false))
        }
    }

    /// Turning from book to laptop reported the book's hinge in a 585 pt
    /// container (89.5 pt beyond it), and back the laptop's 669 pt hinge in
    /// the book's 951 pt width. Neither divides that container.
    func testAHingeFromTheOtherOrientationIsNoFold() {
        let narrow = DuoPaneGeometry.layout(request(CGSize(width: 585, height: 442), fold: book))
        XCTAssertEqual(narrow.arrangement, .single)
        XCTAssertNil(narrow.contextSlot)

        let laptopHinge = DuoFold(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertNil(DuoPaneGeometry.deckSplit(container: CGSize(width: 951, height: 635), fold: laptopHinge))
        let open = DuoPaneGeometry.layout(request(CGSize(width: 951, height: 635), fold: laptopHinge))
        XCTAssertEqual(open.arrangement, .sideBySide)
        XCTAssertEqual(open.mainSlot.width + (open.contextSlot?.width ?? 0), 951)
        // The laptop's own container still splits at its hinge.
        XCTAssertNotNil(DuoPaneGeometry.deckSplit(container: CGSize(width: 669, height: 951), fold: laptopHinge))
    }

    func testOpenWideGivesMainEightyColumnsAndContextTheRemainder() {
        let layout = DuoPaneGeometry.layout(request(wide))
        XCTAssertEqual(layout.arrangement, .sideBySide)
        XCTAssertEqual(layout.mainSlot, CGRect(x: 0, y: 0, width: 524, height: 553))
        XCTAssertEqual(layout.contextSlot, CGRect(x: 524, y: 0, width: 343, height: 553))
    }

    func testBookSnapsBothPanesClearOfTheMeasuredFortyPointFold() {
        let layout = DuoPaneGeometry.layout(request(wide, fold: book))
        XCTAssertEqual(layout.arrangement, .sideBySide)
        XCTAssertEqual(layout.mainSlot, CGRect(x: 0, y: 0, width: 455.5, height: 553))
        XCTAssertEqual(layout.contextSlot, CGRect(x: 495.5, y: 0, width: 371.5, height: 553))
    }

    func testOpenTallIsOnePane() {
        let layout = DuoPaneGeometry.layout(request(tall))
        XCTAssertEqual(layout.arrangement, .single)
        XCTAssertEqual(layout.mainSlot, CGRect(origin: .zero, size: tall))
        XCTAssertNil(layout.contextSlot)
    }

    func testLaptopWithInputKeepsMainWholeForItsOwnDeckSplit() throws {
        let layout = DuoPaneGeometry.layout(request(tall, fold: laptop))
        XCTAssertEqual(layout.arrangement, .single)
        XCTAssertEqual(layout.mainSlot, CGRect(origin: .zero, size: tall))
        XCTAssertNil(layout.contextSlot)
        let split = try XCTUnwrap(DuoPaneGeometry.deckSplit(container: tall, fold: laptop))
        XCTAssertEqual(split.content, CGRect(x: 0, y: 0, width: 669, height: 373.5))
        XCTAssertEqual(split.deck, CGRect(x: 0, y: 413.5, width: 669, height: 373.5))
    }

    func testLaptopSessionLendsItsFreeDeskToTheContextAndHoldsItUnderTheKeyboard() throws {
        var input = request(tall, fold: laptop)
        input.mainHasDesk = true
        let noDesk = DuoPaneGeometry.layout(input)
        XCTAssertEqual(noDesk.arrangement, .stacked)
        XCTAssertEqual(noDesk.mainSlot, CGRect(origin: .zero, size: tall))
        XCTAssertNil(noDesk.contextSlot)

        // Measured with the keyboard down, the desk runs to the bottom.
        input.desk = CGRect(x: 0, y: 413.5 + 52, width: 669, height: 787 - 465.5)
        let resting = DuoPaneGeometry.layout(input)
        XCTAssertEqual(resting.mainSlot, CGRect(origin: .zero, size: tall))
        XCTAssertEqual(resting.contextSlot, input.desk)
        input.desk = CGRect(x: -20, y: 300, width: 700, height: 487)
        XCTAssertEqual(DuoPaneGeometry.layout(input).contextSlot, CGRect(x: 0, y: 413.5, width: 669, height: 373.5),
                       "clipped to the desk half")

        // Typing: the keyboard proposal shortens the workspace to the fold's
        // top while the session holds the desk it measured before. A slot
        // clipped to that short container would hide the context and park it
        // at the origin on every keyboard toggle.
        input.desk = resting.contextSlot
        input.container = CGSize(width: 669, height: 373.5)
        let typing = DuoPaneGeometry.layout(input)
        XCTAssertEqual(typing.mainSlot, CGRect(x: 0, y: 0, width: 669, height: 373.5))
        XCTAssertEqual(typing.contextSlot, resting.contextSlot, "the context waits under the keyboard where it was")
        input.container = tall

        input.contextHidden = true
        XCTAssertNil(DuoPaneGeometry.layout(input).contextSlot)
        input.contextHidden = false
        input.desk = CGRect(x: 0, y: 100, width: 669, height: 200)
        XCTAssertNil(DuoPaneGeometry.layout(input).contextSlot, "a desk above the hinge is no desk")
    }

    /// The context traded up for a field: the session lies on the whole desk
    /// half, live, and stays there at its size while the user types above.
    func testATradedSessionKeepsTheWholeDeskHalfUnderTheKeyboard() {
        var input = request(tall, fold: laptop)
        input.mainHasDesk = true
        input.mainTakesInput = false
        input.desk = CGRect(x: 0, y: 413.5 + 52, width: 669, height: 787 - 465.5)
        let resting = DuoPaneGeometry.layout(input)
        XCTAssertEqual(resting.arrangement, .stacked)
        XCTAssertEqual(resting.mainSlot, CGRect(x: 0, y: 0, width: 669, height: 373.5), "the context, above the keyboard")
        XCTAssertEqual(resting.contextSlot, CGRect(x: 0, y: 413.5, width: 669, height: 373.5), "the session, below the bar's row too")

        input.container = CGSize(width: 669, height: 373.5)
        let typing = DuoPaneGeometry.layout(input)
        XCTAssertEqual(typing.mainSlot, resting.mainSlot)
        XCTAssertEqual(typing.contextSlot, resting.contextSlot, "no remote resize while the keyboard comes and goes")
    }

    func testLaptopWithATabGivesContextTheBottomPart() {
        var input = request(tall, fold: laptop)
        input.mainTakesInput = false
        let layout = DuoPaneGeometry.layout(input)
        XCTAssertEqual(layout.arrangement, .stacked)
        XCTAssertEqual(layout.mainSlot, CGRect(x: 0, y: 0, width: 669, height: 373.5))
        XCTAssertEqual(layout.contextSlot, CGRect(x: 0, y: 413.5, width: 669, height: 373.5))
    }

    func testHiddenContextAndFullScreenSpanTheFoldButRememberTheArrangement() {
        for hidden in [false, true] {
            var input = request(wide, fold: book)
            input.contextHidden = hidden
            input.fullScreen = !hidden
            let layout = DuoPaneGeometry.layout(input)
            XCTAssertEqual(layout.mainSlot, CGRect(origin: .zero, size: wide))
            XCTAssertNil(layout.contextSlot)
            XCTAssertEqual(layout.arrangement, .sideBySide)

            input = request(tall, fold: laptop)
            input.mainTakesInput = false
            input.contextHidden = hidden
            input.fullScreen = !hidden
            let stacked = DuoPaneGeometry.layout(input)
            XCTAssertEqual(stacked.mainSlot, CGRect(origin: .zero, size: tall))
            XCTAssertNil(stacked.contextSlot)
            XCTAssertEqual(stacked.arrangement, .stacked)
        }
    }

    func testSwapNeverChangesSlotGeometry() {
        for input in [request(wide), request(wide, fold: book), request(tall), request(tall, fold: laptop)] {
            var swapped = input
            swapped.swapped = true
            XCTAssertEqual(DuoPaneGeometry.layout(input), DuoPaneGeometry.layout(swapped))
        }
    }

    func testOpenWideKeepsTheContextWhenEightyColumnsNeedMoreThanItLeaves() {
        // 80 columns at the default 8 pt cell need 648 pt; the rail leaves 867.
        var input = request(wide)
        input.mainIdealWidth = 648
        let layout = DuoPaneGeometry.layout(input)
        XCTAssertEqual(layout.arrangement, .sideBySide)
        XCTAssertEqual(layout.mainSlot, CGRect(x: 0, y: 0, width: 524, height: 553))
        XCTAssertEqual(layout.contextSlot, CGRect(x: 524, y: 0, width: 343, height: 553))
    }

    func testSmallerFontsGiveTheContextMoreThanItsMinimum() {
        var input = request(wide)
        input.mainIdealWidth = 450
        let layout = DuoPaneGeometry.layout(input)
        XCTAssertEqual(layout.mainSlot.width, 450)
        XCTAssertEqual(layout.contextSlot?.width, 417)
    }

    func testMinimumWidthBoundaryIsInclusive() {
        let below = DuoPaneGeometry.layout(request(CGSize(width: 742.5, height: 553)))
        XCTAssertEqual(below.arrangement, .single)
        let boundary = DuoPaneGeometry.layout(request(CGSize(width: 743, height: 553)))
        XCTAssertEqual(boundary.arrangement, .sideBySide)
        XCTAssertEqual(boundary.mainSlot.width, 400)
        XCTAssertEqual(boundary.contextSlot?.width, 343)
        var widerMinimum = request(CGSize(width: 743, height: 553))
        widerMinimum.minimumContextWidth = 344
        XCTAssertEqual(DuoPaneGeometry.layout(widerMinimum).arrangement, .single)
        var widerMain = request(CGSize(width: 743, height: 553))
        widerMain.minimumMainWidth = 401
        XCTAssertEqual(DuoPaneGeometry.layout(widerMain).arrangement, .single)
    }

    func testFoldWinsOverTheUnfoldedMinimumAndIdealWidth() {
        var input = request(wide, fold: book)
        input.mainIdealWidth = 800
        input.minimumContextWidth = 800
        XCTAssertEqual(DuoPaneGeometry.layout(input).contextSlot?.width, 371.5)
    }

    func testDeckSplitExistsOnlyForHorizontalFolds() {
        XCTAssertNil(DuoPaneGeometry.deckSplit(container: tall, fold: nil))
        XCTAssertNil(DuoPaneGeometry.deckSplit(container: wide, fold: book))
    }

    func testIdealWidthUsesTotalHorizontalPaddingAndReturningToAPoseIsDeterministic() {
        XCTAssertEqual(DuoPaneGeometry.mainIdealWidth(columns: 80, cellWidth: 6.3, horizontalPadding: 20), 524)
        let before = DuoPaneGeometry.layout(request(wide, fold: book))
        _ = DuoPaneGeometry.layout(request(tall, fold: laptop))
        _ = DuoPaneGeometry.layout(request(CGSize(width: 382, height: 644)))
        XCTAssertEqual(DuoPaneGeometry.layout(request(wide, fold: book)), before)
    }
}
