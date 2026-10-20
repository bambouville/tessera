import Foundation

public struct TmuxGridAuthorityIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = TmuxGridAuthorityStamp.sanitizeToken(id)
        self.displayName = TmuxGridAuthorityStamp.sanitizeToken(displayName)
    }
}

public struct TmuxGridAuthorityStamp: Codable, Equatable, Sendable {
    public static let version = "v1"
    /// The longest display name a parsed stamp keeps, in Characters. A
    /// peer's name is drawn on the veil and crosses the platform ABIs in
    /// several fields of one bounded response, so a longer one (a corrupt
    /// or hostile stamp) is truncated rather than allowed to get the whole
    /// reply rejected. Identity is the device ID and generation alone.
    public static let maximumDisplayNameCharacters = 64
    /// The longest device ID a stamp may carry. Identity cannot be cut
    /// short, so a longer one (no device writes one: IDs are UUIDs) makes the
    /// stamp unparseable, which classifies `.unknown`.
    public static let maximumDeviceIDCharacters = 128
    /// The largest generation a stamp may carry. Android holds generations
    /// as a signed 64-bit `Long`, and its JSON decoder rounds a larger number
    /// through a double, so one stamp past this would be two identities
    /// across the platforms. No device counts that high; a larger one makes
    /// the stamp unparseable, which classifies `.unknown`.
    public static let maximumGeneration = UInt64(Int64.max)
    /// The longest canonical wire value, in bytes: every parsed field is
    /// ASCII (the sanitize check), at its bound, with three separators.
    public static let maximumWireBytes = version.utf8.count + maximumDeviceIDCharacters
        + String(maximumGeneration).utf8.count + maximumDisplayNameCharacters + 3
    /// Epoch milliseconds occupy the high bits; the reducer increments the low bits.
    /// Clock access belongs to the adapters, never the pure core.
    public static func generationBase(unixMillis: Int64) -> UInt64 {
        let origin: Int64 = 1_767_225_600_000
        guard unixMillis > origin else { return 0 }
        // Saturate only outside realistic clock values, preserving room for claims.
        let epoch = min(UInt64(unixMillis - origin), (maximumGeneration - 4095) >> 12)
        return epoch << 12
    }

    public let deviceID: String
    public let generation: UInt64
    public let displayName: String

    public init(identity: TmuxGridAuthorityIdentity, generation: UInt64) {
        self.deviceID = identity.id
        self.generation = generation
        self.displayName = identity.displayName
    }

    public var wireValue: String {
        "\(Self.version) \(deviceID) \(generation) \(displayName)"
    }

    public static func parse(_ rawValue: String) -> TmuxGridAuthorityStamp? {
        let fields = rawValue
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
        guard fields.count >= 4,
              fields[0] == Substring(version),
              let generation = UInt64(fields[2]),
              generation <= maximumGeneration
        else { return nil }
        let id = String(fields[1])
        guard id.count <= maximumDeviceIDCharacters else { return nil }
        let name = fields[3...].joined(separator: " ")
        guard sanitizeToken(id) == id, sanitizeToken(name) == name else { return nil }
        // `prefix` counts Characters, so the cut never splits a grapheme.
        return .init(
            identity: .init(id: id, displayName: String(name.prefix(maximumDisplayNameCharacters))),
            generation: generation
        )
    }

    /// A subscription value bounded for a platform ABI. A longer value
    /// becomes its canonical form, which parses to the same stamp, or the
    /// empty value when it parses to none; either classifies exactly as the
    /// original, so an oversized value cannot get a reduction rejected.
    public static func boundedRawValue(_ value: String) -> String {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count > maximumWireBytes else { return raw }
        return parse(raw)?.wireValue ?? ""
    }

    public static func sanitizeToken(_ raw: String) -> String {
        let characters = raw.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".":
                Character(scalar)
            default:
                "-"
            }
        }
        let token = String(characters)
        return token.isEmpty ? "-" : token
    }
}

public enum TmuxGridAuthoritySnapshot: Codable, Equatable, Sendable {
    case unknown
    case mine(generation: UInt64)
    case peer(deviceID: String, displayName: String, generation: UInt64)

    public var peerDisplayName: String? {
        if case .peer(_, let displayName, _) = self { return displayName }
        return nil
    }

    public var isPeer: Bool {
        if case .peer = self { return true }
        return false
    }

    public static func classify(
        rawValue: String,
        localDeviceID: String?
    ) -> TmuxGridAuthoritySnapshot {
        guard let stamp = TmuxGridAuthorityStamp.parse(rawValue) else { return .unknown }
        if stamp.deviceID == localDeviceID {
            return .mine(generation: stamp.generation)
        }
        return .peer(
            deviceID: stamp.deviceID,
            displayName: stamp.displayName,
            generation: stamp.generation
        )
    }
}

public enum TmuxGridAuthorityScope: Equatable, Sendable {
    /// Inline clients attached to the owner, and the legacy fallback.
    case ownSession
    /// Stable owner id resolved from a grouped mosh view.
    case owner(SessionId)
}

public enum TmuxGridAuthority {
    public static let option = "@tessera_authority"
    public static let subscriptionName = "tessera-authority"

    public static func visibleClientOption(identityID: String) -> String {
        "@tessera-visible-\(TmuxGridAuthorityStamp.sanitizeToken(identityID))"
    }

    /// An owner read names the owner in its reply (`$O|<stamp>`), so a
    /// killed owner (an empty loop) differs from an unset stamp: both
    /// `show-options -q -t` and `display-message -t` answer a missing target
    /// with an empty success. It reads the option as the owner subscription
    /// does.
    public static func queryCommand(_ scope: TmuxGridAuthorityScope) -> String {
        switch scope {
        case .ownSession: return "show-options -qv \(option)"
        case .owner(let id):
            return "display-message -p '#{S:#{?#{==:#{session_id},\(id)},#{session_id}|#{\(option)},}}'"
        }
    }

    /// A read reply's stamp lines as `show-options -qv` gives them (none when
    /// unset), or nil when an owner read found no owner.
    public static func queryReplyLines(_ reply: [String], scope: TmuxGridAuthorityScope) -> [String]? {
        guard case .owner(let id) = scope else { return reply }
        let prefix = "\(id)|"
        guard reply.count == 1, reply[0].hasPrefix(prefix) else { return nil }
        let value = String(reply[0].dropFirst(prefix.count))
        return value.isEmpty ? [] : [value]
    }

    public static func writeCommands(_ stamp: TmuxGridAuthorityStamp, scope: TmuxGridAuthorityScope) -> [String] {
        switch scope {
        case .ownSession: return [setOptionCommand(stamp)]
        case .owner(let id):
            return ["set-option -t '\(id)' \(option) '\(stamp.wireValue)'", setOptionCommand(stamp)]
        }
    }

    /// The stamp as the subscription reads it. A session option reads the
    /// same from every pane, so `TmuxControlSubscriptions` registers it once,
    /// against one pane.
    public static func subscriptionFormat(_ scope: TmuxGridAuthorityScope) -> String {
        switch scope {
        case .ownSession: return "#{\(option)}"
        case .owner(let id): return "#{S:#{?#{==:#{session_id},\(id)},#{\(option)},}}"
        }
    }

    public static func ownerResolutionCommands(ownerSessionName: String) -> [String] {
        ["display-message -p -t \(AutoTmuxCommands.singleQuoted("=\(ownerSessionName):")) '#{session_id} #{session_group}'",
         "display-message -p '#{session_id} #{session_group}'"]
    }

    public static func resolveOwner(ownerReply: [String]?, ownReply: [String]?) -> SessionId? {
        func parse(_ reply: [String]?) -> (SessionId, String)? {
            guard let reply, reply.count == 1 else { return nil }
            // A named group may contain spaces; only the id ends at the first one.
            let fields = reply[0].split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let id = SessionId(wireValue: String(fields[0])),
                  !fields[1].isEmpty, !fields[1].contains(where: \.isNewline) else { return nil }
            return (id, String(fields[1]))
        }
        guard let owner = parse(ownerReply), let own = parse(ownReply),
              owner.1 == own.1, owner.0 != own.0 else { return nil }
        return owner.0
    }

    public static func setOptionCommand(_ stamp: TmuxGridAuthorityStamp) -> String {
        "set-option \(option) '\(stamp.wireValue)'"
    }
}
