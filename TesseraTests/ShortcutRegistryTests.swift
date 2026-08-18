import XCTest
import UIKit
@testable import Tessera

/// `TesseraTerminalContainer.keyCommands` used to be a hand-written list. It is
/// now generated from `ShortcutAction` + `ShortcutStore`, which is what makes
/// remapping possible — and which is exactly the kind of refactor that can
/// quietly change behavior for users who never open the editor.
///
/// This suite pins the shipped defaults against the literal list they replaced,
/// including `wantsPriorityOverSystemBehavior`, whose loss would only show up
/// as "the shortcut stops firing while the terminal has focus".
final class ShortcutRegistryTests: XCTestCase {

    /// The pre-refactor list, transcribed from the commit that removed it.
    /// (input, command-modifier flags, wantsPriority)
    private static let shipped: [ShortcutAction: (String, UIKeyModifierFlags, Bool)] = [
        .findOpen:            ("f", [.command], false),
        .findNext:            ("g", [.command], false),
        .findPrevious:        ("g", [.command, .shift], false),
        .quickSwitchPalette:  ("k", [.command], false),
        .previousSession:     ("k", [.command, .shift], true),
        .nextSession:         ("j", [.command, .shift], true),
        .openSettings:        (",", [.command], false),
        .refreshTerminal:     ("r", [.command], true),
        .toggleAgentCenter:   ("a", [.command, .shift], true),
        .toggleFilesPanel:    ("e", [.command, .shift], true),
        .tmuxNewWindow:       ("t", [.command], false),
        .tmuxCloseWindow:     ("w", [.command, .shift], false),
        .tmuxPreviousWindow:  ("[", [.command, .shift], false),
        .tmuxNextWindow:      ("]", [.command, .shift], false),
        .paneSplitSideBySide: ("d", [.command], true),
        .paneSplitStacked:    ("d", [.command, .shift], true),
        .panePrevious:        ("[", [.command], true),
        .paneNext:            ("]", [.command], true),
        .paneZoom:            ("\r", [.command, .shift], true),
        .tmuxSelectWindow:    ("1", [.command], false),
        // Not on the terminal container — registered by ContentView / the host
        // editor, but their chords must survive the move too.
        .newHost:             ("n", [.command], false),
        .connect:             ("\r", [.command], false),
    ]

    func testEveryActionHasAShippedExpectation() {
        XCTAssertEqual(
            Set(Self.shipped.keys),
            Set(ShortcutAction.allCases),
            "a new bindable action needs a line in this table, or the refactor guard has a hole"
        )
    }

    func testDefaultBindingsMatchTheListTheyReplaced() {
        for (action, expected) in Self.shipped {
            let binding = action.defaultBinding
            XCTAssertEqual(
                binding.key.keyCommandInput, expected.0,
                "\(action.rawValue) input changed"
            )
            XCTAssertEqual(
                binding.modifierFlags, expected.1,
                "\(action.rawValue) modifiers changed"
            )
            XCTAssertEqual(
                action.wantsPriorityOverSystemBehavior, expected.2,
                "\(action.rawValue) lost or gained wantsPriorityOverSystemBehavior"
            )
        }
    }

    /// Two actions sharing a chord means one of them silently never fires. The
    /// shipped set must be conflict-free; ⌘1–9 is excluded because it is nine
    /// commands generated from one binding.
    func testShippedDefaultsAreConflictFree() {
        var seen: [KeyBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases where !action.isDigitBlock {
            let binding = action.defaultBinding
            if let other = seen[binding] {
                // ⌘↩ is deliberately shared: connect lives on the host editor,
                // zoom pane on a mounted grid — they can't be on screen at once.
                let allowed: Set<ShortcutAction> = [.connect, .paneZoom]
                XCTAssertTrue(
                    allowed.contains(action) && allowed.contains(other),
                    "\(action.rawValue) collides with \(other.rawValue) on \(binding.rendered(.glyph))"
                )
                continue
            }
            seen[binding] = action
        }
    }

    // MARK: - Hidden-button chords (SwiftUI `.keyboardShortcut`)

    /// Five actions do not ride `UIKeyCommand`: ⌘N, ⌘K, ⌘⇧A and ⌘, live on
    /// hidden buttons in `ContentView` (they must work when no terminal holds
    /// first responder) and ⌘↩ lives on the host editor's connect button. Two of
    /// them — `newHost` and `connect` — have *no* selector on the terminal
    /// container, so those buttons are the whole registration.
    ///
    /// They were left written out as literals after the keymap landed, which
    /// made their editor rows record-and-persist-but-do-nothing. The bridge
    /// below is what routes them through the store; if it stops answering for
    /// one of these chords, that row silently goes inert again.
    private static let hiddenButtonActions: [ShortcutAction] = [
        .newHost, .quickSwitchPalette, .toggleAgentCenter, .openSettings, .connect,
    ]

    func testHiddenButtonChordsBridgeToSwiftUIKeyEquivalents() {
        // The literals these replaced, transcribed from the call sites.
        let expected: [ShortcutAction: (Character, Set<KeyToken>)] = [
            .newHost:            ("n", [.command]),
            .quickSwitchPalette: ("k", [.command]),
            .toggleAgentCenter:  ("a", [.command, .shift]),
            .openSettings:       (",", [.command]),
            .connect:            ("\r", [.command]),
        ]
        XCTAssertEqual(Set(expected.keys), Set(Self.hiddenButtonActions))

        for (action, want) in expected {
            let bridge = action.defaultBinding.keyEquivalent
            XCTAssertNotNil(
                bridge,
                "\(action.rawValue) has no KeyEquivalent, so its hidden button would attach no chord"
            )
            XCTAssertEqual(bridge?.character, want.0, "\(action.rawValue) character")
            XCTAssertEqual(bridge?.modifiers, want.1, "\(action.rawValue) modifiers")
        }
    }

    /// A rebind has to reach the hidden buttons, and an unbind has to *release*
    /// the shipped chord rather than leaving it in effect alongside the new one.
    @MainActor
    func testHiddenButtonChordsFollowTheStore() {
        let defaults = makeScratchDefaults("shortcut-store-test")
        let store = ShortcutStore(defaults: defaults)

        for action in Self.hiddenButtonActions {
            XCTAssertEqual(
                StoredShortcut.binding(action, in: store),
                action.defaultBinding,
                "\(action.rawValue) must start on its shipped chord"
            )

            store.setBinding(.cmd("y"), for: action)
            XCTAssertEqual(
                StoredShortcut.binding(action, in: store)?.keyEquivalent?.character,
                "y",
                "\(action.rawValue) rebind never reached the hidden button"
            )

            store.setBinding(nil, for: action)
            XCTAssertNil(
                StoredShortcut.binding(action, in: store),
                "\(action.rawValue) unbind must release the chord, not keep the old one"
            )
        }
    }

    /// No store injected (previews, harnesses, tests) keeps the shipped chords,
    /// matching `TesseraTerminalContainer.resolvedBinding`.
    @MainActor
    func testHiddenButtonChordsFallBackToDefaultsWithoutAStore() {
        for action in Self.hiddenButtonActions {
            XCTAssertEqual(
                StoredShortcut.binding(action, in: nil),
                action.defaultBinding
            )
        }
    }

    // MARK: - Store semantics

    @MainActor
    func testOverridesRoundTripAndRestoreCleanly() {
        let defaults = makeScratchDefaults("shortcut-store-test")
        let store = ShortcutStore(defaults: defaults)

        XCTAssertEqual(store.binding(for: .toggleFilesPanel), .cmdShift("e"))
        XCTAssertFalse(store.isCustomized(.toggleFilesPanel))

        store.setBinding(KeyBinding([.command, .option], .character("f")), for: .toggleFilesPanel)
        XCTAssertTrue(store.isCustomized(.toggleFilesPanel))

        // Survives a reload from the same defaults.
        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertEqual(
            reloaded.binding(for: .toggleFilesPanel),
            KeyBinding([.command, .option], .character("f"))
        )

        reloaded.resetToDefault(.toggleFilesPanel)
        XCTAssertEqual(reloaded.binding(for: .toggleFilesPanel), .cmdShift("e"))
        XCTAssertFalse(reloaded.isCustomized(.toggleFilesPanel))
    }

    /// Setting a binding back to the shipped chord must *stop storing it*, not
    /// store it as an override — otherwise a future default change would never
    /// reach a user who once round-tripped that row.
    @MainActor
    func testReassigningTheDefaultChordStopsStoringAnOverride() {
        let defaults = makeScratchDefaults("shortcut-store-test")
        let store = ShortcutStore(defaults: defaults)

        store.setBinding(.cmd("y"), for: .tmuxNewWindow)
        XCTAssertTrue(store.isCustomized(.tmuxNewWindow))

        store.setBinding(.cmd("t"), for: .tmuxNewWindow)
        XCTAssertFalse(store.isCustomized(.tmuxNewWindow))
        XCTAssertEqual(store.changedCount, 0)
    }

    /// "Deliberately unbound" has to survive a reload distinctly from "never
    /// touched", or a cleared shortcut silently comes back on next launch.
    @MainActor
    func testAnExplicitUnbindSurvivesReload() {
        let defaults = makeScratchDefaults("shortcut-store-test")
        let store = ShortcutStore(defaults: defaults)

        store.setBinding(nil, for: .refreshTerminal)
        XCTAssertNil(store.binding(for: .refreshTerminal))

        let reloaded = ShortcutStore(defaults: defaults)
        XCTAssertNil(reloaded.binding(for: .refreshTerminal))
        XCTAssertTrue(reloaded.isCustomized(.refreshTerminal))
    }
}

extension XCTestCase {
    /// A throwaway defaults suite that deletes itself when the test ends.
    ///
    /// Unit tests are hosted inside Tessera, so every `UserDefaults(suiteName:)`
    /// writes a real plist into the app container's Preferences directory. A
    /// unique suite name per test keeps runs isolated but leaves the file
    /// behind — on a long-lived simulator they pile up in the thousands.
    func makeScratchDefaults(_ label: String) -> UserDefaults {
        let suite = "\(label)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
