import SwiftUI
import TesseraArtifactsCore
import TesseraCore
import XCTest
#if canImport(UIKit)
import UIKit
import WebKit
#endif
@testable import Tessera

final class DuoWorkspaceStateTests: XCTestCase {
    func testDefaultsShowMainAndContextWithoutAPresentation() {
        let state = DuoWorkspaceState()
        XCTAssertFalse(state.contextHidden)
        XCTAssertFalse(state.fullScreen)
        XCTAssertFalse(state.swapped)
    }

    func testTheLaptopDeskKeepsTheSessionOnTopAndTheContextShownWithoutForgettingTheRail() {
        var rail = DuoWorkspaceState()
        rail.swap()
        rail.toggleFullScreen()
        rail.contextHidden = true
        let desk = rail.laidOut(onTheDesk: true)
        XCTAssertFalse(desk.swapped)
        XCTAssertFalse(desk.fullScreen)
        XCTAssertFalse(desk.contextHidden)
        XCTAssertEqual(rail.laidOut(onTheDesk: false), rail, "the rail gets its own state back")
    }

    func testTheDeskTradesItsHalvesWithoutTouchingTheRailsSwap() {
        var state = DuoWorkspaceState()
        state.tradeDesk()
        XCTAssertTrue(state.deskTraded)
        XCTAssertFalse(state.swapped, "the rail's swap waits for the rail")
        XCTAssertTrue(state.laidOut(onTheDesk: true).swapped, "the context stands on top, the session on the desk")
        XCTAssertFalse(state.laidOut(onTheDesk: false).swapped, "the rail never shows the desk's trade")

        state.swap()
        state.tradeDesk()
        XCTAssertFalse(state.deskTraded)
        XCTAssertFalse(state.laidOut(onTheDesk: true).swapped, "the session is back on top")
        XCTAssertTrue(state.laidOut(onTheDesk: false).swapped, "the rail's own swap survives the desk")
    }

    /// Laptop pose, inner display: the fold 455.5–495.5, the keyboard
    /// reported from the fold's top, the context's free desk below a bar.
    func testOnlyTheKeyboardRisingForAFieldOnTheDeskTrades() {
        let desk = CGRect(x: 0, y: 547.5, width: 669, height: 403.5)
        let formField = CGRect(x: 16, y: 620, width: 320, height: 36)
        XCTAssertTrue(DuoDeskTradePolicy.trades(responder: formField, desk: desk, keyboardTop: 455.5))
        let webPage = CGRect(x: 0, y: 576, width: 669, height: 375)
        XCTAssertTrue(DuoDeskTradePolicy.trades(responder: webPage, desk: desk, keyboardTop: 455.5),
                      "a web form's content view counts by the page its web view shows")

        let terminalOnTop = CGRect(x: 4, y: 52, width: 661, height: 403.5)
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: terminalOnTop, desk: desk, keyboardTop: 455.5))
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: formField, desk: desk, keyboardTop: 896),
                       "a hardware keyboard's shortcut bar leaves the desk standing")
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: nil, desk: desk, keyboardTop: 455.5),
                       "a sheet's field, or none")
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: formField, desk: nil, keyboardTop: 455.5))
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: .null, desk: desk, keyboardTop: 455.5))

        // Traded, the session lies on the desk: a tap on its terminal trades it back up.
        let deskHalf = CGRect(x: 0, y: 495.5, width: 669, height: 455.5)
        let terminalOnTheDesk = CGRect(x: 4, y: 547.5, width: 661, height: 350)
        XCTAssertTrue(DuoDeskTradePolicy.trades(responder: terminalOnTheDesk, desk: deskHalf, keyboardTop: 455.5))

        // The phone rig's fold (356.6–396.6 on an 874 pt window) and its
        // shorter keyboard, top at 563: it hides a terminal on the desk, but
        // not a field near the desk's top.
        let rigDesk = CGRect(x: 0, y: 396.6, width: 402, height: 477.4)
        XCTAssertTrue(DuoDeskTradePolicy.trades(responder: CGRect(x: 0, y: 424.6, width: 402, height: 449.4),
                                                desk: rigDesk, keyboardTop: 563))
        XCTAssertFalse(DuoDeskTradePolicy.trades(responder: CGRect(x: 16, y: 420, width: 320, height: 36),
                                                 desk: rigDesk, keyboardTop: 563),
                       "a field the keyboard leaves in view stays where it is")
    }

    func testBookHidesAndRestoresBothTwoPaneArrangements() {
        for arrangement in [DuoPaneArrangement.sideBySide, .stacked] {
            var state = DuoWorkspaceState()
            state.toggleContext(arrangement: arrangement)
            XCTAssertTrue(state.contextHidden)
            state.toggleContext(arrangement: arrangement)
            XCTAssertEqual(state, DuoWorkspaceState())
        }
    }

    func testBookReadsPressedOnlyWhileTheContextIsBesideTheMainPane() {
        for arrangement in [DuoPaneArrangement.sideBySide, .stacked] {
            var state = DuoWorkspaceState()
            XCTAssertTrue(state.showsContextPane(arrangement: arrangement))
            state.swap()
            XCTAssertTrue(state.showsContextPane(arrangement: arrangement), "swapped panes are both on screen")
            state.toggleFullScreen()
            XCTAssertFalse(state.showsContextPane(arrangement: arrangement), "either pane full screen")
            state.toggleFullScreen()
            XCTAssertTrue(state.showsContextPane(arrangement: arrangement))
            state.toggleContext(arrangement: arrangement)
            XCTAssertFalse(state.showsContextPane(arrangement: arrangement), "hidden context")
        }
        XCTAssertFalse(DuoWorkspaceState().showsContextPane(arrangement: .single), "one pane has no book")
    }

    /// One pane has no room for the context: the rail hides the book, and
    /// a toggle that reaches the state anyway leaves it as it was.
    func testTheBookLeavesOnePaneAsItWas() {
        for start in [DuoWorkspaceState(), DuoWorkspaceState(contextHidden: true),
                      DuoWorkspaceState(fullScreen: true, swapped: true)] {
            var state = start
            state.toggleContext(arrangement: .single)
            XCTAssertEqual(state, start)
        }
    }

    func testFullScreenShowsTheContextAgainOnExit() {
        var state = DuoWorkspaceState(contextHidden: true)
        state.toggleFullScreen()
        XCTAssertTrue(state.fullScreen)
        XCTAssertFalse(state.contextHidden)
        state.toggleFullScreen()
        XCTAssertEqual(state, DuoWorkspaceState())
    }

    func testBookExitsFullScreenAndShowsTheContext() {
        for arrangement in [DuoPaneArrangement.sideBySide, .stacked] {
            var state = DuoWorkspaceState(fullScreen: true)
            state.toggleContext(arrangement: arrangement)
            XCTAssertFalse(state.fullScreen)
            XCTAssertFalse(state.contextHidden)
        }
    }

    func testSwapReversesWithoutDiscardingHiddenState() {
        var state = DuoWorkspaceState(contextHidden: true)
        state.swap()
        XCTAssertTrue(state.swapped)
        XCTAssertTrue(state.contextHidden)
        state.swap()
        XCTAssertFalse(state.swapped)
        XCTAssertTrue(state.contextHidden)
    }

    func testContextFullScreenSwapsFirstAndExitKeepsItMain() {
        var state = DuoWorkspaceState()
        state.swap()
        state.toggleFullScreen()
        XCTAssertTrue(state.swapped)
        XCTAssertTrue(state.fullScreen)
        state.toggleFullScreen()
        XCTAssertTrue(state.swapped)
        XCTAssertFalse(state.fullScreen)
    }

    func testSwapWhileFullScreenKeepsThePresentation() {
        var state = DuoWorkspaceState(fullScreen: true)
        state.swap()
        XCTAssertTrue(state.swapped)
        XCTAssertTrue(state.fullScreen)
    }

    func testWorkspaceEnvironmentDefaultsToNilAndCarriesActions() throws {
        var environment = EnvironmentValues()
        XCTAssertNil(environment.duoWorkspace)
        var calls = [String]()
        environment.duoWorkspace = DuoWorkspaceActions(
            arrangement: .stacked, isFullScreen: true, isSwapped: true, isContextShown: false,
            toggleContext: { calls.append("context") }, toggleFullScreen: { calls.append("full screen") },
            swap: { calls.append("swap") }
        )
        let actions = try XCTUnwrap(environment.duoWorkspace)
        XCTAssertEqual(actions.arrangement, .stacked)
        XCTAssertTrue(actions.offersFullScreen, "full screen is offered unless the caller withholds it")
        XCTAssertTrue(actions.isFullScreen)
        XCTAssertTrue(actions.isSwapped)
        XCTAssertFalse(actions.isContextShown)
        actions.toggleContext()
        actions.toggleFullScreen()
        actions.swap()
        XCTAssertEqual(calls, ["context", "full screen", "swap"])
    }

    func testFullScreenNeedsTwoPanesOffTheDesk() {
        XCTAssertTrue(DuoWorkspaceActions.offersFullScreen(arrangement: .sideBySide, onTheDesk: false))
        XCTAssertTrue(DuoWorkspaceActions.offersFullScreen(arrangement: .stacked, onTheDesk: false))
        XCTAssertFalse(DuoWorkspaceActions.offersFullScreen(arrangement: .single, onTheDesk: false),
                       "the closed display's one pane has nothing to leave")
        XCTAssertFalse(DuoWorkspaceActions.offersFullScreen(arrangement: .stacked, onTheDesk: true),
                       "the laptop desk trades its halves instead")
    }

    func testSwapExchangesFramesWithoutExchangingStructuralChildren() {
        let layout = splitLayout
        let normal = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: false, lastPrimarySize: nil, lastSecondarySize: nil
        )
        let swapped = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: true, lastPrimarySize: nil, lastSecondarySize: nil
        )
        XCTAssertEqual(normal.primary, swapped.secondary)
        XCTAssertEqual(normal.secondary, swapped.primary)
        XCTAssertTrue(swapped.primaryVisible)
        XCTAssertTrue(swapped.secondaryVisible)
    }

    func testHiddenSecondaryRetainsItsLastSizeAcrossContainerAndFoldChanges() {
        var layout = splitLayout
        layout.mainSlot = CGRect(x: 0, y: 0, width: 669, height: 787)
        layout.contextSlot = nil
        let placement = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: false, lastPrimarySize: CGSize(width: 524, height: 553),
            lastSecondarySize: CGSize(width: 343, height: 553)
        )
        XCTAssertEqual(placement.primary.size, CGSize(width: 669, height: 787))
        XCTAssertEqual(placement.secondary.size, CGSize(width: 343, height: 553))
        XCTAssertTrue(placement.primaryVisible)
        XCTAssertFalse(placement.secondaryVisible)
    }

    func testFullScreenContextKeepsTheHiddenPrimaryAtItsLastNonzeroSize() {
        var layout = splitLayout
        layout.mainSlot = CGRect(x: 0, y: 0, width: 867, height: 553)
        layout.contextSlot = nil
        let placement = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: true, lastPrimarySize: CGSize(width: 524, height: 553),
            lastSecondarySize: CGSize(width: 343, height: 553)
        )
        XCTAssertEqual(placement.primary.size, CGSize(width: 524, height: 553))
        XCTAssertFalse(placement.primaryVisible)
        XCTAssertEqual(placement.secondary.size, CGSize(width: 867, height: 553))
        XCTAssertTrue(placement.secondaryVisible)
    }

    func testAnInitiallyHiddenPrimaryNeverReceivesAZeroProposal() {
        let layout = DuoPaneLayout(arrangement: .single, mainSlot: .zero, contextSlot: nil)
        let placement = DuoWorkspacePlacement.resolve(
            layout: layout, swapped: true, lastPrimarySize: nil, lastSecondarySize: nil
        )
        XCTAssertGreaterThan(placement.primary.width, 0)
        XCTAssertGreaterThan(placement.primary.height, 0)
        XCTAssertGreaterThan(placement.secondary.width, 0)
        XCTAssertGreaterThan(placement.secondary.height, 0)
    }

    private var splitLayout: DuoPaneLayout {
        DuoPaneLayout(
            arrangement: .sideBySide,
            mainSlot: CGRect(x: 0, y: 0, width: 524, height: 553),
            contextSlot: CGRect(x: 524, y: 0, width: 343, height: 553)
        )
    }
}

#if canImport(UIKit)
@MainActor
final class DuoWorkspaceMountTests: XCTestCase {
    private final class Surface {
        var mounts = 0
        var actions: DuoWorkspaceActions?
        var suspended: Bool?
        weak var view: UIView?
    }

    @MainActor @Observable fileprivate final class StateBox {
        var value = DuoWorkspaceState()
        var binding: Binding<DuoWorkspaceState> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    private struct LiveSurface: UIViewRepresentable {
        let surface: Surface

        func makeUIView(context: Context) -> UIView {
            surface.mounts += 1
            let view = UIView()
            surface.view = view
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            surface.actions = context.environment.duoWorkspace
            surface.suspended = context.environment.duoContextSuspended
        }
    }

    private struct Host: View {
        let state: StateBox
        var enabled: Bool
        let primary: Surface
        let secondary: Surface

        var body: some View {
            DuoWorkspace(state: state.binding, isEnabled: enabled, primaryTakesInput: true, mainIdealWidth: 524) {
                LiveSurface(surface: primary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                LiveSurface(surface: secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()
        }
    }

    func testDisabledWorkspaceNeverMountsSecondaryAndEnablingKeepsPrimaryIdentity() throws {
        let state = StateBox(), primary = Surface(), secondary = Surface()
        let controller = UIHostingController(rootView: Host(state: state, enabled: false, primary: primary, secondary: secondary))
        let window = try mount(controller, size: CGSize(width: 867, height: 553))
        defer { unmount(window) }
        settle(controller)
        let original = try XCTUnwrap(primary.view)
        XCTAssertEqual(primary.mounts, 1)
        XCTAssertEqual(secondary.mounts, 0)
        XCTAssertNil(primary.actions)
        XCTAssertEqual(original.bounds.size, controller.view.bounds.size)

        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(primary.view === original)
        XCTAssertEqual(primary.mounts, 1)
        XCTAssertEqual(secondary.mounts, 1)
        XCTAssertEqual(original.bounds.width, 524, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(secondary.view).bounds.width, 343, accuracy: 1)

        controller.rootView = Host(state: state, enabled: false, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(primary.view === original)
        XCTAssertEqual(primary.mounts, 1)
        XCTAssertNil(primary.actions)
        XCTAssertEqual(original.bounds.size, controller.view.bounds.size)
    }

    /// Inner-wide → inner-tall turns rail mode off. The context keeps its
    /// mount, and with it a docked page, hidden at its last size.
    func testAShownSecondaryOutlivesADisabledPoseAtItsLastSize() throws {
        let state = StateBox(), primary = Surface(), secondary = Surface()
        let controller = UIHostingController(rootView: Host(state: state, enabled: true, primary: primary, secondary: secondary))
        let window = try mount(controller, size: CGSize(width: 867, height: 553))
        defer { unmount(window) }
        settle(controller)
        let context = try XCTUnwrap(secondary.view)
        XCTAssertEqual(secondary.suspended, false)

        controller.rootView = Host(state: state, enabled: false, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(secondary.view === context)
        XCTAssertEqual(secondary.mounts, 1)
        XCTAssertEqual(secondary.suspended, true)
        XCTAssertNil(secondary.actions)
        XCTAssertEqual(context.bounds.width, 343, accuracy: 1)
        XCTAssertGreaterThan(context.bounds.height, 0)

        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(secondary.view === context)
        XCTAssertEqual(secondary.mounts, 1)
        XCTAssertEqual(secondary.suspended, false)
        XCTAssertNotNil(secondary.actions)
    }

    func testHiddenAndSwappedFullScreenPanesKeepTheirSizesAndMounts() throws {
        let state = StateBox(), primary = Surface(), secondary = Surface()
        let controller = UIHostingController(rootView: Host(state: state, enabled: true, primary: primary, secondary: secondary))
        let window = try mount(controller, size: CGSize(width: 867, height: 553))
        defer { unmount(window) }
        settle(controller)
        let originalPrimary = try XCTUnwrap(primary.view)
        let originalSecondary = try XCTUnwrap(secondary.view)
        let contextSize = originalSecondary.bounds.size
        try XCTUnwrap(primary.actions).toggleContext()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(state.value.contextHidden)
        XCTAssertEqual(originalSecondary.bounds.size, contextSize)
        XCTAssertEqual(originalPrimary.bounds.width, 867, accuracy: 1)
        try XCTUnwrap(primary.actions).toggleContext()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)

        try XCTUnwrap(secondary.actions).toggleFullScreen()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(state.value.swapped)
        XCTAssertTrue(state.value.fullScreen)
        XCTAssertEqual(originalPrimary.bounds.width, 524, accuracy: 1)
        XCTAssertEqual(originalSecondary.bounds.width, 867, accuracy: 1)

        try XCTUnwrap(secondary.actions).toggleFullScreen()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertTrue(state.value.swapped)
        XCTAssertFalse(state.value.fullScreen)
        XCTAssertEqual(originalPrimary.bounds.width, 343, accuracy: 1)
        XCTAssertEqual(originalSecondary.bounds.width, 524, accuracy: 1)

        try XCTUnwrap(primary.actions).toggleFullScreen()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller)
        XCTAssertFalse(state.value.swapped)
        XCTAssertTrue(state.value.fullScreen)
        XCTAssertEqual(primary.mounts, 1)
        XCTAssertEqual(secondary.mounts, 1)
        XCTAssertTrue(primary.view === originalPrimary)
        XCTAssertTrue(secondary.view === originalSecondary)
    }

    @MainActor @Observable fileprivate final class SelectionBox {
        var value: DuoContextSelection
        init(_ value: DuoContextSelection) { self.value = value }
        var binding: Binding<DuoContextSelection> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    /// The Agent Center root's two structural locations: a pushed narrow
    /// workspace, and the two-column composition, which has no context.
    private struct HeldPageHost: View {
        let holder: AgentRailPageHolder
        let routeID: AgentThreadID
        let hostID: UUID
        let store: ArtifactsStore
        let lock: AppLockController
        let selection: SelectionBox
        let twoColumns: Bool
        var pushed = true

        var body: some View {
            Group {
                if twoColumns {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 300)
                        Color.clear
                    }
                } else {
                    NavigationStack {
                        Color.clear.navigationDestination(isPresented: .constant(pushed)) {
                            // The pushed container loses the window's
                            // horizontal safe area; keep both panes there.
                            DuoWorkspace(
                                state: .constant(DuoWorkspaceState()), isEnabled: true, primaryTakesInput: true,
                                mainIdealWidth: 300, pageOwner: holder.owner(for: routeID)
                            ) {
                                Color.clear
                            } secondary: {
                                DuoContextPane(hostID: hostID, extras: [], fallbackExtraID: nil,
                                               selection: selection.binding)
                            }
                        }
                    }
                }
            }
            .background {
                AgentRailPageReconciler(holder: holder, routeID: pushed ? routeID : nil,
                    threadID: routeID, selection: selection.value)
                    .equatable()
            }
            .environment(store)
            .environment(lock)
            .ignoresSafeArea()
        }
    }

    /// Inner-wide → inner-tall turns two columns on in Agent Center, which
    /// replaces the pushed thread, and inner-wide rebuilds it. The route's
    /// held page keeps its web view, document and history; a pop ends it.
    func testAHeldDockedPageSurvivesTheTwoColumnSwapAndAPopEndsIt() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/index.html"] = Data("<!doctype html><p>held page</p>".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([heldPageLiveSession(hostID: bridge.hostID)])
        let tabID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files
        )))
        await artifactEventually { store.tab(tabID)?.cache != nil }
        guard case .servedPage = store.content(for: tabID) else { return XCTFail("live HTML should be served") }
        let route = try XCTUnwrap(AgentThreadID(hostID: bridge.hostID, providerID: .claude, providerSessionID: "held"))
        let holder = AgentRailPageHolder()
        holder.pushes(route)
        let selection = SelectionBox(.tab(tabID))
        let lock = AppLockController(requiresOwnerAuthentication: { false }, locksWhenBackgrounded: { false },
                                     autoLockMinutes: { 5 })
        func host(twoColumns: Bool, pushed: Bool = true) -> HeldPageHost {
            HeldPageHost(holder: holder, routeID: route, hostID: bridge.hostID, store: store, lock: lock,
                         selection: selection, twoColumns: twoColumns, pushed: pushed)
        }
        let controller = UIHostingController(rootView: host(twoColumns: false))
        // On a portrait simulator the settled push leaves an 867 pt window's
        // workspace 695 pt, short of the 400 + 343 two panes need; this one
        // leaves room for both.
        let window = try mount(controller, size: CGSize(width: 960, height: 553))
        defer { unmount(window) }
        settle(controller, turns: 30)

        let webView = try XCTUnwrap(webViews(in: controller.view).first, "the docked page never mounted")
        // WebKit's first launch in a test process can take several seconds.
        let loaded = await poll { webView.url != nil && !webView.isLoading }
        XCTAssertTrue(loaded, "the docked page never loaded")
        let marked = try await webView.evaluateJavaScript("window.heldProbe = 'kept'; history.pushState({}, '', '#next'); 1")
        XCTAssertEqual(marked as? Int, 1)
        let navigated = await poll { webView.canGoBack }
        XCTAssertTrue(navigated)
        let owner = holder.owner(for: route)
        let model = try XCTUnwrap(owner.pageSession.session?.model)

        controller.rootView = host(twoColumns: true)
        settle(controller, turns: 30)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(webViews(in: controller.view).isEmpty, "two columns show no context")
        XCTAssertTrue(owner.pageSession.session?.model === model, "the swap ended the held page")

        controller.rootView = host(twoColumns: false)
        settle(controller, turns: 30)
        XCTAssertTrue(webViews(in: controller.view).first === webView, "the rebuilt pane made a new web view")
        XCTAssertTrue(owner.pageSession.session?.model === model)
        let kept = try await webView.evaluateJavaScript("window.heldProbe ?? 'reloaded'")
        XCTAssertEqual(kept as? String, "kept", "the document reloaded")
        XCTAssertTrue(webView.canGoBack)
        XCTAssertEqual(webView.url?.fragment, "next")

        // No pane is mounted to notice a tab closed in the artifacts section.
        controller.rootView = host(twoColumns: true)
        settle(controller, turns: 30)
        XCTAssertFalse(owner.isOwned)
        XCTAssertTrue(owner.pageSession.session?.model === model)
        store.close(tabID)
        settle(controller)
        let ended = await poll { owner.pageSession.session == nil }
        XCTAssertTrue(ended, "closing a tab with no pane must end its held page")
        XCTAssertTrue(webViews(in: controller.view).isEmpty)

        controller.rootView = host(twoColumns: false)
        settle(controller, turns: 30)
        XCTAssertNil(owner.pageSession.session, "the closed tab must not revive on a narrow rebuild")
        XCTAssertTrue(webViews(in: controller.view).isEmpty)
        let reopenedID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files
        )))
        selection.value = .tab(reopenedID)
        await artifactEventually { store.tab(reopenedID)?.cache != nil }
        settle(controller, turns: 30)
        let fresh = try XCTUnwrap(webViews(in: controller.view).first, "reopening should mount a fresh page")
        XCTAssertFalse(fresh === webView)
        let reloaded = await poll { fresh.url != nil && !fresh.isLoading }
        XCTAssertTrue(reloaded)
        XCTAssertFalse(owner.pageSession.session?.model === model)
        let probe = try await fresh.evaluateJavaScript("window.heldProbe ?? 'reloaded'")
        XCTAssertEqual(probe as? String, "reloaded", "a closed document must not retain its form or JS state")
        XCTAssertFalse(fresh.canGoBack)
        XCTAssertNil(fresh.url?.fragment)

        holder.pushes(nil)
        controller.rootView = host(twoColumns: false, pushed: false)
        settle(controller, turns: 40)
        // The pop's transition outlasts a fixed settle on a loaded machine.
        let popped = await poll { owner.pageSession.session == nil }
        XCTAssertTrue(popped, "a pop must end the held page")
        XCTAssertEqual(bridge.connectCalls, 0)
    }

    private func webViews(in view: UIView) -> [WKWebView] {
        if let webView = view as? WKWebView { return [webView] }
        return view.subviews.flatMap(webViews(in:))
    }

    func testTheHeldPageReconcilerAllowsAMissingStoreAndRechecksOnLateRelease() async throws {
        let root = artifactTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = ArtifactTestBridge()
        bridge.files["/srv/index.html"] = Data("<!doctype html><p>held page</p>".utf8)
        let store = ArtifactsStore(stateFile: ArtifactsStateFile(directory: root), bridgeProvider: { [bridge] })
        store.syncHosts([ArtifactsHostDirectoryEntry(id: bridge.hostID, label: "host")])
        store.updateSessions([heldPageLiveSession(hostID: bridge.hostID)])
        let tabID = try XCTUnwrap(store.open(ArtifactOpenRequest(
            hostID: bridge.hostID, target: .file(path: "/srv/index.html"), origin: .files
        )))
        await artifactEventually { store.tab(tabID)?.cache != nil }
        let route = try XCTUnwrap(AgentThreadID(hostID: bridge.hostID, providerID: .claude, providerSessionID: "late-release"))
        let holder = AgentRailPageHolder()
        holder.pushes(route)
        let owner = holder.owner(for: route), pane = UUID()
        owner.adopt(pane)
        owner.update(store.tab(tabID), store: store, ownerID: pane)
        let model = try XCTUnwrap(owner.pageSession.session?.model)
        owner.release(pane)
        let reconciler = AgentRailPageReconciler(holder: holder, routeID: route, threadID: route, selection: .tab(tabID))
        do {
            let controller = UIHostingController(rootView: reconciler.equatable())
            let window = try mount(controller, size: CGSize(width: 867, height: 553))
            defer { unmount(window) }
            settle(controller)
            store.close(tabID)
            settle(controller)
            XCTAssertTrue(owner.pageSession.session?.model === model, "without an injected store, do nothing")
        }

        // A stale page is still owned when reconciliation first sees it.
        let outgoing = UUID()
        owner.adopt(outgoing)
        let controller = UIHostingController(rootView: reconciler.equatable().environment(store))
        let window = try mount(controller, size: CGSize(width: 867, height: 553))
        defer { unmount(window) }
        settle(controller)
        XCTAssertTrue(owner.pageSession.session?.model === model, "a mounted pane owns its reconciliation")
        owner.release(outgoing)
        // No route, selection, tab or root-view change accompanies this release.
        settle(controller)
        let ended = await poll { owner.pageSession.session == nil }
        XCTAssertTrue(ended, "ownership observation must wake the reconciler after a late disappear")
        XCTAssertEqual(bridge.connectCalls, 0)
        holder.pushes(nil)
    }

    private func poll(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// The outer display has no room for the context: a toggle that reaches
    /// a one-pane workspace presents nothing and leaves the terminal alone.
    func testOnePaneNeverPresentsTheContextOrMovesThePrimary() throws {
        let state = StateBox(), primary = Surface(), secondary = Surface()
        let controller = UIHostingController(rootView: Host(state: state, enabled: true, primary: primary, secondary: secondary))
        let window = try mount(controller, size: CGSize(width: 382, height: 644))
        defer { unmount(window) }
        settle(controller)
        let original = try XCTUnwrap(primary.view)
        let actions = try XCTUnwrap(primary.actions)
        XCTAssertEqual(actions.arrangement, .single)
        XCTAssertFalse(actions.isContextShown)
        actions.toggleContext()
        controller.rootView = Host(state: state, enabled: true, primary: primary, secondary: secondary)
        settle(controller, turns: 30)
        XCTAssertNil(controller.presentedViewController)
        XCTAssertEqual(state.value, DuoWorkspaceState())
        XCTAssertEqual(primary.mounts, 1)
        XCTAssertTrue(primary.view === original)
        XCTAssertEqual(secondary.mounts, 1, "the retained slot stays the only copy")
    }

    private func mount<Content: View>(_ controller: UIHostingController<Content>, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.isHidden = false
        return window
    }

    private func unmount(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func settle<Content: View>(_ controller: UIHostingController<Content>, turns: Int = 15) {
        for _ in 0..<turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
    }
}

@MainActor
final class DuoKeyboardResponderTests: XCTestCase {
    private final class Field: UIView {
        override var canBecomeFirstResponder: Bool { true }
    }

    /// A key window of the inner display's size, as the app's would be.
    private func inKeyWindow(_ body: (UIWindow) throws -> Void) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        try body(window)
    }

    /// A web form's first responder is WebKit's content view, as tall as the
    /// page; only what its web view shows says which half the form is in.
    func testAResponderCountsByWhatItsClippingAncestorsShow() throws {
        try inKeyWindow { window in
            let root = try XCTUnwrap(window.rootViewController?.view)
            let page = UIScrollView(frame: CGRect(x: 0, y: 547, width: 669, height: 404))
            let content = Field(frame: CGRect(x: 0, y: -1_000, width: 669, height: 3_000))
            page.addSubview(content)
            root.addSubview(page)
            XCTAssertNil(DuoKeyboardResponder.visibleFrame(in: window), "nothing holds the keyboard")

            XCTAssertTrue(content.becomeFirstResponder())
            XCTAssertEqual(DuoKeyboardResponder.visibleFrame(in: window), CGRect(x: 0, y: 547, width: 669, height: 404))
        }
    }

    /// A sheet's or an alert's field places itself above the keyboard.
    func testAFieldInAPresentedSheetNeverTradesTheDesk() throws {
        try inKeyWindow { window in
            let root = try XCTUnwrap(window.rootViewController)
            let sheet = UIViewController()
            sheet.modalPresentationStyle = .overFullScreen
            root.present(sheet, animated: false)
            let field = Field(frame: CGRect(x: 16, y: 620, width: 320, height: 36))
            sheet.view.addSubview(field)
            for _ in 0..<20 where field.window == nil {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(field.becomeFirstResponder())
            XCTAssertNil(DuoKeyboardResponder.visibleFrame(in: window))
        }
    }
}

@MainActor
private func heldPageLiveSession(hostID: UUID) -> LiveSession {
    let host = Host(id: hostID, name: "host", address: "unused.invalid", user: "test", transport: .mosh)
    return LiveSession(session: .mosh(MoshSession(host: host)), hostName: host.name, persistedHostID: hostID,
                       hostKey: "mosh:test@unused.invalid:22", launchMode: .customCommand)
}
#endif
