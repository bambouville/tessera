// Tessera/Keyboard/CustomShortcut.swift
// User-defined shortcuts: a trigger (chord, bar chip, or both) bound to text or
// keys sent to the remote.
//
// Why this does NOT reuse the swipe pad's macro language:
// `MacroEncoder` strips *every* space ("git status↵" → "gitstatus") and matches
// the bare words `tab` / `esc` anywhere they end at a token boundary, so
// "crontab -l" encodes as "cron"<TAB>"-l". That is fine for the 1–3 character
// agent replies it was written for and wrong for arbitrary command text. Here
// literal text stays literal and special keys are separate tokens, so there is
// no grammar to get wrong and nothing to re-parse. The swipe pad's spec
// language is deliberately untouched.
import Foundation

/// One piece of a custom action. Stored as a typed array rather than a string,
/// so what the user typed and what gets sent can't drift apart.
enum ShortcutToken: Codable, Equatable, Hashable {
    /// Literal text, sent as UTF-8 exactly as written — spaces included.
    case text(String)
    /// A named key, encoded through the same path an accessory chip uses.
    case key(AccessoryChip)
    /// Enter — carriage return, 0x0D.
    ///
    /// Deliberately its own case rather than `.key(.ctrlJ)`: the ^J chip sends
    /// 0x0A, a *line feed*. Shells treat CR as the Enter key (it is what
    /// SwiftTerm's `returnByteSequence` sends), and a shortcut that fills the
    /// prompt but never runs is a confusing bug to chase.
    case returnKey

    var displayLabel: String {
        switch self {
        case .text(let s): return s
        case .key(let chip): return chip.displayLabel
        case .returnKey: return "↵"
        }
    }
}

extension Array where Element == ShortcutToken {
    /// Bytes for the wire. Arrow keys encode against the session's current
    /// cursor mode, exactly like a bar chip — `AccessoryChipEncoder` owns that
    /// and is reused verbatim rather than reimplemented.
    func encoded(applicationCursor: Bool) -> [UInt8] {
        var out: [UInt8] = []
        for token in self {
            switch token {
            case .text(let s):
                // `s.utf8` rather than `Array(s.utf8)`: inside an extension on
                // Array, a bare `Array(…)` means `Array<Element>` — here,
                // `[ShortcutToken]`.
                out.append(contentsOf: s.utf8)
            case .returnKey:
                out.append(0x0D)
            case .key(let chip):
                // A modifier chip arms state rather than sending bytes, and
                // `AccessoryChipEncoder` preconditions on being handed one.
                guard !chip.isModifier else { continue }
                out.append(contentsOf: AccessoryChipEncoder.encode(
                    chip,
                    armed: .none,
                    applicationCursor: applicationCursor
                ))
            }
        }
        return out
    }

    /// True when the sequence ends in a carriage return — i.e. it will execute
    /// rather than just fill the prompt. Surfaced in the editor so "runs
    /// immediately" is never a surprise.
    var endsWithReturn: Bool {
        guard let last = last else { return false }
        switch last {
        case .returnKey:     return true
        case .key:           return false
        case .text(let s):   return s.hasSuffix("\n") || s.hasSuffix("\r")
        }
    }

    var plainSummary: String {
        map(\.displayLabel).joined()
    }
}

/// What a custom chip shows on the accessory bar.
///
/// `.symbol` is the default: SF Symbols are monochrome and tint with the theme,
/// which is what keeps the bar reading as chrome. `.character` exists because
/// it's the user's own bar and the symbol library won't have everything — but
/// an emoji renders in full color, so it is a choice rather than the default.
enum ChipLabelKind: Codable, Equatable, Hashable {
    case symbol(String)
    case text(String)
    case character(String)

    var isSymbol: Bool { if case .symbol = self { return true }; return false }
}

/// Where a custom shortcut applies. `process` reuses
/// `SwipePadProfile.matchProcess` semantics — a literal name, or a `regex:`
/// prefix — so an "approve" shortcut exists only while an agent is in the
/// foreground and can't fire a stray `1` into a shell.
enum ShortcutScope: Codable, Equatable, Hashable {
    case everywhere
    case hosts([UUID])
    case process(String)

    var summary: String {
        switch self {
        case .everywhere:
            return String(localized: "everywhere", comment: "Shortcut scope: active in all sessions")
        case .hosts(let ids):
            return String(
                localized: "\(ids.count) hosts",
                comment: "Shortcut scope: limited to N hosts. Pluralized on the host count."
            )
        case .process(let p):
            // The process name is remote data — it stays verbatim.
            return String(
                localized: "when running \(p)",
                comment: "Shortcut scope: active only while a named process runs"
            )
        }
    }
}

struct CustomShortcut: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String
    /// Optional — a chip-only shortcut is the path for a device with no
    /// hardware keyboard attached.
    var binding: KeyBinding?
    /// Optional — a chord-only shortcut never appears on the bar.
    var chipLabel: ChipLabelKind?
    var tokens: [ShortcutToken]
    var scope: ShortcutScope

    init(
        id: UUID = UUID(),
        name: String,
        binding: KeyBinding? = nil,
        chipLabel: ChipLabelKind? = nil,
        tokens: [ShortcutToken],
        scope: ShortcutScope = .everywhere
    ) {
        self.id = id
        self.name = name
        self.binding = binding
        self.chipLabel = chipLabel
        self.tokens = tokens
        self.scope = scope
    }

    /// Whether the user asked for either kind of trigger. Not the same as being
    /// *able* to fire it — see `isReachable(barKeys:)`.
    var hasTrigger: Bool { binding != nil || chipLabel != nil }

    /// Can the user actually run this right now?
    ///
    /// A chip label is not a trigger on its own — it only says how the chip
    /// renders. Until `chipRawID` is in the stored bar order there is nothing to
    /// tap, so a chip-only shortcut with no placement is dead: no chord, no
    /// chip, and an editor that showed an ON THE BAR preview of a chip that
    /// wasn't. That was the shipped defect this guards.
    func isReachable(barKeys: [String]) -> Bool {
        binding != nil || barKeys.contains(chipRawID)
    }

    /// The raw ID this shortcut occupies in `accessoryBarKeys`.
    ///
    /// `AccessoryChip.from(rawIDs:)` decodes through
    /// `compactMap(AccessoryChip.init(rawValue:))`, so a build that doesn't
    /// understand this prefix drops the entry instead of failing to decode the
    /// whole bar. Forward and backward compatible for free — asserted in
    /// `CustomShortcutTests`.
    var chipRawID: String { "custom:\(id.uuidString)" }

    static func id(fromChipRawID raw: String) -> UUID? {
        guard raw.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(raw.dropFirst("custom:".count)))
    }

    func encoded(applicationCursor: Bool) -> [UInt8] {
        tokens.encoded(applicationCursor: applicationCursor)
    }
}

/// Where a custom shortcut's chip sits in `AppearancePreferences.accessoryBarKeys`.
///
/// Pure, so the rule the editor applies on save is testable without driving a
/// view — the same reason `SavedHostAdmissionPolicy` is separate from its sheet.
enum AccessoryBarPlacement {

    /// Applies the editor's "accessory bar chip" choice to a stored bar order.
    /// Appends at the end (the bar scrolls; a new chip landing mid-row would
    /// shuffle muscle memory) and never duplicates.
    static func apply(wantsChip: Bool, chipRawID: String, to keys: [String]) -> [String] {
        if wantsChip {
            guard !keys.contains(chipRawID) else { return keys }
            return keys + [chipRawID]
        }
        return keys.filter { $0 != chipRawID }
    }

    /// Drops a deleted shortcut's chip. A stale `custom:<uuid>` renders as
    /// nothing — the bar drops raw IDs it can't resolve — so this is about not
    /// accumulating dead entries in the user's stored order rather than about
    /// anything visible.
    static func removing(chipRawID: String, from keys: [String]) -> [String] {
        keys.filter { $0 != chipRawID }
    }
}
