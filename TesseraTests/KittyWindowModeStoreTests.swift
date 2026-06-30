import XCTest
import SwiftTerm
import TmuxControl
@testable import Tessera

/// Regression tests for the kitty keyboard-flag leak across tmux -CC
/// windows: an app pushing kitty flags in one window must not cause
/// SwiftTerm to keep CSI-u-encoding keystrokes after a display swap to
/// a window whose pane never requested them (shift+= rendered as
/// `1:43;2u` in the neighbouring shell).
@MainActor
final class KittyWindowModeStoreTests: XCTestCase {
    private final class TerminalDelegateStub: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let windowA = WindowId(1)
    private let windowB = WindowId(2)

    // Strong reference: Terminal holds its delegate weakly.
    private var delegateStub = TerminalDelegateStub()

    private func makeTerminal() -> Terminal {
        Terminal(delegate: delegateStub)
    }

    private func feed(_ terminal: Terminal, _ text: String) {
        terminal.feed(byteArray: Array(text.utf8))
    }

    /// ESC [ ? 1049 h — enter alternate screen, where real TUIs push
    /// kitty flags; ESC [ > 1 u — kitty push with the disambiguate flag.
    private func enterAltScreenAndPushKittyFlags(_ terminal: Terminal) {
        feed(terminal, "\u{1B}[?1049h\u{1B}[>1u")
        XCTAssertFalse(terminal.keyboardEnhancementFlags.isEmpty)
    }

    func test_swapAwayFromKittyWindow_clearsFlags() {
        let terminal = makeTerminal()
        enterAltScreenAndPushKittyFlags(terminal)

        let store = KittyWindowModeStore()
        store.displayWillSwap(
            from: windowA, to: windowB, paneInAltScreen: false, terminal: terminal
        )

        XCTAssertTrue(terminal.keyboardEnhancementFlags.isEmpty)
    }

    func test_swapBackToKittyWindow_restoresFlags() {
        let terminal = makeTerminal()
        enterAltScreenAndPushKittyFlags(terminal)
        let pushed = terminal.keyboardEnhancementFlags

        let store = KittyWindowModeStore()
        store.displayWillSwap(
            from: windowA, to: windowB, paneInAltScreen: false, terminal: terminal
        )
        store.displayWillSwap(
            from: windowB, to: windowA, paneInAltScreen: true, terminal: terminal
        )

        XCTAssertEqual(terminal.keyboardEnhancementFlags, pushed)
    }

    /// The pop emitted by an app exiting while its window is off-screen
    /// never reaches SwiftTerm (%output of non-active windows is
    /// dropped). tmux reporting the pane out of the alternate screen is
    /// the staleness signal: the saved alt-screen flags must die.
    func test_swapBackAfterAppExitedOffScreen_discardsStaleAltFlags() {
        let terminal = makeTerminal()
        enterAltScreenAndPushKittyFlags(terminal)

        let store = KittyWindowModeStore()
        store.displayWillSwap(
            from: windowA, to: windowB, paneInAltScreen: false, terminal: terminal
        )
        store.displayWillSwap(
            from: windowB, to: windowA, paneInAltScreen: false, terminal: terminal
        )

        XCTAssertTrue(terminal.keyboardEnhancementFlags.isEmpty)
    }

    /// First swap after attach (`from == nil`) starts from a clean
    /// slate even if the passthrough prologue left kitty state behind.
    func test_firstSwap_resetsLeftoverState() {
        let terminal = makeTerminal()
        feed(terminal, "\u{1B}[>1u")
        XCTAssertFalse(terminal.keyboardEnhancementFlags.isEmpty)

        let store = KittyWindowModeStore()
        store.displayWillSwap(
            from: nil, to: windowA, paneInAltScreen: false, terminal: terminal
        )

        XCTAssertTrue(terminal.keyboardEnhancementFlags.isEmpty)
    }

    /// Same-window refreshes (re-attach, resize) round-trip the state
    /// through the store without changing it.
    func test_sameWindowRefresh_keepsFlags() {
        let terminal = makeTerminal()
        enterAltScreenAndPushKittyFlags(terminal)
        let pushed = terminal.keyboardEnhancementFlags

        let store = KittyWindowModeStore()
        store.displayWillSwap(
            from: windowA, to: windowA, paneInAltScreen: true, terminal: terminal
        )

        XCTAssertEqual(terminal.keyboardEnhancementFlags, pushed)
    }
}
