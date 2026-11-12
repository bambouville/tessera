import SwiftUI
import XCTest
@testable import Tessera

final class LaptopShellPolicyTests: XCTestCase {
    private let session = UUID(uuidString: "D0020000-0000-4000-8000-000000000001")!
    private let host = UUID(uuidString: "D0020000-0000-4000-8000-000000000002")!

    /// The inner display's fold, partly folded in portrait (669×951).
    private let laptopFold = DuoFold(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), splitsSideBySide: false)
    /// Folded like a book, the inner display held wide.
    private let bookFold = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), splitsSideBySide: true)

    private func change(
        to tab: CompactRootTab, from currentTab: CompactRootTab,
        selection: SidebarItem? = nil, agents: Bool = true
    ) -> LaptopShellPolicy.SectionChange {
        LaptopShellPolicy.change(to: tab, currentTab: currentTab, currentSelection: selection, agentCenterEnabled: agents)
    }

    func testLaptopPoseNeedsAPhoneASettledFoldAcrossTheScreenAndNoRail() {
        XCTAssertTrue(LaptopShellPolicy.isLaptopPose(isPhone: true, railEdge: nil, fold: laptopFold))
        XCTAssertFalse(LaptopShellPolicy.isLaptopPose(isPhone: true, railEdge: nil, fold: nil), "closed or open flat")
        XCTAssertFalse(LaptopShellPolicy.isLaptopPose(isPhone: true, railEdge: nil, fold: bookFold), "folded like a book")
        XCTAssertFalse(LaptopShellPolicy.isLaptopPose(isPhone: true, railEdge: .trailing, fold: laptopFold), "the rail keeps its sections")
        XCTAssertFalse(LaptopShellPolicy.isLaptopPose(isPhone: false, railEdge: nil, fold: laptopFold), "iPad is untouched")
    }

    func testSectionsFollowTheTabBar() {
        XCTAssertEqual(LaptopShellPolicy.sections(agentCenterEnabled: true), [.hosts, .sessions, .agents, .artifacts, .settings])
        XCTAssertEqual(LaptopShellPolicy.sections(agentCenterEnabled: false), [.hosts, .sessions, .artifacts, .settings])
        let tabs: [CompactRootTab] = [.hosts, .sessions, .agents, .artifacts, .settings]
        XCTAssertEqual(tabs.map(\.sectionSymbol),
                       ["server.rack", "rectangle.stack.fill", "sparkles", "square.stack.3d.up", "gearshape.fill"])
        XCTAssertEqual(Set(tabs.map(\.sectionIdentifier)).count, tabs.count)
    }

    func testFromATabsOwnPageASectionDoesWhatItsTabWould() {
        XCTAssertEqual(change(to: .sessions, from: .hosts), .selectTab(.sessions))
        XCTAssertEqual(change(to: .agents, from: .hosts, selection: nil), .selectTab(.agents))
        XCTAssertEqual(change(to: .artifacts, from: .agents, selection: .agents), .selectTab(.artifacts))
        XCTAssertEqual(change(to: .settings, from: .artifacts, selection: .artifacts), .selectTab(.settings))
        XCTAssertEqual(change(to: .hosts, from: .settings, selection: .settings), .selectTab(.hosts))
        XCTAssertEqual(change(to: .hosts, from: .settings, selection: .keys), .selectTab(.hosts))
    }

    func testTheCurrentSectionStays() {
        for tab in [CompactRootTab.hosts, .sessions, .agents, .artifacts, .settings] {
            XCTAssertEqual(change(to: tab, from: tab, selection: LaptopShellPolicy.destination(of: tab)), .stay, "\(tab)")
        }
        XCTAssertEqual(change(to: .sessions, from: .sessions, selection: .session(session)), .stay,
                       "a session's section is sessions; tapping it keeps the terminal")
        XCTAssertEqual(change(to: .hosts, from: .hosts, selection: .host(host)), .stay)
    }

    func testFromASessionASectionLeavesItForItsDestination() {
        let selection = SidebarItem.session(session)
        XCTAssertEqual(change(to: .hosts, from: .sessions, selection: selection), .leave(to: nil, tab: .hosts))
        XCTAssertEqual(change(to: .agents, from: .sessions, selection: selection), .leave(to: .agents, tab: .agents))
        XCTAssertEqual(change(to: .artifacts, from: .sessions, selection: selection), .leave(to: .artifacts, tab: .artifacts))
        XCTAssertEqual(change(to: .settings, from: .sessions, selection: selection), .leave(to: .settings, tab: .settings))
    }

    func testFromAHostEditorASectionLeavesIt() {
        let selection = SidebarItem.host(host)
        XCTAssertEqual(change(to: .sessions, from: .hosts, selection: selection), .leave(to: nil, tab: .sessions))
        XCTAssertEqual(change(to: .artifacts, from: .hosts, selection: selection), .leave(to: .artifacts, tab: .artifacts))
    }

    func testAHiddenAgentsSectionResolvesToSessionsAsTheTabViewDoes() {
        XCTAssertEqual(change(to: .agents, from: .hosts, agents: false), .selectTab(.sessions))
        XCTAssertEqual(change(to: .agents, from: .sessions, agents: false), .stay)
        XCTAssertEqual(change(to: .sessions, from: .agents, agents: false), .stay, "a stale agents tab already shows sessions")
        XCTAssertEqual(change(to: .agents, from: .sessions, selection: .session(session), agents: false), .stay)
    }

    func testDestinationsMatchTheTabViewsOwnSelection() {
        XCTAssertNil(LaptopShellPolicy.destination(of: .hosts))
        XCTAssertNil(LaptopShellPolicy.destination(of: .sessions))
        XCTAssertEqual(LaptopShellPolicy.destination(of: .agents), .agents)
        XCTAssertEqual(LaptopShellPolicy.destination(of: .artifacts), .artifacts)
        XCTAssertEqual(LaptopShellPolicy.destination(of: .settings), .settings)
    }

    func testThePaletteHangsFromTheTitleAboveTheFold() {
        XCTAssertEqual(LaptopPaletteLayout.width(container: 669), 649, "the screen's width, inside its margins")
        XCTAssertEqual(LaptopPaletteLayout.width(container: 400), 380)
        XCTAssertEqual(LaptopPaletteLayout.width(container: 0), 0)
        // The inner display's top row, then the title: the card ends 8 pt above the fold.
        let top: CGFloat = 54 + LaptopPaletteLayout.titleClearance
        let height = LaptopPaletteLayout.maxHeight(top: top, foldTop: laptopFold.frame.minY)
        XCTAssertEqual(top + height, laptopFold.frame.minY - LaptopPaletteLayout.foldClearance)
        XCTAssertEqual(LaptopPaletteLayout.maxHeight(top: 500, foldTop: laptopFold.frame.minY), 0, "never onto the hinge")
    }

    func testTheTitleSwitcherIsLaptopOnly() {
        var environment = EnvironmentValues()
        XCTAssertNil(environment.duoTitleSwitcher, "the tab bar has its sections")
        environment.duoOpenSwitcher = DuoSwitcherAction {}
        XCTAssertNotNil(environment.duoTitleSwitcher)
        environment.duoRailMode = true
        XCTAssertNil(environment.duoTitleSwitcher, "the rail has its own ▾")
    }

    #if DEBUG
    func testTheSyntheticFoldSitsWhereTheInnerDisplaysDoes() {
        XCTAssertEqual(DuoSyntheticLaptopFold.frame(window: CGSize(width: 669, height: 951)), laptopFold.frame)
        let tall = DuoSyntheticLaptopFold.frame(window: CGSize(width: 440, height: 956))
        XCTAssertEqual(tall.width, 440)
        XCTAssertEqual(tall.height, 40)
        XCTAssertEqual(tall.minY / 956, 455.5 / 951, accuracy: 0.0001)
    }
    #endif

    func testAHalfHeightSheetRestsOnTheDeskBelowTheHinge() throws {
        // The window's fold, above a 34 pt home indicator: a height detent
        // leaves that out, so the sheet's top lands on the fold's bottom.
        let desk = try XCTUnwrap(LaptopSheetLayout.deskHeight(safeBottom: 951 - 34, fold: laptopFold))
        XCTAssertEqual(desk, 951 - 34 - laptopFold.frame.maxY)

        XCTAssertEqual(LaptopSheetLayout.detents([.medium, .large], desk: desk), [.height(desk), .large])
        XCTAssertEqual(LaptopSheetLayout.detents([.large], desk: desk), [.large], "a full sheet stays")
        XCTAssertEqual(LaptopSheetLayout.detents([.medium, .large], desk: nil), [.medium, .large])
    }

    /// L-08: iOS rested the half sheet's top 8 pt up the hinge on the Duo
    /// and 8.6 pt below the fold on an iPhone. Where it rests corrects the
    /// detent, a few times at most, until it lands on the fold's bottom.
    func testASheetsRestingTopCorrectsItsDetentOntoTheFoldsBottom() {
        let foldBottom = laptopFold.frame.maxY
        let desk = 951 - 34 - foldBottom
        typealias Layout = LaptopSheetLayout
        let duo = Layout.calibration(after: foldBottom - 8, foldBottom: foldBottom, desk: desk, current: nil)
        XCTAssertEqual(duo, .init(desk: desk, offset: -8, corrections: 1))
        XCTAssertEqual(Layout.restingDesk(desk: desk, calibration: duo), desk - 8)
        XCTAssertEqual(Layout.calibration(after: foldBottom + 0.2, foldBottom: foldBottom, desk: desk, current: duo), duo,
                       "a top on the fold's bottom keeps the detent")

        let phone = Layout.calibration(after: foldBottom + 8.6, foldBottom: foldBottom, desk: desk, current: nil)
        let refined = Layout.calibration(after: foldBottom + 2, foldBottom: foldBottom, desk: desk, current: phone)
        XCTAssertEqual(Layout.restingDesk(desk: desk, calibration: refined) ?? 0, desk + 10.6, accuracy: 0.001,
                       "a correction that missed corrects again")
        let third = Layout.calibration(after: foldBottom + 1, foldBottom: foldBottom, desk: desk, current: refined)
        XCTAssertEqual(third?.corrections, 3)
        XCTAssertEqual(Layout.calibration(after: foldBottom + 1, foldBottom: foldBottom, desk: desk, current: third), third,
                       "three corrections are the most")

        XCTAssertNil(Layout.calibration(after: 60, foldBottom: foldBottom, desk: desk, current: nil),
                     "the full detent's top is no reading of the desk")
        XCTAssertEqual(Layout.calibration(after: foldBottom - 30, foldBottom: foldBottom, desk: desk, current: duo), duo,
                       "nor is a sheet lifted by a keyboard's bar")
        XCTAssertEqual(Layout.restingDesk(desk: desk - 100, calibration: duo), desk - 100, "another desk starts uncorrected")
        XCTAssertEqual(Layout.calibration(after: foldBottom - 8, foldBottom: foldBottom, desk: desk - 100, current: third),
                       .init(desk: desk - 100, offset: -8, corrections: 1))
        XCTAssertNil(Layout.restingDesk(desk: nil, calibration: duo))
    }

    /// The next sheet opens where the last came to rest, and may still
    /// correct three times of its own.
    @MainActor
    func testTheNextSheetStartsFromTheLastCorrection() {
        let saved = LaptopSheetLayout.rememberedCalibration
        defer { LaptopSheetLayout.rememberedCalibration = saved }
        LaptopSheetLayout.remember(.init(desk: 380, offset: 8.6, corrections: 3))
        XCTAssertEqual(LaptopSheetLayout.rememberedCalibration, .init(desk: 380, offset: 8.6))
        LaptopSheetLayout.remember(nil)
        XCTAssertEqual(LaptopSheetLayout.rememberedCalibration, .init(desk: 380, offset: 8.6), "no correction keeps the last")
    }

    func testSheetsKeepTheirDetentsOffTheLaptopsFold() {
        XCTAssertNil(LaptopSheetLayout.deskHeight(safeBottom: 600, fold: nil))
        XCTAssertNil(LaptopSheetLayout.deskHeight(safeBottom: 600, fold: bookFold))
        let lowFold = DuoFold(frame: CGRect(x: 0, y: 420, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertNil(LaptopSheetLayout.deskHeight(safeBottom: 600, fold: lowFold), "too little desk for a sheet")
    }
}

/// The lock screen, onboarding and continuation cards in laptop pose.
final class LaptopCardLayoutTests: XCTestCase {
    /// The inner display's fold, partly folded in portrait (669×951), read
    /// over the whole window.
    private let laptopFold = DuoFold(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), splitsSideBySide: false)
    /// Folded like a book, the inner display held wide.
    private let bookFold = DuoFold(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), splitsSideBySide: true)
    /// The inner display's top row.
    private let statusBar: CGFloat = 54

    func testACardCentresOnTheScreenAboveTheFoldBelowTheTopSafeArea() {
        let foldTop = laptopFold.frame.minY - LaptopPaletteLayout.foldClearance
        // A layer over the whole window, like the lock screen's.
        let window = LaptopCardLayout(fold: laptopFold, windowTopInset: statusBar, layerMinY: 0)
        XCTAssertEqual(window.topInset, statusBar)
        XCTAssertEqual(window.screen, statusBar...foldTop)
        // A layer below the top safe area, like the continuation overlay's,
        // reads the fold that much higher, and has no inset of its own.
        let below = DuoFold(frame: laptopFold.frame.offsetBy(dx: 0, dy: -statusBar), splitsSideBySide: false)
        let inset = LaptopCardLayout(fold: below, windowTopInset: statusBar, layerMinY: statusBar)
        XCTAssertEqual(inset.topInset, 0)
        XCTAssertEqual(inset.screen, 0...(foldTop - statusBar))
    }

    func testEveryOtherPoseKeepsTheCardCentredOnItsWindow() {
        XCTAssertNil(LaptopCardLayout().screen, "no fold: every device but a Duo")
        XCTAssertNil(LaptopCardLayout(fold: bookFold, windowTopInset: statusBar).screen, "folded like a book")
        let high = DuoFold(frame: CGRect(x: 0, y: 40, width: 669, height: 40), splitsSideBySide: false)
        XCTAssertNil(LaptopCardLayout(fold: high, windowTopInset: statusBar).screen, "no screen above the fold to centre on")
    }

    func testACalloutCrossingTheHingeMovesPastItAwayFromItsTarget() {
        let layout = LaptopCardLayout(fold: laptopFold, windowTopInset: statusBar)
        let height: CGFloat = 188
        let hinge = laptopFold.frame
        // A target on the screen: the callout below it would end on the hinge, so it rests on the desk.
        let onScreen = CGRect(x: 200, y: 280, width: 260, height: 50)
        XCTAssertEqual(layout.calloutY(onScreen.maxY + 14, height: height, target: onScreen, containerHeight: 951),
                       hinge.maxY + LaptopPaletteLayout.foldClearance)
        // A target on the desk: the callout above it moves up onto the screen.
        let onDesk = CGRect(x: 200, y: 600, width: 260, height: 50)
        let raised = layout.calloutY(onDesk.minY - 14 - height, height: height, target: onDesk, containerHeight: 951)
        XCTAssertEqual(raised + height, hinge.minY - LaptopPaletteLayout.foldClearance)
        // Clear of the hinge, or in any other pose, it stays.
        XCTAssertEqual(layout.calloutY(100, height: height, target: onScreen, containerHeight: 951), 100)
        XCTAssertEqual(layout.calloutY(hinge.maxY + 8, height: height, target: onScreen, containerHeight: 951), hinge.maxY + 8)
        XCTAssertEqual(LaptopCardLayout().calloutY(344, height: height, target: onScreen, containerHeight: 951), 344)
        XCTAssertEqual(LaptopCardLayout(fold: bookFold).calloutY(344, height: height, target: onScreen, containerHeight: 951), 344)
    }
}

/// L-08 with a real sheet: presented in a window with the laptop's desk in
/// its environment, a half sheet's top lands on the fold's bottom wherever
/// this iOS floats it. Also proves the sheet's `.global` space is the window's.
@MainActor
final class LaptopSheetPresentationTests: XCTestCase {
    private struct Host: View {
        let desk: CGFloat
        let foldBottom: CGFloat
        var body: some View {
            Color.clear
                .sheet(isPresented: .constant(true)) {
                    Color.gray.laptopSheetDetents([.medium, .large])
                }
                .environment(\.laptopDeskHeight, desk)
                .environment(\.laptopFoldBottom, foldBottom)
        }
    }

    func testAHalfSheetOnTheDeskPutsItsTopOnTheFoldsBottom() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        let height = window.bounds.height
        // The inner display's fold, scaled to this window as the iPhone rig does.
        let fold = DuoFold(frame: CGRect(x: 0, y: height * 455.5 / 951, width: window.bounds.width, height: 40),
                           splitsSideBySide: false)
        let desk = try XCTUnwrap(LaptopSheetLayout.deskHeight(safeBottom: height - window.safeAreaInsets.bottom, fold: fold))
        window.rootViewController = UIHostingController(rootView: Host(desk: desk, foldBottom: fold.frame.maxY))

        var top: CGFloat?
        let deadline = Date().addingTimeInterval(10)
        // The sheet arrives, then settles once its own safe area is read.
        var settledSince: Date?
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let sheet = window.rootViewController?.presentedViewController, !sheet.isBeingPresented,
                  let view = sheet.view else { continue }
            let minY = view.convert(view.bounds, to: window).minY
            if minY == top {
                if let since = settledSince, Date().timeIntervalSince(since) > 1 { break }
            } else {
                top = minY
                settledSince = Date()
            }
        }
        let landed = try XCTUnwrap(top, "no sheet presented")
        XCTAssertEqual(landed, fold.frame.maxY, accuracy: 1, "the sheet's top rests on the fold's bottom")
    }
}
