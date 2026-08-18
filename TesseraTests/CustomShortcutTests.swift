import XCTest
@testable import Tessera

/// Custom shortcuts: what they send, where they apply, and how they share the
/// accessory bar's storage with built-in chips.
final class CustomShortcutTests: XCTestCase {

    // MARK: - Encoding

    /// The reason this doesn't reuse `MacroEncoder`: that language strips every
    /// space and matches bare `tab`/`esc` anywhere. Both would corrupt ordinary
    /// command text, so these two cases are the whole justification for a
    /// separate token model — and they must keep passing.
    func testLiteralTextKeepsSpacesAndWordsThatLookLikeKeyNames() {
        let shortcut = CustomShortcut(
            name: "status",
            tokens: [.text("git status"), .returnKey]
        )
        let bytes = shortcut.encoded(applicationCursor: false)
        XCTAssertEqual(String(decoding: bytes.dropLast(), as: UTF8.self), "git status")
        XCTAssertEqual(bytes.last, 0x0D, "trailing return runs the command")

        // "crontab -l" contains the word "tab" at a token boundary — the swipe
        // pad's encoder turns that into a literal TAB byte. Ours must not.
        let crontab = CustomShortcut(name: "cron", tokens: [.text("crontab -l")])
        XCTAssertEqual(
            String(decoding: crontab.encoded(applicationCursor: false), as: UTF8.self),
            "crontab -l"
        )
        XCTAssertFalse(crontab.encoded(applicationCursor: false).contains(0x09))
    }

    /// Confirms the divergence is real rather than assumed — if `MacroEncoder`
    /// is ever fixed, this test tells us the two models could converge.
    func testMacroEncoderStillManglesCommandText() {
        XCTAssertEqual(
            String(decoding: MacroEncoder.encode("git status"), as: UTF8.self),
            "gitstatus",
            "if this changes, revisit whether custom shortcuts can share the macro language"
        )
        XCTAssertTrue(MacroEncoder.encode("crontab -l").contains(0x09))
    }

    /// Special keys reuse `AccessoryChipEncoder` rather than a second encoder,
    /// so arrows follow the session's cursor mode exactly as a bar chip does.
    func testSpecialKeysEncodeThroughTheChipEncoder() {
        let shortcut = CustomShortcut(name: "up", tokens: [.key(.up)])
        XCTAssertEqual(
            shortcut.encoded(applicationCursor: false),
            AccessoryChipEncoder.encode(.up, armed: .none, applicationCursor: false)
        )
        XCTAssertEqual(
            shortcut.encoded(applicationCursor: true),
            AccessoryChipEncoder.encode(.up, armed: .none, applicationCursor: true)
        )
        XCTAssertNotEqual(
            shortcut.encoded(applicationCursor: false),
            shortcut.encoded(applicationCursor: true),
            "cursor mode must reach the bytes"
        )
    }

    /// A modifier token would trip `AccessoryChipEncoder`'s precondition; it is
    /// skipped rather than crashing on a shortcut a user could author.
    func testModifierTokensAreSkippedRatherThanCrashing() {
        let shortcut = CustomShortcut(name: "odd", tokens: [.key(.ctrl), .text("x")])
        XCTAssertEqual(String(decoding: shortcut.encoded(applicationCursor: false), as: UTF8.self), "x")
    }

    func testEndsWithReturnDetectsAnImmediateRun() {
        XCTAssertTrue(CustomShortcut(name: "a", tokens: [.text("ls"), .returnKey]).tokens.endsWithReturn)
        XCTAssertFalse(CustomShortcut(name: "b", tokens: [.text("ls")]).tokens.endsWithReturn)
    }

    // MARK: - Bar storage compatibility

    /// `accessoryBarKeys` stays `[String]`, and a build that predates custom
    /// chips decodes it through `compactMap(AccessoryChip.init(rawValue:))`.
    /// A custom entry must therefore be *dropped* by that path, not crash it —
    /// this is what makes the storage forward and backward compatible with no
    /// migration.
    func testCustomChipIDsAreInvisibleToTheBuiltInDecoder() {
        let shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        let raw = shortcut.chipRawID
        XCTAssertTrue(raw.hasPrefix("custom:"))
        XCTAssertNil(AccessoryChip(rawValue: raw))

        let mixed = ["esc", raw, "tab"]
        XCTAssertEqual(AccessoryChip.from(rawIDs: mixed), [.esc, .tab])
    }

    func testChipRawIDRoundTrips() {
        let shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        XCTAssertEqual(CustomShortcut.id(fromChipRawID: shortcut.chipRawID), shortcut.id)
        XCTAssertNil(CustomShortcut.id(fromChipRawID: "esc"))
        XCTAssertNil(CustomShortcut.id(fromChipRawID: "custom:not-a-uuid"))
    }

    func testBarItemResolutionPrefersBuiltInsThenCustoms() {
        let shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        let lookup: (String) -> CustomShortcut? = { $0 == shortcut.chipRawID ? shortcut : nil }

        XCTAssertEqual(AccessoryBarItem.resolve("esc", customLookup: lookup), .chip(.esc))
        XCTAssertEqual(
            AccessoryBarItem.resolve(shortcut.chipRawID, customLookup: lookup),
            .custom(shortcut)
        )
        XCTAssertNil(AccessoryBarItem.resolve("nonsense", customLookup: lookup))
    }

    /// An icon chip has no readable text, so the shortcut's name is what
    /// VoiceOver announces. Losing this makes custom chips unusable blind.
    func testIconChipsAnnounceTheShortcutName() {
        var shortcut = CustomShortcut(name: "tail the deploy log", tokens: [.text("x")])
        shortcut.chipLabel = .symbol("doc.text")
        XCTAssertEqual(AccessoryBarItem.custom(shortcut).accessibilityLabel, "tail the deploy log")
        if case .symbol(let name) = AccessoryBarItem.custom(shortcut).label(.glyph) {
            XCTAssertEqual(name, "doc.text")
        } else {
            XCTFail("symbol label expected")
        }
    }

    func testTextChipFallsBackToTheNameWhenUnset() {
        let shortcut = CustomShortcut(name: "deployment", tokens: [.text("x")])
        if case .text(let label) = AccessoryBarItem.custom(shortcut).label(.glyph) {
            XCTAssertEqual(label, "deploy", "six characters is what fits a 44pt chip")
        } else {
            XCTFail("text label expected")
        }
    }

    // MARK: - Scope

    func testEverywhereAlwaysApplies() {
        XCTAssertTrue(ShortcutScopeEvaluator.applies(.everywhere, hostID: nil, processName: nil))
    }

    func testHostScopeMatchesOnlyItsHosts() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(ShortcutScopeEvaluator.applies(.hosts([a, b]), hostID: a, processName: nil))
        XCTAssertFalse(ShortcutScopeEvaluator.applies(.hosts([a]), hostID: b, processName: nil))
        XCTAssertFalse(ShortcutScopeEvaluator.applies(.hosts([a]), hostID: nil, processName: nil))
    }

    /// The failure direction is the point: an unknown foreground process must
    /// not fire a program-scoped shortcut. Otherwise an "approve" shortcut
    /// sends `1` into whatever shell happens to be focused.
    func testProgramScopeFailsClosedWhenTheProcessIsUnknown() {
        XCTAssertFalse(ShortcutScopeEvaluator.applies(.process("claude"), hostID: UUID(), processName: nil))
        XCTAssertFalse(ShortcutScopeEvaluator.applies(.process("claude"), hostID: UUID(), processName: ""))
    }

    /// Literal and `regex:` forms come from `SwipePadActiveProfileResolver`
    /// itself, not a second implementation.
    func testProgramScopeUsesTheSwipePadMatcher() {
        XCTAssertTrue(ShortcutScopeEvaluator.applies(.process("claude"), hostID: nil, processName: "claude"))
        XCTAssertTrue(ShortcutScopeEvaluator.applies(.process("CLAUDE"), hostID: nil, processName: "claude"))
        XCTAssertFalse(ShortcutScopeEvaluator.applies(.process("claude"), hostID: nil, processName: "codex"))
        XCTAssertTrue(
            ShortcutScopeEvaluator.applies(
                .process("regex:^\\d+\\.\\d+\\.\\d+$"),
                hostID: nil,
                processName: "1.2.3"
            ),
            "Claude Code renames itself to its semver at runtime"
        )
    }

    // MARK: - Scope enforcement on the accessory bar

    /// A scope is a safety rule, so it has to hold on *every* trigger. The chord
    /// path guarded from the start; the bar chip sent its bytes unconditionally,
    /// which meant a shortcut scoped to host `staging` and sending `terraform
    /// apply -auto-approve␍` ran on prod when tapped there. The chip renders in
    /// every session — `AccessoryBarItem.resolve` looks a chip up by raw ID
    /// alone — so the tap is the only place the scope can be enforced.
    func testOutOfScopeCustomChipCannotFire() {
        let staging = UUID(), prod = UUID()
        let shortcut = CustomShortcut(
            name: "apply",
            chipLabel: .symbol("bolt"),
            tokens: [.text("terraform apply -auto-approve"), .returnKey],
            scope: .hosts([staging])
        )
        let item = AccessoryBarItem.custom(shortcut)

        XCTAssertTrue(
            SessionAccessoryBar.canFire(item) {
                ShortcutScopeEvaluator.applies($0.scope, hostID: staging, processName: nil)
            }
        )
        XCTAssertFalse(
            SessionAccessoryBar.canFire(item) {
                ShortcutScopeEvaluator.applies($0.scope, hostID: prod, processName: nil)
            },
            "a host-scoped chip must not fire on another host"
        )
    }

    /// Program-scoped chips inherit the evaluator's fail-closed direction: an
    /// unknown foreground process (plain passthrough has no cheap process
    /// source) must not send a stray `1` into a shell.
    func testProgramScopedChipFailsClosedWithNoProcessSignal() {
        let shortcut = CustomShortcut(
            name: "approve",
            chipLabel: .text("1"),
            tokens: [.text("1"), .returnKey],
            scope: .process("claude")
        )
        let item = AccessoryBarItem.custom(shortcut)

        XCTAssertFalse(
            SessionAccessoryBar.canFire(item) {
                ShortcutScopeEvaluator.applies($0.scope, hostID: UUID(), processName: nil)
            }
        )
        XCTAssertTrue(
            SessionAccessoryBar.canFire(item) {
                ShortcutScopeEvaluator.applies($0.scope, hostID: UUID(), processName: "claude")
            }
        )
    }

    /// Built-in chips send a key, not a command, and have no scope to consult —
    /// the guard must never withhold one.
    func testBuiltInChipsAreNeverWithheld() {
        for chip in AccessoryChip.allCases {
            XCTAssertTrue(
                SessionAccessoryBar.canFire(.chip(chip)) { _ in false },
                "\(chip.rawValue) must stay unconditional"
            )
        }
    }

    // MARK: - Persistence

    func testCustomShortcutsRoundTripThroughJSON() throws {
        var shortcut = CustomShortcut(
            name: "tail the deploy log",
            binding: KeyBinding([.command, .option], .character("d")),
            tokens: [.text("tail -f /var/log/deploy.log"), .returnKey],
            scope: .process("regex:^claude")
        )
        shortcut.chipLabel = .symbol("doc.text")

        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(CustomShortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut)
    }

    @MainActor
    func testStoreUpsertAndDelete() {
        let defaults = makeScratchDefaults("custom-shortcut-test")
        let store = ShortcutStore(defaults: defaults)

        var shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        store.upsert(shortcut)
        XCTAssertEqual(store.customShortcuts.count, 1)

        shortcut.name = "deploy prod"
        store.upsert(shortcut)
        XCTAssertEqual(store.customShortcuts.count, 1, "upsert by id, not append")
        XCTAssertEqual(store.customShortcuts.first?.name, "deploy prod")

        XCTAssertEqual(ShortcutStore(defaults: defaults).customShortcuts.first?.name, "deploy prod")

        store.delete(shortcut)
        XCTAssertTrue(store.customShortcuts.isEmpty)
        XCTAssertTrue(ShortcutStore(defaults: defaults).customShortcuts.isEmpty)
    }

    // MARK: - Reachability
    //
    // The shipped defect: saving a shortcut with "accessory bar chip" on stored
    // the label and nothing else. With no chord, nothing could fire it — and
    // the palette offered no way to place it by hand, so it was unreachable
    // from every direction while the editor previewed it as ON THE BAR.

    func testAChipLabelAloneIsNotATrigger() {
        var shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        shortcut.chipLabel = .text("dply")

        XCTAssertTrue(shortcut.hasTrigger, "the user did ask for a chip")
        XCTAssertFalse(
            shortcut.isReachable(barKeys: ["esc", "ctrl"]),
            "a chip that was never placed on the bar cannot be tapped"
        )
        XCTAssertTrue(shortcut.isReachable(barKeys: ["esc", shortcut.chipRawID]))
    }

    func testAChordOnlyShortcutIsReachableWithNoChip() {
        var shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        shortcut.binding = KeyBinding([.command, .control], .character("d"))
        XCTAssertTrue(shortcut.isReachable(barKeys: []))
    }

    /// Saving with the chip toggle on must place it, or the toggle is a promise
    /// the app doesn't keep.
    func testSavingWithTheChipToggleOnPlacesItOnTheBar() {
        let raw = CustomShortcut(name: "deploy", tokens: [.text("x")]).chipRawID
        let placed = AccessoryBarPlacement.apply(wantsChip: true, chipRawID: raw, to: ["esc", "ctrl"])
        XCTAssertEqual(placed, ["esc", "ctrl", raw], "appended, so existing chips keep their positions")

        // Saving again must not stack duplicates.
        XCTAssertEqual(AccessoryBarPlacement.apply(wantsChip: true, chipRawID: raw, to: placed), placed)
    }

    func testTurningTheChipToggleOffTakesItBackOffTheBar() {
        let raw = CustomShortcut(name: "deploy", tokens: [.text("x")]).chipRawID
        XCTAssertEqual(
            AccessoryBarPlacement.apply(wantsChip: false, chipRawID: raw, to: ["esc", raw, "ctrl"]),
            ["esc", "ctrl"]
        )
    }

    func testDeletingAShortcutTakesItsChipWithIt() {
        let raw = CustomShortcut(name: "deploy", tokens: [.text("x")]).chipRawID
        XCTAssertEqual(
            AccessoryBarPlacement.removing(chipRawID: raw, from: ["esc", raw]),
            ["esc"]
        )
        // A stale ID left behind would be invisible rather than broken — this is
        // about not accumulating dead entries in the stored order.
        XCTAssertEqual(AccessoryChip.from(rawIDs: ["esc", raw]), [.esc])
    }

    @MainActor
    func testChipLookupFindsTheOwningShortcut() {
        let defaults = makeScratchDefaults("custom-shortcut-test")
        let store = ShortcutStore(defaults: defaults)
        let shortcut = CustomShortcut(name: "deploy", tokens: [.text("x")])
        store.upsert(shortcut)

        XCTAssertEqual(store.customShortcut(withChipRawID: shortcut.chipRawID), shortcut)
        XCTAssertNil(store.customShortcut(withChipRawID: "esc"))
    }
}

/// The ⌘ accessory chip. Unlike ⌃/⌥/⇧ it has no wire encoding — no terminal
/// protocol carries Command — so it arms Tessera's own shortcuts instead.
/// These tests pin that separation, because a ⌘ that leaked into the byte path
/// would corrupt input rather than fail visibly.
final class CommandChipTests: XCTestCase {

    /// ⌘ is opt-in, not a default chip. Because it arms app shortcuts instead
    /// of transforming bytes, a user who taps it expecting ⌃/⌥ behavior gets
    /// something that looks identical and acts nothing alike — so it ships only
    /// for users who go and add it.
    func testCommandIsAvailableButNotOnEitherDefaultBar() {
        XCTAssertFalse(AccessoryChip.defaultBarOrder(for: .phone).contains(.cmd))
        XCTAssertFalse(AccessoryChip.defaultBarOrder(for: .pad).contains(.cmd))
        // Still addable from the palette, and still round-trips through the
        // stored raw IDs — removing it from the defaults must not strip it from
        // a bar a user already customized.
        XCTAssertTrue(AccessoryChip.allCases.contains(.cmd))
        XCTAssertEqual(AccessoryChip.from(rawIDs: ["esc", AccessoryChip.cmd.rawValue]), [.esc, .cmd])
    }

    func testCommandIsAModifierChip() {
        XCTAssertTrue(AccessoryChip.cmd.isModifier)
        XCTAssertEqual(AccessoryChip.cmd.displayLabel(.glyph), "⌘")
        XCTAssertEqual(AccessoryChip.cmd.displayLabel(.words), "cmd")
        XCTAssertEqual(AccessoryChip.cmd.accessibilityLabel, "Command")
    }

    /// `isAny` gates the byte transforms in `SoftwareModifierEncoder`. Command
    /// must stay out of it: there is no sequence to emit, so including it would
    /// consume a one-shot modifier and send the key unchanged.
    func testCommandIsExcludedFromTheWireModifierSet() {
        var armed = ArmedModifiers.none
        armed.cmd = true
        XCTAssertFalse(armed.isAny, "⌘ must not reach the byte encoder")
        XCTAssertTrue(armed.isAnyArmed, "…but the bar still shows it armed")

        // With only ⌘ armed, the software-keyboard encoder declines the payload
        // entirely rather than transforming it.
        XCTAssertNil(SoftwareModifierEncoder.encodeNextKey([0x6B], armed: armed))
    }

    @MainActor
    func testTappingCommandTogglesItsOwnFlag() {
        let state = ModifierState()
        state.tap(.cmd)
        XCTAssertTrue(state.armed.cmd)
        XCTAssertFalse(state.armed.ctrl)
        state.tap(.cmd)
        XCTAssertFalse(state.armed.cmd)
    }

    /// The chord an on-screen ⌘ assembles must be identical to what a hardware
    /// press produces, or the same binding would need two spellings.
    func testAssembledChordMatchesARecordedOne() {
        var armed = ArmedModifiers.none
        armed.cmd = true
        armed.shift = true
        let assembled = AppShortcutDispatcher.chord(armed: armed, key: .character("e"))
        XCTAssertEqual(assembled, KeyBinding([.command, .shift], .character("e")))
        XCTAssertEqual(assembled, ShortcutAction.toggleFilesPanel.defaultBinding)
    }

    /// Chips that stand for a single key can take part in a ⌘ chord; modifier
    /// and control-shortcut chips cannot, and must not be silently mapped to
    /// something else.
    func testOnlySingleKeyChipsMapToABindingKey() {
        XCTAssertEqual(BindingKey.from(chip: .tab), .tab)
        XCTAssertEqual(BindingKey.from(chip: .left), .left)
        XCTAssertEqual(BindingKey.from(chip: .pipe), .character("|"))
        XCTAssertEqual(BindingKey.from(chip: .f5), .function(5))
        for chip in [AccessoryChip.ctrl, .alt, .shift, .cmd, .ctrlC, .ctrlJ] {
            XCTAssertNil(BindingKey.from(chip: chip), "\(chip.rawValue) is not a single key")
        }
    }

    /// Every chip that isn't a modifier still encodes to bytes — adding ⌘ must
    /// not have knocked a chip out of the wire path.
    func testEveryNonModifierChipStillEncodes() {
        for chip in AccessoryChip.allCases where !chip.isModifier {
            XCTAssertFalse(
                AccessoryChipEncoder.encode(chip, armed: .none, applicationCursor: false).isEmpty,
                "\(chip.rawValue) encodes to nothing"
            )
        }
    }
}

/// The chord → action resolution an on-screen ⌘ relies on. Kept separate from
/// dispatch itself, which needs a live responder chain.
final class AppShortcutResolutionTests: XCTestCase {

    /// The shipped set has no shared chord at all — worth pinning, because the
    /// two actions that look like they might collide (⌘↩ connect, ⇧⌘↩ zoom
    /// pane) differ only by ⇧.
    func testShippedDefaultsShareNoChord() {
        var seen: [KeyBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases where !action.isDigitBlock {
            let binding = action.defaultBinding
            XCTAssertNil(
                seen[binding],
                "\(action.rawValue) collides with \(seen[binding]?.rawValue ?? "") on \(binding.rendered(.glyph))"
            )
            seen[binding] = action
        }
        XCTAssertNotEqual(
            ShortcutAction.connect.defaultBinding,
            ShortcutAction.paneZoom.defaultBinding
        )
    }

    /// A *user* can still create a collision by remapping onto a chord that
    /// belongs to an action the terminal doesn't own (new host, connect —
    /// those live on SwiftUI hidden buttons). Resolution must then pick the
    /// dispatchable one, deterministically. A dictionary-order lookup would
    /// let `connect` mask it depending on hashing.
    @MainActor
    func testUserCollisionResolvesToTheDispatchableAction() {
        let defaults = makeScratchDefaults("shortcut-collision")
        let store = ShortcutStore(defaults: defaults)

        let connectChord = ShortcutAction.connect.defaultBinding
        store.setBinding(connectChord, for: .findOpen)

        let resolved = ShortcutAction.allCases.first {
            store.binding(for: $0) == connectChord
                && TesseraTerminalContainer.shortcutSelector(for: $0) != nil
        }
        XCTAssertEqual(resolved, .findOpen)
        XCTAssertNil(TesseraTerminalContainer.shortcutSelector(for: .connect))
        XCTAssertNil(TesseraTerminalContainer.shortcutSelector(for: .newHost))
    }

    /// Every other terminal action must be reachable from an on-screen chord,
    /// or a ⌘ chip is a decoration for that row of the settings list.
    func testEveryTerminalActionHasASelector() {
        for action in ShortcutAction.terminalActions {
            XCTAssertNotNil(
                TesseraTerminalContainer.shortcutSelector(for: action),
                "\(action.rawValue) cannot be dispatched from an on-screen ⌘ chord"
            )
        }
    }
}
