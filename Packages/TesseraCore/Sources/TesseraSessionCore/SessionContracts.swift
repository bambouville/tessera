import Foundation
import TesseraDomainCore
import TesseraTrustCore
@_exported import TmuxControlCore

public struct SessionGeneration: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public enum SessionVisibility: String, Codable, Sendable {
    case active
    case inactive
    case background
}

public enum SharedSessionState: Equatable, Sendable {
    case idle
    case connecting(attemptID: UUID)
    case connected
    case disconnected
    case failed(CoreFailure)
}

public struct CoreFailure: Codable, Equatable, Sendable {
    public let code: String
    public let arguments: [String: String]

    public init(code: String, arguments: [String: String] = [:]) {
        self.code = code
        self.arguments = arguments
    }
}

public enum SessionCommand: Equatable, Sendable {
    case connect(ConnectionIntent)
    case cancelConnect(attemptID: UUID)
    case disconnect
    case sendInput(Data)
    case resize(columns: Int, rows: Int)
    case selectTmuxWindow(String)
    case selectTmuxPane(String)
    case sendTmuxPaneInput(data: Data, paneID: String, receipt: SessionCommandReceipt?)
    case sendTmuxPaneKey(SessionTmuxPaneKey, paneID: String, receipt: SessionCommandReceipt?)
    case createTmuxWindow
    case closeTmuxWindow(String)
    case closeTmuxPane(String)
    case splitTmuxPane(String, axis: SessionTmuxSplitAxis, before: Bool)
    case cycleTmuxPane(forward: Bool)
    case setTmuxPaneZoomed(String, zoomed: Bool)
    case renameTmuxWindow(String, name: String)
    case moveTmuxWindow(String, move: TmuxWindowMove)
    case renumberTmuxWindows
    case setTmuxGridPresentation(SessionTmuxGridPresentation)
    case claimTmuxGridAuthority(
        reason: SessionTmuxGridAuthorityReason,
        repaintEvenIfSame: Bool
    )
    case reclaimTmuxGridAuthority(reason: SessionTmuxGridAuthorityReason)
    case completeTmuxGridAuthorityRepaint(generation: UInt64)
    case setFocused(Bool)
    case setApplicationVisibility(SessionVisibility)
    case requestFullRepaint
    case submitChallengeResponse(ChallengeResponse)
    case destroy
}

public struct SessionCommandReceipt: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum SessionCommandResult: Codable, Equatable, Sendable {
    case succeeded
    case failed(CoreFailure)
}

public struct SessionCommandCompletion: Codable, Equatable, Sendable {
    public let receipt: SessionCommandReceipt
    public let result: SessionCommandResult

    public init(receipt: SessionCommandReceipt, result: SessionCommandResult) {
        self.receipt = receipt
        self.result = result
    }
}

public enum SessionTmuxPaneKey: String, Codable, Equatable, Sendable {
    case enter
    case escape
    // Prompt-answer navigation, sent by name so a pane's mode cannot change
    // what the bytes mean.
    case tab
    case backTab
    case up
    case down
    case left
    case right
    case shiftLeft
    case controlRightBracket

    /// The key's name in tmux's `send-keys`.
    public var tmuxKeyName: String {
        switch self {
        case .enter: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .backTab: "BTab"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .shiftLeft: "S-Left"
        case .controlRightBracket: "C-]"
        }
    }

    public init?(tmuxKeyName: String) {
        guard let key = Self.allNamed.first(where: { $0.tmuxKeyName == tmuxKeyName }) else { return nil }
        self = key
    }

    /// The bytes a terminal in its default (normal cursor) mode sends.
    public var bytes: [UInt8] {
        switch self {
        case .enter: [0x0D]
        case .escape: [0x1B]
        case .tab: [0x09]
        case .backTab: Array("\u{1B}[Z".utf8)
        case .up: Array("\u{1B}[A".utf8)
        case .down: Array("\u{1B}[B".utf8)
        case .right: Array("\u{1B}[C".utf8)
        case .left: Array("\u{1B}[D".utf8)
        case .shiftLeft: Array("\u{1B}[1;2D".utf8)
        case .controlRightBracket: [0x1D]
        }
    }

    private static let allNamed: [SessionTmuxPaneKey] = [
        .enter, .escape, .tab, .backTab, .up, .down, .left, .right, .shiftLeft, .controlRightBracket,
    ]
}

public enum SessionTmuxSplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum SessionTmuxGridPresentation: String, Codable, Equatable, Sendable {
    case singlePane
    case paneGrid
}

public enum SessionTmuxGridAuthorityReason: String, Codable, Equatable, Sendable {
    case user
    case forceRefresh
}

public enum SessionCommandLimits {
    public static let maximumInputBytes = 1_048_576
    public static let maximumPendingReceipts = 1_024
    public static let maximumRenameUnicodeScalars = 100
    public static let maximumColumns = 10_000
    public static let maximumRows = 10_000
    public static let maximumTmuxObjectID = 1_000_000
}

public extension SessionCommand {
    var completionReceipt: SessionCommandReceipt? {
        switch self {
        case .sendTmuxPaneInput(_, _, let receipt),
             .sendTmuxPaneKey(_, _, let receipt):
            receipt
        default:
            nil
        }
    }

    /// The grid-authority gate this command passes (review §6.5 S5′).
    /// Receipted Agent Center pane sends are neutral; grid typing has no receipt.
    var authorityGate: SessionCommandAuthorityGate {
        SessionBackendOperation(self).authorityGate
    }
}

/// Which grid-authority gate a command must pass before it reaches tmux or
/// the mosh transport (review §6.5 S5′). Adapters read the session's
/// projection once when the command is dispatched and again where it is
/// applied, since the gate can close while it waits in the ordered queue.
public enum SessionCommandAuthorityGate: String, Codable, CaseIterable, Equatable, Sendable {
    /// Keys, paste, paths, mouse and mosh bytes: refused while the
    /// projection gates typing (M7).
    case typing
    /// Window and pane mutations, un-receipted pane sends and the forced
    /// repaint: refused on the projection's mutation refusal (D7).
    case mutation
    /// Lifecycle, sizing, presentation, claims, challenges and acknowledged
    /// Agent Center pane replies, whose receipt reports tmux's verdict.
    case ungated

    /// Why the command must not run now, or nil to admit it.
    ///
    /// - Parameters:
    ///   - gatesTyping: `TmuxGridAuthorityPresentation.gatesTyping(lastKnown:)`.
    ///   - mutationRefusal: `TmuxGridAuthorityPresentation.mutationRefusal(lastKnown:)`.
    public func refusal(
        gatesTyping: Bool,
        mutationRefusal: TmuxGridAuthorityPresentation.MutationRefusal?
    ) -> SessionCommandAuthorityRefusal? {
        switch self {
        case .ungated:
            return nil
        case .mutation:
            return mutationRefusal.map(SessionCommandAuthorityRefusal.init)
        case .typing:
            guard gatesTyping else { return nil }
            return mutationRefusal.map(SessionCommandAuthorityRefusal.init) ?? .resuming
        }
    }
}

/// A command the grid-authority gate refused.
public enum SessionCommandAuthorityRefusal: String, Codable, Equatable, Sendable {
    /// A peer holds the grid.
    case yielded
    /// This device's take-back is still running.
    case reclaiming
    /// A show is waiting for its read or running its claim: typing waits,
    /// window commands may proceed.
    case resuming

    public init(_ refusal: TmuxGridAuthorityPresentation.MutationRefusal) {
        switch refusal {
        case .yielded: self = .yielded
        case .reclaiming: self = .reclaiming
        }
    }
}

public struct ConnectionIntent: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let hostID: UUID
    public let policyGeneration: UInt64

    public init(requestID: UUID = UUID(), hostID: UUID, policyGeneration: UInt64) {
        self.requestID = requestID
        self.hostID = hostID
        self.policyGeneration = policyGeneration
    }
}

/// Operations the shared state machine asks a platform transport/lifecycle
/// adapter to perform. Unlike the presentation-facing command type this is a
/// stable, Codable port contract suitable for the C ABI.
public enum SessionBackendOperation: Codable, Equatable, Sendable {
    case connect(ConnectionIntent)
    case cancelConnect(attemptID: UUID)
    case disconnect
    case sendInput(Data)
    case resize(columns: Int, rows: Int)
    case selectTmuxWindow(String)
    case selectTmuxPane(String)
    case sendTmuxPaneInput(data: Data, paneID: String, receipt: SessionCommandReceipt?)
    case sendTmuxPaneKey(SessionTmuxPaneKey, paneID: String, receipt: SessionCommandReceipt?)
    case createTmuxWindow
    case closeTmuxWindow(String)
    case closeTmuxPane(String)
    case splitTmuxPane(String, axis: SessionTmuxSplitAxis, before: Bool)
    case cycleTmuxPane(forward: Bool)
    case setTmuxPaneZoomed(String, zoomed: Bool)
    case renameTmuxWindow(String, name: String)
    case moveTmuxWindow(String, move: TmuxWindowMove)
    case renumberTmuxWindows
    case setTmuxGridPresentation(SessionTmuxGridPresentation)
    case claimTmuxGridAuthority(
        reason: SessionTmuxGridAuthorityReason,
        repaintEvenIfSame: Bool
    )
    case reclaimTmuxGridAuthority(reason: SessionTmuxGridAuthorityReason)
    case completeTmuxGridAuthorityRepaint(generation: UInt64)
    case setFocused(Bool)
    case setApplicationVisibility(SessionVisibility)
    case requestFullRepaint
    case submitChallengeResponse(ChallengeResponse)
    case destroy

    public init(_ command: SessionCommand) {
        switch command {
        case .connect(let value): self = .connect(value)
        case .cancelConnect(let value): self = .cancelConnect(attemptID: value)
        case .disconnect: self = .disconnect
        case .sendInput(let value): self = .sendInput(value)
        case .resize(let columns, let rows): self = .resize(columns: columns, rows: rows)
        case .selectTmuxWindow(let value): self = .selectTmuxWindow(value)
        case .selectTmuxPane(let value): self = .selectTmuxPane(value)
        case .sendTmuxPaneInput(let data, let paneID, let receipt):
            self = .sendTmuxPaneInput(data: data, paneID: paneID, receipt: receipt)
        case .sendTmuxPaneKey(let key, let paneID, let receipt):
            self = .sendTmuxPaneKey(key, paneID: paneID, receipt: receipt)
        case .createTmuxWindow: self = .createTmuxWindow
        case .closeTmuxWindow(let value): self = .closeTmuxWindow(value)
        case .closeTmuxPane(let value): self = .closeTmuxPane(value)
        case .splitTmuxPane(let value, let axis, let before):
            self = .splitTmuxPane(value, axis: axis, before: before)
        case .cycleTmuxPane(let forward): self = .cycleTmuxPane(forward: forward)
        case .setTmuxPaneZoomed(let value, let zoomed):
            self = .setTmuxPaneZoomed(value, zoomed: zoomed)
        case .renameTmuxWindow(let value, let name): self = .renameTmuxWindow(value, name: name)
        case .moveTmuxWindow(let id, let move): self = .moveTmuxWindow(id, move: move)
        case .renumberTmuxWindows: self = .renumberTmuxWindows
        case .setTmuxGridPresentation(let value):
            self = .setTmuxGridPresentation(value)
        case .claimTmuxGridAuthority(let reason, let repaintEvenIfSame):
            self = .claimTmuxGridAuthority(
                reason: reason,
                repaintEvenIfSame: repaintEvenIfSame
            )
        case .reclaimTmuxGridAuthority(let reason): self = .reclaimTmuxGridAuthority(reason: reason)
        case .completeTmuxGridAuthorityRepaint(let generation):
            self = .completeTmuxGridAuthorityRepaint(generation: generation)
        case .setFocused(let value): self = .setFocused(value)
        case .setApplicationVisibility(let value): self = .setApplicationVisibility(value)
        case .requestFullRepaint: self = .requestFullRepaint
        case .submitChallengeResponse(let value): self = .submitChallengeResponse(value)
        case .destroy: self = .destroy
        }
    }

    /// The single classification both platforms gate on (S5′). Android's
    /// `perform()` keeps a Kotlin copy that a JVM test checks against this
    /// one through `tessera_session_authority_gates`.
    public var authorityGate: SessionCommandAuthorityGate {
        switch self {
        case .sendInput:
            .typing
        case .sendTmuxPaneInput(_, _, let receipt), .sendTmuxPaneKey(_, _, let receipt):
            // Acknowledged Agent Center replies target a proved pane without
            // moving grid authority; grid typing carries no receipt.
            receipt == nil ? .mutation : .ungated
        case .selectTmuxWindow, .selectTmuxPane,
             .createTmuxWindow, .closeTmuxWindow, .closeTmuxPane, .splitTmuxPane,
             .cycleTmuxPane, .setTmuxPaneZoomed, .renameTmuxWindow, .moveTmuxWindow,
             .renumberTmuxWindows, .claimTmuxGridAuthority:
            // A forced repaint (`claimTmuxGridAuthority`) never claims (D9),
            // and over a peer or a running take-back it has nothing of its
            // own to paint.
            .mutation
        case .connect, .cancelConnect, .disconnect, .resize, .setTmuxGridPresentation,
             .reclaimTmuxGridAuthority, .completeTmuxGridAuthorityRepaint, .setFocused,
             .setApplicationVisibility, .requestFullRepaint, .submitChallengeResponse,
             .destroy:
            // Resize is latched while yielded and replayed by the take-back;
            // the adapters withhold what would reach the peer's grid.
            .ungated
        }
    }

    public var kindCode: String {
        switch self {
        case .connect: "connect"
        case .cancelConnect: "cancel_connect"
        case .disconnect: "disconnect"
        case .sendInput: "send_input"
        case .resize: "resize"
        case .selectTmuxWindow: "select_tmux_window"
        case .selectTmuxPane: "select_tmux_pane"
        case .sendTmuxPaneInput: "send_tmux_pane_input"
        case .sendTmuxPaneKey: "send_tmux_pane_key"
        case .createTmuxWindow: "create_tmux_window"
        case .closeTmuxWindow: "close_tmux_window"
        case .closeTmuxPane: "close_tmux_pane"
        case .splitTmuxPane: "split_tmux_pane"
        case .cycleTmuxPane: "cycle_tmux_pane"
        case .setTmuxPaneZoomed: "set_tmux_pane_zoomed"
        case .renameTmuxWindow: "rename_tmux_window"
        case .moveTmuxWindow: "move_tmux_window"
        case .renumberTmuxWindows: "renumber_tmux_windows"
        case .setTmuxGridPresentation: "set_tmux_grid_presentation"
        case .claimTmuxGridAuthority: "claim_tmux_grid_authority"
        case .reclaimTmuxGridAuthority: "reclaim_tmux_grid_authority"
        case .completeTmuxGridAuthorityRepaint: "complete_tmux_grid_authority_repaint"
        case .setFocused: "set_focused"
        case .setApplicationVisibility: "set_application_visibility"
        case .requestFullRepaint: "request_full_repaint"
        case .submitChallengeResponse: "submit_challenge_response"
        case .destroy: "destroy"
        }
    }
}

public struct SessionBackendPorts: Sendable {
    public typealias OperationSink = @Sendable (SessionBackendOperation) throws -> Void
    public let perform: OperationSink

    public init(perform: @escaping OperationSink) {
        self.perform = perform
    }
}

/// Optional provenance for a transport chunk whose producer exposes an
/// absolute delivery sequence. Mosh uses this to order a forced framebuffer
/// behind the final terminal consumer; SSH leaves it nil.
public struct TerminalOutputReceipt: Codable, Equatable, Sendable {
    /// Receipt identifiers cross the Swift/Kotlin boundary. Kotlin exposes
    /// them as signed `Long`, so the shared contract deliberately stops at
    /// `Int64.max` instead of accepting values Android could only drop.
    public static let maximumIdentifier = UInt64(Int64.max)

    public let deliveryID: UInt64
    public let repaintRequestID: UInt64?

    public init(deliveryID: UInt64, repaintRequestID: UInt64? = nil) {
        precondition(Self.isValidIdentifier(deliveryID))
        precondition(repaintRequestID.map(Self.isValidIdentifier) ?? true)
        self.deliveryID = deliveryID
        self.repaintRequestID = repaintRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case deliveryID
        case repaintRequestID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let deliveryID = try container.decode(UInt64.self, forKey: .deliveryID)
        let repaintRequestID = try container.decodeIfPresent(UInt64.self, forKey: .repaintRequestID)
        guard Self.isValidIdentifier(deliveryID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .deliveryID,
                in: container,
                debugDescription: "deliveryID must be in 1...Int64.max"
            )
        }
        if let repaintRequestID, !Self.isValidIdentifier(repaintRequestID) {
            throw DecodingError.dataCorruptedError(
                forKey: .repaintRequestID,
                in: container,
                debugDescription: "repaintRequestID must be in 1...Int64.max"
            )
        }
        self.deliveryID = deliveryID
        self.repaintRequestID = repaintRequestID
    }

    private static func isValidIdentifier(_ value: UInt64) -> Bool {
        value > 0 && value <= maximumIdentifier
    }
}

public enum SessionEvent: Equatable, Sendable {
    case stateChanged(generation: SessionGeneration, state: SharedSessionState)
    case terminalBytes(
        generation: SessionGeneration,
        bytes: Data,
        receipt: TerminalOutputReceipt? = nil
    )
    case tmuxSnapshotChanged(generation: SessionGeneration, snapshot: TmuxSnapshot)
    case gridAuthorityChanged(generation: SessionGeneration, snapshot: GridAuthoritySnapshot)
    case challenge(generation: SessionGeneration, challenge: SessionChallenge)
    case remoteWorkingDirectoryChanged(generation: SessionGeneration, path: String?)
    case forwardingStateChanged(generation: SessionGeneration, states: [ForwardingState])
    case recoverableWarning(generation: SessionGeneration, warning: CoreFailure)
    case failure(generation: SessionGeneration, failure: CoreFailure)
    case diagnostics(generation: SessionGeneration, event: DiagnosticEvent)
    case commandCompleted(
        generation: SessionGeneration,
        receipt: SessionCommandReceipt,
        result: SessionCommandResult
    )
    case destroyed(generation: SessionGeneration)
}

/// The session boundary deliberately re-exports the single immutable tmux
/// model owned by `TmuxControlCore`; adapters must not maintain a parallel DTO.
public typealias GridAuthoritySnapshot = TmuxGridAuthoritySnapshot

public struct ForwardingState: Codable, Equatable, Sendable {
    public let ruleID: UUID
    public let state: String

    public init(ruleID: UUID, state: String) {
        self.ruleID = ruleID
        self.state = state
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let code: String
    public let values: [String: String]

    public init(code: String, values: [String: String] = [:]) {
        self.code = code
        self.values = values
    }
}
