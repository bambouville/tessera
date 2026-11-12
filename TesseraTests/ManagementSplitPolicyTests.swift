import XCTest
@testable import Tessera

final class ManagementSplitPolicyTests: XCTestCase {
    private let outer = CGSize(width: 382, height: 644)
    private let wide = CGSize(width: 867, height: 553)
    private let tall = CGSize(width: 669, height: 787)
    private let book = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 553), splitsSideBySide: true)
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)

    func testOutsideRailModeKeepsTheExistingSingleArrangementWithoutALaptopFold() {
        for (size, fold) in [(outer, nil), (wide, nil), (wide, book), (tall, nil)] {
            XCTAssertEqual(ManagementSplitPolicy.arrangement(isRailMode: false, container: size, fold: fold), .single)
        }
    }

    /// Laptop pose has no rail (the bars are horizontal on the inner tall display), so the fold alone stacks the list
    /// over the detail.
    func testALaptopFoldStacksTheListOverTheDetailWithoutTheRail() {
        XCTAssertEqual(
            ManagementSplitPolicy.arrangement(isRailMode: false, container: tall, fold: laptop),
            ManagementSplitPolicy.arrangement(isRailMode: true, container: tall, fold: laptop)
        )
        guard case .listOverDetail = ManagementSplitPolicy.arrangement(isRailMode: false, container: tall, fold: laptop) else {
            return XCTFail("a laptop fold outside rail mode did not stack the list over the detail")
        }
    }

    func testOuterDisplayUsesThePhoneStack() {
        XCTAssertEqual(arrangement(outer), .single)
    }

    func testInnerWideKeepsA343PointListBesideA524PointDetail() {
        XCTAssertEqual(arrangement(wide), .listBesideDetail(listWidth: 343))
    }

    func testBookUsesTheExactLeadingHalfAndKeepsTheFoldClear() throws {
        XCTAssertEqual(arrangement(wide, fold: book), .listBesideDetail(listWidth: 455.5))
        let split = try XCTUnwrap(ManagementSplitPolicy.foldSplit(container: wide, fold: book))
        XCTAssertEqual(split.list, CGRect(x: 0, y: 0, width: 455.5, height: 553))
        XCTAssertEqual(split.detail, CGRect(x: 495.5, y: 0, width: 371.5, height: 553))
        XCTAssertEqual(split.detail.minX - split.list.maxX, 40)
    }

    func testLaptopPutsTheListAboveTheFoldAndTheDetailBelowIt() {
        XCTAssertEqual(arrangement(tall, fold: laptop), .listOverDetail(split: ManagementSplitPolicy.Split(
            list: CGRect(x: 0, y: 0, width: 669, height: 373.5),
            detail: CGRect(x: 0, y: 413.5, width: 669, height: 373.5)
        )))
    }

    func testTypingOnTheDeskMovesTheDetailOverTheListAboveTheFold() throws {
        let open = try XCTUnwrap(ManagementSplitPolicy.foldSplit(container: tall, fold: laptop))
        XCTAssertEqual(ManagementSplitPolicy.detailFrame(open), open.detail)
        // The keyboard rises from the fold's top, or a little below it.
        for height in [373.5, 413.5, 653.0] {
            let typing = try XCTUnwrap(ManagementSplitPolicy.foldSplit(
                container: CGSize(width: tall.width, height: height), fold: laptop))
            let detail = ManagementSplitPolicy.detailFrame(typing)
            XCTAssertEqual(detail, typing.list)
            XCTAssertFalse(detail.intersects(laptop.frame))
        }
        let roomy = try XCTUnwrap(ManagementSplitPolicy.foldSplit(
            container: CGSize(width: tall.width, height: 653.5), fold: laptop))
        XCTAssertEqual(ManagementSplitPolicy.detailFrame(roomy), roomy.detail)
    }

    func testInnerTallWithoutAFoldUsesThePhoneStackEvenIfRailModeIsEnabled() {
        XCTAssertEqual(arrangement(tall), .single)
    }

    func testUnfoldedBoundaryNeeds320ForTheListAnd480ForDetail() {
        XCTAssertEqual(arrangement(CGSize(width: 799.5, height: 600)), .single)
        XCTAssertEqual(arrangement(CGSize(width: 800, height: 600)), .listBesideDetail(listWidth: 320))
        XCTAssertEqual(arrangement(CGSize(width: 822.5, height: 600)), .listBesideDetail(listWidth: 342.5))
        XCTAssertEqual(arrangement(CGSize(width: 823, height: 600)), .listBesideDetail(listWidth: 343))
        XCTAssertEqual(arrangement(CGSize(width: 1500, height: 600)), .listBesideDetail(listWidth: 343))
    }

    func testFoldsWinOverTheUnfoldedWidthThreshold() {
        let smallBook = DuoFold(frame: CGRect(x: 210, y: 0, width: 40, height: 600), splitsSideBySide: true)
        XCTAssertEqual(arrangement(CGSize(width: 500, height: 600), fold: smallBook), .listBesideDetail(listWidth: 210))
        XCTAssertEqual(arrangement(outer, fold: laptop), .listOverDetail(split: ManagementSplitPolicy.Split(
            list: CGRect(x: 0, y: 0, width: 382, height: 373.5),
            detail: CGRect(x: 0, y: 413.5, width: 382, height: 230.5)
        )))
    }

    func testFoldEdgesUseTheSameRulesAsPaneGeometry() throws {
        // A side-by-side fold leaving no pane's room on one side divides nothing.
        let offscreenBook = DuoFold(frame: CGRect(x: -10, y: 0, width: 40, height: 600), splitsSideBySide: true)
        XCTAssertNil(ManagementSplitPolicy.foldSplit(container: outer, fold: offscreenBook))
        XCTAssertEqual(arrangement(outer, fold: offscreenBook), arrangement(outer))
        let offscreenLaptop = DuoFold(frame: CGRect(x: 0, y: 800, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertEqual(arrangement(tall, fold: offscreenLaptop), .listOverDetail(split: ManagementSplitPolicy.Split(
            list: CGRect(x: 0, y: 0, width: 669, height: 787),
            detail: CGRect(x: 0, y: 787, width: 669, height: 0)
        )))
    }

    func testNoFoldHasNoReservedGap() {
        XCTAssertNil(ManagementSplitPolicy.foldSplit(container: wide, fold: nil))
    }

    func testReturningToAPoseGivesTheSameArrangement() {
        let poses: [(CGSize, DuoFold?)] = [(outer, nil), (wide, nil), (wide, book), (tall, laptop), (tall, nil)]
        let before = poses.map { arrangement($0.0, fold: $0.1) }
        for (size, fold) in poses.reversed() { _ = arrangement(size, fold: fold) }
        XCTAssertEqual(poses.map { arrangement($0.0, fold: $0.1) }, before)
    }

    private func arrangement(_ container: CGSize, fold: DuoFold? = nil) -> ManagementSplitPolicy.Arrangement {
        ManagementSplitPolicy.arrangement(isRailMode: true, container: container, fold: fold)
    }
}

final class ManagementSplitSelectionTests: XCTestCase {
    private enum Section: Hashable, CaseIterable { case first, second, third }

    func testEverySelectionSurvivesPhoneWideBookLaptopAndTallSwitches() {
        var selection = ManagementSelection<Section>(section: nil)
        let arrangements: [ManagementSplitPolicy.Arrangement] = [
            .single,
            .listBesideDetail(listWidth: 343),
            .listBesideDetail(listWidth: 455.5),
            .listOverDetail(split: ManagementSplitPolicy.Split(
                list: CGRect(x: 0, y: 0, width: 669, height: 373.5),
                detail: CGRect(x: 0, y: 413.5, width: 669, height: 373.5)
            )),
            .single
        ]

        for section in Section.allCases {
            selection.phonePath = [section]
            for arrangement in arrangements {
                selection.retainDetail(for: arrangement, defaultSection: .first)
                XCTAssertEqual(selection.section, section)
                XCTAssertEqual(selection.detail(defaultSection: .first), section)
                XCTAssertEqual(selection.phonePath, [section])
            }
        }
    }

    func testSplitRowSelectionIsThePhoneDestinationAndPhoneBackClearsIt() {
        var selection = ManagementSelection<Section>(section: .first)

        selection.section = .second
        selection.retainDetail(for: .single, defaultSection: .first)
        XCTAssertEqual(selection.detail(defaultSection: .first), .second)
        XCTAssertEqual(selection.phonePath, [.second])

        selection.phonePath = []
        selection.retainDetail(for: .single, defaultSection: .first)
        XCTAssertNil(selection.section)
        XCTAssertEqual(selection.phonePath, [])
    }

    func testPhonePathRetainsTheLastPushedSection() {
        var selection = ManagementSelection<Section>(section: nil)
        selection.phonePath = [.first, .third]
        XCTAssertEqual(selection.section, .third)
        XCTAssertEqual(selection.phonePath, [.third])
    }

    func testUnselectedPhoneKeepsItsListUntilASplitDisplaysTheDefault() {
        var selection = ManagementSelection<Section>(section: nil)

        selection.retainDetail(for: .single, defaultSection: .first)
        XCTAssertNil(selection.section)
        XCTAssertEqual(selection.phonePath, [])

        selection.retainDetail(for: .listBesideDetail(listWidth: 343), defaultSection: .first)
        XCTAssertEqual(selection.section, .first)
        selection.retainDetail(for: .single, defaultSection: .first)
        XCTAssertEqual(selection.detail(defaultSection: .first), .first)
        XCTAssertEqual(selection.phonePath, [.first])
    }

    func testAnInitialLaptopSplitAlsoRetainsTheDisplayedDefault() {
        var selection = ManagementSelection<Section>(section: nil)
        selection.retainDetail(for: .listOverDetail(split: ManagementSplitPolicy.Split(
            list: CGRect(x: 0, y: 0, width: 669, height: 373.5),
            detail: CGRect(x: 0, y: 413.5, width: 669, height: 373.5)
        )), defaultSection: .first)
        selection.retainDetail(for: .single, defaultSection: .first)
        XCTAssertEqual(selection.section, .first)
        XCTAssertEqual(selection.phonePath, [.first])
    }
}
