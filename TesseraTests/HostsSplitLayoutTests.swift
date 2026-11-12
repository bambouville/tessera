import SwiftUI
import XCTest
@testable import Tessera

final class HostsSplitLayoutTests: XCTestCase {
    private let outer = CGSize(width: 382, height: 644)
    private let wide = CGSize(width: 867, height: 553)
    private let tall = CGSize(width: 669, height: 787)
    private let book = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 553), splitsSideBySide: true)
    private let laptop = DuoFold(frame: CGRect(x: 0, y: 373.5, width: 669, height: 40), splitsSideBySide: false)

    /// "Set up as new" already made a device key, so with one on file the
    /// empty state opens the keys rather than offering to generate another.
    func testTheEmptyStateOffersToGenerateAKeyOnlyWhenThereIsNone() {
        XCTAssertEqual(HostsEmptyKeyAction(hasKeys: false), .generate)
        XCTAssertEqual(HostsEmptyKeyAction(hasKeys: true), .view)
    }

    /// M-07 from Hosts, after leaving an import open on the keys page: the
    /// generator must not open underneath it.
    func testGeneratingAKeyReplacesAnImportLeftOpen() {
        let presentation = KeysPagePresentationState()
        presentation.showImportModal = true
        presentation.presentGenerator(initialProtection: false)
        XCTAssertTrue(presentation.showGenerateModal)
        XCTAssertFalse(presentation.showImportModal)
    }

    func testOuterDisplayKeepsTheLandingAndOnlyAnExplicitSelectionShowsAnEditor() {
        let empty = layout(outer)
        XCTAssertEqual(empty.arrangement, .single)
        XCTAssertEqual(empty.list, CGRect(origin: .zero, size: outer))
        XCTAssertEqual(empty.detailContent, .hidden)
        XCTAssertFalse(empty.isSplit)

        let id = UUID()
        let selected = layout(outer, selectedHostID: id)
        XCTAssertEqual(selected.editor, CGRect(origin: .zero, size: outer))
        XCTAssertEqual(selected.detailContent, .editor(id))
    }

    func testNonRailPhonesWithoutALaptopFoldKeepTheExistingSingleLayout() {
        for (size, fold) in [(outer, nil), (wide, nil), (wide, book), (tall, nil)] {
            let result = layout(size, fold: fold, isRailMode: false)
            XCTAssertEqual(result.arrangement, .single)
            XCTAssertEqual(result.list, CGRect(origin: .zero, size: size))
            XCTAssertEqual(result.detailContent, .hidden)
        }
    }

    func testEveryIPadKeepsItsExistingLayoutEvenIfGivenDuoInputs() {
        let id = UUID()
        for (size, fold) in [(outer, nil), (wide, nil), (wide, book), (tall, laptop)] {
            for railMode in [false, true] {
                let result = layout(size, fold: fold, selectedHostID: id, isRailMode: railMode, isPhone: false)
                XCTAssertEqual(result.arrangement, .single)
                XCTAssertEqual(result.editor, CGRect(origin: .zero, size: size))
                XCTAssertEqual(result.detailContent, .editor(id))
            }
        }
    }

    func testInnerWideGivesTheList343PointsAndTheDetail524Points() {
        let result = layout(wide)
        XCTAssertEqual(result.arrangement, .listBesideDetail(listWidth: 343))
        XCTAssertEqual(result.list, CGRect(x: 0, y: 0, width: 343, height: 553))
        XCTAssertEqual(result.detail, CGRect(x: 343, y: 0, width: 524, height: 553))
        XCTAssertEqual(result.editor, result.detail)
        XCTAssertFalse(result.editorCoversList)
    }

    func testWidthBoundaryFitsA320PointListWithoutChangingTheDetailMinimum() {
        XCTAssertEqual(layout(CGSize(width: 799.5, height: 600)).arrangement, .single)
        for (width, listWidth) in [(800.0, 320.0), (822.5, 342.5), (823.0, 343.0)] {
            let result = layout(CGSize(width: width, height: 600))
            XCTAssertEqual(result.list.width, listWidth)
            XCTAssertEqual(result.detail.width, 480)
            XCTAssertEqual(result.list.maxX, result.detail.minX)
        }
    }

    func testBookUsesTheExactFoldEdgesAndNeverDrawsInTheGap() {
        let result = layout(wide, fold: book, selectedHostID: UUID())
        XCTAssertEqual(result.arrangement, .listBesideDetail(listWidth: 455.5))
        XCTAssertEqual(result.list, CGRect(x: 0, y: 0, width: 455.5, height: 553))
        XCTAssertEqual(result.detail, CGRect(x: 495.5, y: 0, width: 371.5, height: 553))
        XCTAssertEqual(result.editor, result.detail)
        XCTAssertEqual(result.detail.minX - result.list.maxX, 40)
        XCTAssertFalse(result.list.intersects(book.frame))
        XCTAssertFalse(result.editor.intersects(book.frame))
    }

    func testLaptopWithoutARailPutsTheListAboveAndTheEditorBelowTheFold() {
        let result = layout(tall, fold: laptop, selectedHostID: UUID(), isRailMode: false)
        let expected = ManagementSplitPolicy.Split(
            list: CGRect(x: 0, y: 0, width: 669, height: 373.5),
            detail: CGRect(x: 0, y: 413.5, width: 669, height: 373.5)
        )
        XCTAssertEqual(result.arrangement, .listOverDetail(split: expected))
        XCTAssertEqual(result.list, expected.list)
        XCTAssertEqual(result.detail, expected.detail)
        XCTAssertEqual(result.editor, expected.detail)
        XCTAssertFalse(result.editorCoversList)
        XCTAssertFalse(result.list.intersects(laptop.frame))
        XCTAssertFalse(result.editor.intersects(laptop.frame))
    }

    func testInnerTallWithoutAFoldStillUsesASinglePane() {
        for railMode in [false, true] {
            XCTAssertEqual(layout(tall, isRailMode: railMode).arrangement, .single)
        }
    }

    func testEverySplitStartsWithAnEmptyDetailAndNeverSelectsAHost() {
        for (size, fold, railMode) in [(wide, nil, true), (wide, book, true), (tall, laptop, false)] {
            let result = layout(size, fold: fold, isRailMode: railMode)
            XCTAssertTrue(result.isSplit)
            XCTAssertEqual(result.detailContent, .empty)
        }
    }

    func testTheSameSelectionSurvivesSingleWideBookLaptopAndSingleAgain() {
        let id = UUID()
        for (size, fold, railMode) in [
            (outer, nil, true), (wide, nil, true), (wide, book, true),
            (tall, laptop, false), (tall, nil, false), (outer, nil, true)
        ] {
            XCTAssertEqual(layout(size, fold: fold, selectedHostID: id, isRailMode: railMode).detailContent, .editor(id))
        }
    }

    func testChoosingAnotherHostChangesOnlyTheDetailSelection() {
        let first = UUID()
        let second = UUID()
        for (size, fold) in [(wide, nil), (wide, book), (tall, laptop)] {
            let before = layout(size, fold: fold, selectedHostID: first)
            let after = layout(size, fold: fold, selectedHostID: second)
            XCTAssertEqual(before.detailContent, .editor(first))
            XCTAssertEqual(after.detailContent, .editor(second))
            XCTAssertEqual(before.arrangement, after.arrangement)
            XCTAssertEqual(before.list, after.list)
            XCTAssertEqual(before.editor, after.editor)
        }
    }

    func testClearingSelectionAfterCancelOrDeleteRestoresEmptyDetailWithoutMovingTheList() {
        for (size, fold) in [(wide, nil), (wide, book), (tall, laptop)] {
            let before = layout(size, fold: fold, selectedHostID: UUID())
            let after = layout(size, fold: fold)
            XCTAssertEqual(after.detailContent, .empty)
            XCTAssertEqual(before.arrangement, after.arrangement)
            XCTAssertEqual(before.list, after.list)
            XCTAssertEqual(before.detail, after.detail)
        }
    }

    func testKeyboardReducedLaptopProposalKeepsTheEditorReachableAndTheFoldClear() {
        let id = UUID()
        for height in [550.0, 413.5, 373.5, 280.0] {
            let size = CGSize(width: tall.width, height: height)
            let result = layout(size, fold: laptop, selectedHostID: id, isRailMode: false)
            XCTAssertEqual(result.editor, CGRect(x: 0, y: 0, width: 669, height: min(height, 373.5)))
            XCTAssertTrue(result.editorCoversList)
            XCTAssertEqual(result.detailContent, .editor(id))
            XCTAssertLessThanOrEqual(result.editor.maxY, height)
            XCTAssertFalse(result.editor.intersects(laptop.frame))
        }
    }

    func testLaptopKeepsTheEditorBelowTheFoldWhileThereIsRoomForItsForm() {
        let result = layout(CGSize(width: 669, height: 653.5), fold: laptop, selectedHostID: UUID(), isRailMode: false)
        XCTAssertEqual(result.editor, CGRect(x: 0, y: 413.5, width: 669, height: 240))
        XCTAssertFalse(result.editorCoversList)
    }

    func testKeyboardFallbackDoesNotHideAnUnselectedHostsList() {
        let result = layout(CGSize(width: 669, height: 373.5), fold: laptop, isRailMode: false)
        XCTAssertEqual(result.detailContent, .empty)
        XCTAssertEqual(result.editor, result.detail)
        XCTAssertFalse(result.editorCoversList)
        XCTAssertEqual(result.list.height, 373.5)
    }

    func testSearchKeyboardKeepsTheListVisibleAndRetainsTheUnfocusedEditorSizeBelowTheFold() {
        let id = UUID()
        let retained = CGSize(width: 669, height: 373.5)
        for height in [550.0, 373.5, 280.0] {
            let result = layout(
                CGSize(width: 669, height: height), fold: laptop, selectedHostID: id,
                isRailMode: false, isSearching: true, retainedEditorSize: retained
            )
            XCTAssertFalse(result.editorCoversList)
            XCTAssertEqual(result.editor, CGRect(x: 0, y: 413.5, width: 669, height: retained.height))
            XCTAssertFalse(result.editor.intersects(laptop.frame))
            XCTAssertEqual(result.detailContent, .editor(id))
        }
    }

    func testSearchKeyboardUsesTheNormalSafeAreaHeightBesideDetail() {
        let result = layout(
            CGSize(width: 867, height: 300), selectedHostID: UUID(), isSearching: true,
            retainedEditorSize: CGSize(width: 524, height: 553)
        )
        XCTAssertEqual(result.editor, CGRect(x: 343, y: 0, width: 524, height: 300))
        XCTAssertFalse(result.editorCoversList)
    }

    func testNarrowManagementColumnsUseOneColumnAndOuterDisplayKeepsTodaysGrid() {
        for width in [320.0, 330.0, 342.5, 343.0] {
            XCTAssertTrue(HostsSplitLayout.usesSingleColumn(isSplit: true, width: width))
            XCTAssertFalse(HostsSplitLayout.usesSingleColumn(isSplit: false, width: width))
        }
        for width in [343.5, 382.0, 455.5, 669.0] {
            XCTAssertFalse(HostsSplitLayout.usesSingleColumn(isSplit: true, width: width))
        }
    }

    func testReturningToAPoseRestoresTheSameRectanglesAndSelection() {
        let id = UUID()
        let before = layout(wide, fold: book, selectedHostID: id)
        _ = layout(tall, fold: laptop, selectedHostID: id, isRailMode: false)
        _ = layout(outer, selectedHostID: id)
        XCTAssertEqual(layout(wide, fold: book, selectedHostID: id), before)
    }

    func testAFoldWithNoRoomForAPaneOnOneSideIsNoFold() {
        // The shared pane geometry's rule: no zero-width list beside it.
        for x in [-10.0, 0, 150] {
            let fold = DuoFold(frame: CGRect(x: x, y: 0, width: 40, height: 553), splitsSideBySide: true)
            XCTAssertEqual(layout(wide, fold: fold), layout(wide), "fold at \(x)")
        }
    }

    func testMovingHingeKeepsTheLastHostsLayoutUntilOneSettledFoldArrives() {
        let id = UUID()
        var settlement = DuoFoldSettlement()
        _ = settlement.update(current: nil, hinge: .none)
        let before = layout(wide, fold: settlement.fold, selectedHostID: id)
        for x in [430.0, 440.0, 455.5] {
            let moving = DuoFold(frame: CGRect(x: x, y: 0, width: 40, height: 553), splitsSideBySide: true)
            XCTAssertFalse(settlement.update(current: moving, hinge: .moving))
            XCTAssertEqual(layout(wide, fold: settlement.fold, selectedHostID: id), before)
        }
        XCTAssertTrue(settlement.update(current: book, hinge: .settled(.partiallyOpen)))
        let after = layout(wide, fold: settlement.fold, selectedHostID: id)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.detailContent, .editor(id))
        XCTAssertFalse(settlement.update(current: book, hinge: .settled(.partiallyOpen)))
        XCTAssertEqual(layout(wide, fold: settlement.fold, selectedHostID: id), after)
    }

    func testDeletingAnotherHostFromTheListKeepsTheOpenEditor() {
        let edited = UUID(), other = UUID()
        XCTAssertFalse(HostsSplitLayout.deletionClearsSelection(deleted: other, selected: edited))
        XCTAssertTrue(HostsSplitLayout.deletionClearsSelection(deleted: edited, selected: edited))
        XCTAssertTrue(HostsSplitLayout.deletionClearsSelection(deleted: other, selected: nil))
    }

    /// Laptop pose with nothing selected: the split stops above the tab bar,
    /// which keeps its taps; otherwise the overlay's whole frame is its own.
    func testTheUnselectedLaptopSplitLeavesTheTabBarItsTaps() {
        let rect = CGRect(x: 0, y: 0, width: 402, height: 820)
        let bounded = CompactOverlayHitShape(bottom: 771).path(in: rect)
        XCTAssertTrue(bounded.contains(CGPoint(x: 200, y: 770)))
        XCTAssertFalse(bounded.contains(CGPoint(x: 200, y: 790)), "the tab bar's band")
        let whole = CompactOverlayHitShape(bottom: nil).path(in: rect)
        XCTAssertEqual(whole.boundingRect, rect)
    }

    /// Over a docked keyboard the session's accessory bar runs on past the
    /// panes, over the rail: its keys there take taps, the rail above keeps its own.
    func testTheKeyboardSpanningBarTakesTapsOverTheRail() {
        let panes = CGRect(x: 0, y: 0, width: 867, height: 442)
        let bar = CGRect(x: 0, y: 390, width: 951, height: 52)
        let shape = CompactOverlayHitShape(bottom: nil, keyboardBar: bar).path(in: panes)
        XCTAssertTrue(shape.contains(CGPoint(x: 930, y: 415)), "the bar's keyboard toggle over the rail")
        XCTAssertTrue(shape.contains(CGPoint(x: 400, y: 200)), "the panes")
        XCTAssertFalse(shape.contains(CGPoint(x: 930, y: 200)), "the rail's own buttons")
    }

    /// Laptop pose has no tab bar, so the hosts title's ⌄ is the only way to
    /// another section: a split keeps the page's header above its scrolling
    /// hosts. A single column (the tab bar is there) scrolls it with them.
    @MainActor
    func testASplitKeepsItsTitleSwitcherAboveItsScrollingHosts() throws {
        let container = try TesseraModelContainer.make(inMemory: true)
        for index in 0..<12 {
            container.mainContext.insert(PersistedHost(name: "host \(index)", address: "10.0.0.\(index)", sortOrder: index))
        }
        try container.mainContext.save()
        let suite = "HostsSplitLayoutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        var measured: [Bool: (top: CGFloat, content: CGFloat)] = [:]
        for isSplit in [true, false] {
            let landing = HostsLandingView(
                onConnect: { _ in }, onEdit: { _ in }, onDelete: { _ in }, onNewHost: {},
                onQuickConnect: { _ in }, onOpenKeys: {}, onGenerateKey: {},
                activeHostKeys: [], activeHostTmuxUsage: [:], isManagementSplit: isSplit
            )
            .environment(AppearancePreferences())
            .environment(ConnectionActivityStore(defaults: defaults))
            .environment(\.duoOpenSwitcher, DuoSwitcherAction {})
            .modelContainer(container)
            let controller = UIHostingController(rootView: landing)
            controller.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            // The laptop's upper half.
            window.frame = CGRect(x: 0, y: 0, width: 669, height: 373)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            settle(controller)
            let scroll = try XCTUnwrap(Self.firstScrollView(in: controller.view))
            let end = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            XCTAssertGreaterThan(end, 100, "split \(isSplit): twelve hosts scroll")
            scroll.contentOffset.y = end
            settle(controller)
            let frame = try XCTUnwrap(scroll.superview).convert(scroll.frame, to: window)
            measured[isSplit] = (frame.minY, scroll.contentSize.height)
        }
        let split = try XCTUnwrap(measured[true]), column = try XCTUnwrap(measured[false])
        XCTAssertEqual(column.top, 0, accuracy: 1, "the single column scrolls from the top, its header with it")
        XCTAssertGreaterThan(split.top, 40, "the split's header, title and ⌄, sits above its scrolling hosts")
        XCTAssertEqual(column.content - split.content, split.top, accuracy: 2,
                       "the header left the split's scrolling content, and nothing else did")
    }

    @MainActor
    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }

    @MainActor
    private func settle(_ controller: UIViewController) {
        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }

    private func layout(
        _ container: CGSize, fold: DuoFold? = nil, selectedHostID: UUID? = nil,
        isRailMode: Bool = true, isPhone: Bool = true,
        isSearching: Bool = false, retainedEditorSize: CGSize? = nil
    ) -> HostsSplitLayout {
        HostsSplitLayout.layout(
            isPhone: isPhone, isRailMode: isRailMode, container: container,
            fold: fold, selectedHostID: selectedHostID,
            isSearching: isSearching, retainedEditorSize: retainedEditorSize
        )
    }
}
