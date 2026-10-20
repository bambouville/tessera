import Foundation

public enum TmuxValidationError: String, Error, Equatable, Sendable {
    case empty
    case tooLong
    case unsafeCharacter
}

/// How a control client participates in tmux's server-mediated grid sizing.
/// Rendering clients publish their viewport. Observer/bridge clients preserve
/// the existing server grid unless they have explicitly become its owner.
public enum TmuxClientSizePolicy: String, Codable, CaseIterable, Sendable {
    case resizeTmux
    case preserveServerGeometry
}

public enum TmuxGeometryValidationError: String, Error, Equatable, Sendable {
    case nonPositiveDimension
    case dimensionTooLarge
}

/// A validated tmux client grid. Keeping validation in the portable core lets
/// Apple, Android, and the Mac Bridge make the same capability decision before
/// issuing a fixed `refresh-client -C` command.
public struct TmuxClientGeometry: Codable, Equatable, Sendable {
    public static let maximumDimension = 65_535

    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) throws {
        guard columns > 0, rows > 0 else {
            throw TmuxGeometryValidationError.nonPositiveDimension
        }
        guard columns <= Self.maximumDimension,
              rows <= Self.maximumDimension else {
            throw TmuxGeometryValidationError.dimensionTooLarge
        }
        self.columns = columns
        self.rows = rows
    }
}

public enum TmuxGeometryCapability {
    /// Whether this client may publish its local viewport to tmux. An observer
    /// that preserves server geometry becomes capable only after the platform
    /// has independently established that it owns the preserved grid.
    public static func canPublishLocalGeometry(
        policy: TmuxClientSizePolicy,
        ownsPreservedGeometry: Bool
    ) -> Bool {
        switch policy {
        case .resizeTmux:
            true
        case .preserveServerGeometry:
            ownsPreservedGeometry
        }
    }
}

/// A tmux session name safe to place in a fixed command without shell quoting.
/// The grammar intentionally matches Tessera's shipped Mosh/continuity rule.
public struct TmuxSessionName: Codable, Hashable, Sendable {
    public static let maximumUTF8Length = 256
    public let rawValue: String

    public init(validating rawValue: String) throws {
        switch Self.validationError(for: rawValue) {
        case nil:
            self.rawValue = rawValue
        case .some(let error):
            throw error
        }
    }

    public static func isValid(_ candidate: String) -> Bool {
        validationError(for: candidate) == nil
    }

    public static func validationError(for candidate: String) -> TmuxValidationError? {
        guard !candidate.isEmpty else { return .empty }
        guard candidate.utf8.count <= maximumUTF8Length else { return .tooLong }
        let valid = candidate.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte)
                || (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || byte == 0x2D || byte == 0x5F || byte == 0x2E
        }
        return valid ? nil : .unsafeCharacter
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Socket labels use the same conservative token grammar as session names.
/// Absolute socket paths belong to a platform adapter and are never interpolated
/// into portable fixed commands.
public struct TmuxSocketName: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(validating rawValue: String) throws {
        _ = try TmuxSessionName(validating: rawValue)
        self.rawValue = rawValue
    }

    public static func isValid(_ candidate: String) -> Bool {
        TmuxSessionName.isValid(candidate)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(validating: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TmuxTarget: Hashable, Sendable, CustomStringConvertible {
    case sessionID(SessionId)
    case sessionName(TmuxSessionName)
    case windowID(WindowId)
    case paneID(PaneId)

    public var description: String {
        switch self {
        case .sessionID(let id): id.description
        case .sessionName(let name): name.rawValue
        case .windowID(let id): id.description
        case .paneID(let id): id.description
        }
    }
}

/// Fixed, format-only queries used by Apple, Android, and the Mac bridge.
/// Caller-provided format strings never cross this boundary.
public enum TmuxFixedQuery {
    public static func hasSession(_ target: TmuxTarget) -> String {
        "has-session -t \(target.description)"
    }

    public static func listWindows(_ session: TmuxTarget) -> String {
        "list-windows -t \(session.description) -F '#{window_id}\\t#{window_index}\\t#{window_name}\\t#{window_active}\\t#{pane_id}\\t#{pane_title}\\t#{pane_title_changed}\\t#{window_layout}\\t#{window_visible_layout}\\t#{window_zoomed_flag}'"
    }

    public static func displaySessionIdentity(_ target: TmuxTarget) -> String {
        "display-message -p -t \(target.description) '#{session_id}\\t#{session_name}\\t#{socket_path}'"
    }

    /// Exact-name session lookup used by continuity/bootstrap compatibility.
    /// The leading `=` is tmux's exact-target operator and is kept inside the
    /// fixed-query owner so no platform or protocol adapter forks its grammar.
    public static func displaySessionAttachment(_ name: TmuxSessionName) -> String {
        "display-message -p -t =\(name.rawValue) '#{session_id}\\t#{session_name}\\t#{session_attached}'"
    }
}
