import Foundation
import XCTest
@testable import TesseraInputCore

/// The catalog is the single answer to "what keys exist, what are they called
/// in storage, and what do they send". Golden bytes for every entry, because
/// the whole point of one entry point keyed by ID is that neither platform can
/// quietly grow a different table.
final class AccessoryKeyCatalogTests: XCTestCase {

    // MARK: - Golden bytes, every entry

    /// Bare bytes for each catalog entry. Modifiers are absent from the table
    /// on purpose: they arm state and encode to nil.
    private static let goldenBareBytes: [AccessoryKey: [UInt8]] = [
        .esc: [0x1B],
        .enter: [0x0D],
        .ctrlC: [0x03],
        .ctrlJ: [0x0A],
        .ctrlL: [0x0C],
        .tab: [0x09],
        .left: [0x1B, 0x5B, 0x44],
        .down: [0x1B, 0x5B, 0x42],
        .up: [0x1B, 0x5B, 0x41],
        .right: [0x1B, 0x5B, 0x43],
        .home: [0x1B, 0x5B, 0x48],
        .end: [0x1B, 0x5B, 0x46],
        .pgup: [0x1B, 0x5B, 0x35, 0x7E],
        .pgdn: [0x1B, 0x5B, 0x36, 0x7E],
        .f1: [0x1B, 0x4F, 0x50],
        .f2: [0x1B, 0x4F, 0x51],
        .f3: [0x1B, 0x4F, 0x52],
        .f4: [0x1B, 0x4F, 0x53],
        .f5: [0x1B, 0x5B, 0x31, 0x35, 0x7E],
        .f6: [0x1B, 0x5B, 0x31, 0x37, 0x7E],
        .f7: [0x1B, 0x5B, 0x31, 0x38, 0x7E],
        .f8: [0x1B, 0x5B, 0x31, 0x39, 0x7E],
        .f9: [0x1B, 0x5B, 0x32, 0x30, 0x7E],
        .f10: [0x1B, 0x5B, 0x32, 0x31, 0x7E],
        .f11: [0x1B, 0x5B, 0x32, 0x33, 0x7E],
        .f12: [0x1B, 0x5B, 0x32, 0x34, 0x7E],
        .pipe: [0x7C],
        .tilde: [0x7E],
        .slash: [0x2F],
        .backslash: [0x5C],
        .dollar: [0x24],
        .lbrace: [0x7B],
        .rbrace: [0x7D],
        .lbracket: [0x5B],
        .rbracket: [0x5D],
        .lt: [0x3C],
        .gt: [0x3E],
    ]

    /// Entries whose bare form changes under DECCKM. Everything else must be
    /// byte-identical in both cursor modes.
    private static let goldenApplicationCursorBytes: [AccessoryKey: [UInt8]] = [
        .left: [0x1B, 0x4F, 0x44],
        .down: [0x1B, 0x4F, 0x42],
        .up: [0x1B, 0x4F, 0x41],
        .right: [0x1B, 0x4F, 0x43],
        .home: [0x1B, 0x4F, 0x48],
        .end: [0x1B, 0x4F, 0x46],
    ]

    func test_everyCatalogEntryEncodesToItsGoldenBytesByID() {
        for key in AccessoryKey.allCases {
            let expected = Self.goldenBareBytes[key]
            XCTAssertEqual(
                AccessoryKeyCatalog.encode(id: key.rawValue),
                expected,
                "\(key.rawValue) bare"
            )
            XCTAssertEqual(
                AccessoryKeyCatalog.encode(key),
                expected,
                "\(key.rawValue) bare, by case"
            )

            XCTAssertEqual(
                AccessoryKeyCatalog.encode(id: key.rawValue, applicationCursorMode: true),
                Self.goldenApplicationCursorBytes[key] ?? expected,
                "\(key.rawValue) under application-cursor mode"
            )
        }
    }

    /// The golden table must stay exhaustive: every non-modifier key has an
    /// entry, and every modifier key has none.
    func test_goldenTableCoversExactlyTheNonModifierKeys() {
        let expectedIDs = Set(AccessoryKey.allCases.filter { !$0.isModifier })
        XCTAssertEqual(Set(Self.goldenBareBytes.keys), expectedIDs)
        XCTAssertEqual(
            Set(AccessoryKey.allCases.filter(\.isModifier)),
            [.ctrl, .alt, .shift, .cmd]
        )
    }

    /// Modifier chips arm `ModifierArming` instead of producing output, so the
    /// catalog answers nil rather than an empty byte array — an empty array
    /// would read as "sends nothing", which is a different statement.
    func test_modifierKeysEncodeToNil() {
        for key in AccessoryKey.allCases where key.isModifier {
            XCTAssertNil(AccessoryKeyCatalog.encode(key), key.rawValue)
            XCTAssertNil(AccessoryKeyCatalog.encode(id: key.rawValue), key.rawValue)
        }
        XCTAssertEqual(AccessoryKey.ctrl.modifier, .control)
        XCTAssertEqual(AccessoryKey.alt.modifier, .alternate)
        XCTAssertEqual(AccessoryKey.shift.modifier, .shift)
        XCTAssertEqual(AccessoryKey.cmd.modifier, .command)
    }

    func test_unknownIDEncodesToNil() {
        XCTAssertNil(AccessoryKeyCatalog.encode(id: "nonsense"))
        XCTAssertNil(AccessoryKeyCatalog.encode(id: "custom:1D6A8A1C-0000-4000-8000-000000000000"))
        XCTAssertNil(AccessoryKeyCatalog.encode(id: ""))
    }

    /// Every entry goes through `TerminalKeySequenceEncoder` — no key may grow
    /// a private byte path in the catalog.
    func test_everyEntryDelegatesToTheSharedKeySequenceEncoder() {
        let modifiers = TerminalModifiers(ctrl: true, alt: true, shift: true, cmd: true)
        for key in AccessoryKey.allCases {
            guard let terminalKey = key.terminalKey else {
                XCTAssertTrue(key.isModifier, "\(key.rawValue) has no terminal key but is not a modifier")
                continue
            }
            for applicationCursor in [false, true] {
                XCTAssertEqual(
                    AccessoryKeyCatalog.encode(
                        key,
                        modifiers: modifiers,
                        applicationCursorMode: applicationCursor
                    ),
                    TerminalKeySequenceEncoder.encode(
                        terminalKey,
                        modifiers: modifiers.terminalOnly,
                        mode: TerminalKeyMode(applicationCursorKeys: applicationCursor)
                    ),
                    "\(key.rawValue)"
                )
            }
        }
    }

    // MARK: - Default bar orders

    func test_defaultBarOrdersAreTheShippedLayouts() {
        XCTAssertEqual(
            AccessoryKeyCatalog.defaultPhoneBarOrder,
            [.esc, .enter, .ctrl, .tab, .left, .right, .down, .up, .alt,
             .ctrlC, .ctrlJ, .ctrlL]
        )
        XCTAssertEqual(
            AccessoryKeyCatalog.defaultTabletBarOrder,
            [.esc, .ctrl, .alt, .tab, .left, .down, .up, .right, .pipe, .tilde]
        )
    }

    /// ⌘ is the one modifier chip that sends nothing to the remote, so it ships
    /// in neither default — a bar with ⌃ ⌥ ⌘ side by side puts two different
    /// kinds of key on one row with nothing to tell them apart.
    func test_commandShipsInNoDefaultBar() {
        XCTAssertFalse(AccessoryKeyCatalog.defaultPhoneBarOrder.contains(.cmd))
        XCTAssertFalse(AccessoryKeyCatalog.defaultTabletBarOrder.contains(.cmd))
    }

    /// Both default bars must fit their idiom's chip budget. Phone chips are
    /// 44pt wide with 6pt gaps and no horizontal padding, so twelve is ~594pt:
    /// a whole row in landscape, which is the width the default is sized to.
    /// Portrait has scrolled since the row was ten chips long.
    func test_defaultBarsStayWithinTheirChipBudget() {
        XCTAssertLessThanOrEqual(AccessoryKeyCatalog.defaultPhoneBarOrder.count, 12)
        XCTAssertLessThanOrEqual(AccessoryKeyCatalog.defaultTabletBarOrder.count, 12)
    }

    // MARK: - Persistence codec

    /// The distinction that is easy to lose: *no stored value* means the user
    /// never touched the bar and gets the default; a *stored empty array* is a
    /// deliberately empty row and must stay empty.
    func test_unsetRestoresDefaultsWhileStoredEmptyStaysEmpty() {
        XCTAssertEqual(
            AccessoryKeyCatalog.resolveStoredOrder(nil, defaults: AccessoryKeyCatalog.defaultPhoneBarOrder),
            ["esc", "enter", "ctrl", "tab", "left", "right", "down", "up", "alt",
             "ctrlC", "ctrlJ", "ctrlL"]
        )
        XCTAssertEqual(
            AccessoryKeyCatalog.resolveStoredOrder([], defaults: AccessoryKeyCatalog.defaultPhoneBarOrder),
            []
        )
    }

    /// Unknown values are dropped one at a time rather than failing the whole
    /// array — that is what makes `custom:<uuid>` slots safe to write into a
    /// shared `[String]` and what lets an older build survive a newer chip.
    func test_unknownAndCustomIDsAreDroppedIndividually() {
        let stored = ["esc", "custom:1D6A8A1C-0000-4000-8000-000000000000", "nonsense", "tab"]

        // The raw order is preserved, because a custom slot still has to render.
        XCTAssertEqual(
            AccessoryKeyCatalog.resolveStoredOrder(stored, defaults: AccessoryKeyCatalog.defaultPhoneBarOrder),
            stored
        )
        // Only the built-in subset resolves to catalog keys.
        XCTAssertEqual(AccessoryKeyCatalog.builtInKeys(in: stored), [.esc, .tab])
        // A stored order of nothing but custom slots is not "empty" — it is a
        // bar of user shortcuts, so it must not fall back to defaults.
        XCTAssertEqual(
            AccessoryKeyCatalog.resolveStoredOrder(
                ["custom:1D6A8A1C-0000-4000-8000-000000000000"],
                defaults: AccessoryKeyCatalog.defaultPhoneBarOrder
            ),
            ["custom:1D6A8A1C-0000-4000-8000-000000000000"]
        )
    }

    func test_persistedIDsRoundTrip() {
        let ids = AccessoryKeyCatalog.persistedIDs(for: AccessoryKeyCatalog.defaultTabletBarOrder)
        XCTAssertEqual(
            AccessoryKeyCatalog.builtInKeys(in: ids),
            AccessoryKeyCatalog.defaultTabletBarOrder
        )
        XCTAssertEqual(AccessoryKeyCatalog.allIDs, AccessoryKey.allCases.map(\.rawValue))
        XCTAssertEqual(AccessoryKeyCatalog.allKeys, AccessoryKey.allCases)
    }

    // MARK: - Custom-shortcut escape hatch

    /// The prefix must be invisible to the built-in decoder — that is the whole
    /// mechanism: a build that predates custom chips drops the entry and keeps
    /// the rest of the bar, forward and backward compatible with no migration.
    func test_customIDsAreInvisibleToTheBuiltInDecoder() {
        let uuid = "1D6A8A1C-0000-4000-8000-000000000000"
        let id = AccessoryKeyCatalog.customID(forUUID: uuid)

        XCTAssertEqual(id, "custom:\(uuid)")
        XCTAssertTrue(AccessoryKeyCatalog.isCustomID(id))
        XCTAssertNil(AccessoryKey(rawValue: id))
        XCTAssertEqual(AccessoryKeyCatalog.customUUIDString(fromID: id), uuid)

        XCTAssertFalse(AccessoryKeyCatalog.isCustomID("esc"))
        XCTAssertNil(AccessoryKeyCatalog.customUUIDString(fromID: "esc"))
        // No catalog ID may ever start with the escape-hatch prefix.
        for key in AccessoryKey.allCases {
            XCTAssertFalse(AccessoryKeyCatalog.isCustomID(key.rawValue), key.rawValue)
        }
    }

    // MARK: - Legacy Android IDs

    /// Android's shipped persisted vocabulary, read from
    /// `android/data/.../AccessoryBarLayout.kt`. Every one of these must map
    /// onto a catalog key or a stored Android layout silently loses chips.
    private static let androidPersistedIDs = [
        "escape", "control", "tab", "left", "right", "down", "up", "alt",
        "control-c", "control-j", "shift", "home", "end", "page-up", "page-down",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
        "pipe", "tilde", "slash", "backslash", "dollar", "left-brace",
        "right-brace", "left-bracket", "right-bracket", "less-than", "greater-than",
    ]

    func test_everyLegacyAndroidIDMapsOntoACatalogKey() {
        XCTAssertEqual(Set(Self.androidPersistedIDs).count, Self.androidPersistedIDs.count)
        XCTAssertEqual(
            Set(AccessoryKeyCatalog.legacyAndroidIDMap.keys),
            Set(Self.androidPersistedIDs)
        )
        for legacy in Self.androidPersistedIDs {
            let canonical = AccessoryKeyCatalog.legacyAndroidIDMap[legacy]
            XCTAssertNotNil(canonical, legacy)
            XCTAssertNotNil(AccessoryKey(rawValue: canonical ?? ""), legacy)
            XCTAssertEqual(
                AccessoryKeyCatalog.key(forLegacyAndroidID: legacy)?.rawValue,
                canonical,
                legacy
            )
        }
    }

    func test_legacySpellingsThatActuallyDiffer() {
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "escape"), .esc)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "control"), .ctrl)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "control-c"), .ctrlC)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "control-j"), .ctrlJ)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "page-up"), .pgup)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "page-down"), .pgdn)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "left-brace"), .lbrace)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "right-brace"), .rbrace)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "left-bracket"), .lbracket)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "right-bracket"), .rbracket)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "less-than"), .lt)
        XCTAssertEqual(AccessoryKeyCatalog.key(forLegacyAndroidID: "greater-than"), .gt)
    }

    /// A partially migrated array must resolve in one pass, so canonical IDs
    /// pass through the legacy lookup unchanged.
    func test_canonicalIDsPassThroughTheLegacyLookup() {
        for key in AccessoryKey.allCases {
            XCTAssertEqual(
                AccessoryKeyCatalog.key(forLegacyAndroidID: key.rawValue),
                key,
                key.rawValue
            )
        }
        XCTAssertNil(AccessoryKeyCatalog.key(forLegacyAndroidID: "nonsense"))
    }

    /// The table covers every key Android ever persisted under its own
    /// spelling, and only those. ⌘ is out because Android's accessory row is a
    /// touch/IME affordance and carries no hardware-keyboard commands; ↩ and
    /// ⌃L are out because they were added after the catalog was shared, so
    /// there is no older Android spelling of them to migrate from.
    func test_keysWithNoLegacyAndroidPeer() {
        XCTAssertEqual(
            Set(AccessoryKeyCatalog.legacyAndroidIDMap.values),
            Set(AccessoryKey.allCases.filter { ![.cmd, .enter, .ctrlL].contains($0) }.map(\.rawValue))
        )
        for id in ["cmd", "enter", "ctrlL"] {
            XCTAssertFalse(AccessoryKeyCatalog.legacyAndroidIDMap.values.contains(id), id)
        }
    }

    /// Android's `phoneDefaultOrder` from before the catalog was shared. Every
    /// entry must still resolve, and today's default must be that same row in
    /// the same relative order plus exactly the keys added since — a bar stored
    /// by that build keeps its chips and simply does not gain the new ones.
    func test_androidLegacyPhoneDefaultResolvesAndNamesTheKeysAddedSince() {
        let androidPhoneDefault = [
            "escape", "control", "tab", "left", "right", "down", "up", "alt",
            "control-c", "control-j",
        ]
        let migrated = androidPhoneDefault.compactMap(AccessoryKeyCatalog.key(forLegacyAndroidID:))
        XCTAssertEqual(migrated.count, androidPhoneDefault.count)
        XCTAssertEqual(
            AccessoryKeyCatalog.defaultPhoneBarOrder.filter(migrated.contains),
            migrated
        )
        XCTAssertEqual(
            AccessoryKeyCatalog.defaultPhoneBarOrder.filter { !migrated.contains($0) },
            [.enter, .ctrlL]
        )
    }
}
