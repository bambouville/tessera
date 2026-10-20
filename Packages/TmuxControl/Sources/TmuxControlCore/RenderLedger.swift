import Foundation

public struct SurfaceId: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let live = SurfaceId("live")
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RenderProfile: String, Codable, Equatable, Sendable {
    case inline
    case sideChannel
}

public enum RenderStage: String, Codable, Equatable, Sendable {
    case viewport
    case viewportOnly
    case deep
}

public enum CaptureBodyPolicy: String, Codable, Equatable, Sendable {
    case requiredGrid
    case optionalSupplement
}

public enum SurfacePresentation: String, Codable, Equatable, Sendable {
    case single
    case grid
    case overlay
}

public struct SurfaceDeclaration: Equatable, Sendable, Codable {
    public let surfaceID: SurfaceId
    public let presentation: SurfacePresentation
    public let windowID: WindowId?
    public let paneID: PaneId?

    public init(
        surfaceID: SurfaceId,
        presentation: SurfacePresentation,
        windowID: WindowId? = nil,
        paneID: PaneId? = nil
    ) {
        self.surfaceID = surfaceID
        self.presentation = presentation
        self.windowID = windowID
        self.paneID = paneID
    }

    private enum CodingKeys: String, CodingKey {
        case surfaceID, presentation, windowID, paneID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaceID = try container.decode(SurfaceId.self, forKey: .surfaceID)
        presentation = try container.decode(SurfacePresentation.self, forKey: .presentation)
        windowID = try container.decodeIfPresent(Int.self, forKey: .windowID).map(WindowId.init)
        paneID = try container.decodeIfPresent(Int.self, forKey: .paneID).map(PaneId.init)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(surfaceID, forKey: .surfaceID)
        try container.encode(presentation, forKey: .presentation)
        try container.encodeIfPresent(windowID?.rawValue, forKey: .windowID)
        try container.encodeIfPresent(paneID?.rawValue, forKey: .paneID)
    }
}

public struct RenderOwner: Hashable, Sendable, Codable, CustomStringConvertible {
    public let windowID: WindowId?
    public let paneID: PaneId?
    public let epoch: UInt64

    public init(windowID: WindowId?, paneID: PaneId?, epoch: UInt64) {
        self.windowID = windowID
        self.paneID = paneID
        self.epoch = epoch
    }

    public var description: String {
        "\(windowID?.description ?? "none")/\(paneID?.description ?? "none")#\(epoch)"
    }

    private enum CodingKeys: String, CodingKey { case windowID, paneID, epoch }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try container.decodeIfPresent(Int.self, forKey: .windowID).map(WindowId.init)
        paneID = try container.decodeIfPresent(Int.self, forKey: .paneID).map(PaneId.init)
        epoch = try container.decode(UInt64.self, forKey: .epoch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(windowID?.rawValue, forKey: .windowID)
        try container.encodeIfPresent(paneID?.rawValue, forKey: .paneID)
        try container.encode(epoch, forKey: .epoch)
    }
}

public struct RenderBytesRef: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public init(_ rawValue: UInt64) { self.rawValue = rawValue }

    private enum CodingKeys: String, CodingKey { case id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(UInt64.self, forKey: .id))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawValue, forKey: .id)
    }
}

public enum RenderFeedSource: String, Codable, Equatable, Sendable {
    case paneOutput = "pane-output"
    case viewportRepaint = "tmux-repaint-viewport"
    case viewportRefresh = "tmux-repaint-viewport-refresh"
    case deepRepaint = "tmux-repaint-deep"
    case repaintScrub = "tmux-repaint-scrub"
    case foregroundReplay = "foreground-replay"
    case moshHistory = "mosh-history"
}

public enum RenderMouseMode: String, Codable, Equatable, Sendable {
    case off
    case tracking
}

public enum RenderHistoryPlacement: String, Codable, Equatable, Sendable {
    case bottom
    case preserveDistanceFromBottom
}

public enum RenderEffect: Equatable, Sendable, Codable {
    case sendCommand(String)
    case commandReply(tag: UInt64, success: Bool, lines: [String], parts: [RenderCommandResult] = [])
    case bindSurface(SurfaceId, owner: RenderOwner)
    case feed(SurfaceId, owner: RenderOwner, bytes: RenderBytesRef, source: RenderFeedSource)
    case saveWindowModes(SurfaceId, window: WindowId)
    case restoreWindowModes(SurfaceId, window: WindowId, paneInAltScreen: Bool)
    case resolveSurfaceState(SurfaceId, request: UInt64)
    case armTimer(token: UInt64, milliseconds: Int)
    case cancelTimer(token: UInt64)
    case initialRenderReady
    case requestTransportFullFrame
    case historyReady(
        SurfaceId,
        owner: RenderOwner,
        depth: Int,
        historySize: Int,
        placement: RenderHistoryPlacement
    )
    /// Terminal state of an inline (SSH+tmux) history capture. It follows
    /// every inline `.deep` feed it describes, and it also answers a
    /// `scrollbackRequested` / `findOpened` fact the ledger did not act on, so
    /// a platform gesture always receives exactly one settling signal.
    /// `depth` is the credited capture depth in history rows; `canDeepen`
    /// says whether a later `scrollbackRequested` can still fetch older rows.
    case inlineHistorySettled(
        SurfaceId,
        owner: RenderOwner,
        depth: Int,
        historySize: Int,
        canDeepen: Bool
    )
    /// Exact completion marker for a platform-correlated authoritative
    /// refresh. It follows every feed and mode-restore effect belonging to
    /// the refresh, so an executor can require that the complete frame was
    /// admitted before advancing a separate lifecycle transaction.
    case refreshCompleted(
        SurfaceId,
        owner: RenderOwner,
        stage: RenderStage,
        correlation: UInt64
    )
    /// Terminal rejection for a platform-correlated authoritative refresh.
    /// Every accepted correlated request produces exactly one completion or
    /// failure, including when lifecycle or topology supersedes the capture.
    case refreshFailed(
        SurfaceId,
        correlation: UInt64,
        reason: String
    )
    /// Ask the platform for one transport-painted full frame belonging to
    /// `correlation`, tagged to `owner`.
    ///
    /// Unlike an inline refresh the ledger cannot produce these bytes: on the
    /// side channel the visible screen is painted by mosh, outside the control
    /// connection. The ledger still owns the *reservation*, so a rebind of the
    /// surface re-emits this effect under the same correlation rather than
    /// stranding or failing the transaction waiting on it.
    ///
    /// `owner` is nil before the surface's first bind. That is admissible: the
    /// initial-attach claim deliberately runs ahead of the first bind, and a
    /// quiet session never binds until something prints.
    case requestCorrelatedTransportFullFrame(
        SurfaceId,
        owner: RenderOwner?,
        correlation: UInt64,
        reason: String
    )
    /// The reserved transport frame was rendered by the owner it was tagged
    /// to. Exactly one of this or `transportFullFrameFailed` follows every
    /// accepted reservation.
    case transportFullFrameCompleted(
        SurfaceId,
        owner: RenderOwner?,
        correlation: UInt64
    )
    case transportFullFrameFailed(
        SurfaceId,
        correlation: UInt64,
        reason: String
    )
    case diagnostic(String)

    private enum CodingKeys: String, CodingKey {
        case kind, command, tag, success, lines, parts, surfaceID, owner, bytesRef, source
        case windowID, paneInAltScreen, request, token, milliseconds, depth
        case historySize, placement, stage, correlation, reason, message
        case canDeepen
    }

    private enum Kind: String, Codable {
        case sendCommand, commandReply, bindSurface, feed, saveWindowModes
        case restoreWindowModes, resolveSurfaceState, armTimer, cancelTimer
        case initialRenderReady, requestTransportFullFrame, historyReady
        case inlineHistorySettled
        case refreshCompleted, refreshFailed, diagnostic
        case requestCorrelatedTransportFullFrame
        case transportFullFrameCompleted, transportFullFrameFailed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .sendCommand:
            self = .sendCommand(try container.decode(String.self, forKey: .command))
        case .commandReply:
            self = .commandReply(
                tag: try container.decode(UInt64.self, forKey: .tag),
                success: try container.decode(Bool.self, forKey: .success),
                lines: try container.decode([String].self, forKey: .lines),
                parts: try container.decodeIfPresent([RenderCommandResult].self, forKey: .parts) ?? []
            )
        case .bindSurface:
            self = .bindSurface(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner)
            )
        case .feed:
            self = .feed(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner),
                bytes: try container.decode(RenderBytesRef.self, forKey: .bytesRef),
                source: try container.decode(RenderFeedSource.self, forKey: .source)
            )
        case .saveWindowModes:
            self = .saveWindowModes(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                window: WindowId(try container.decode(Int.self, forKey: .windowID))
            )
        case .restoreWindowModes:
            self = .restoreWindowModes(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                window: WindowId(try container.decode(Int.self, forKey: .windowID)),
                paneInAltScreen: try container.decode(Bool.self, forKey: .paneInAltScreen)
            )
        case .resolveSurfaceState:
            self = .resolveSurfaceState(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                request: try container.decode(UInt64.self, forKey: .request)
            )
        case .armTimer:
            self = .armTimer(
                token: try container.decode(UInt64.self, forKey: .token),
                milliseconds: try container.decode(Int.self, forKey: .milliseconds)
            )
        case .cancelTimer:
            self = .cancelTimer(token: try container.decode(UInt64.self, forKey: .token))
        case .initialRenderReady:
            self = .initialRenderReady
        case .requestTransportFullFrame:
            self = .requestTransportFullFrame
        case .historyReady:
            self = .historyReady(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner),
                depth: try container.decode(Int.self, forKey: .depth),
                historySize: try container.decode(Int.self, forKey: .historySize),
                placement: try container.decode(RenderHistoryPlacement.self, forKey: .placement)
            )
        case .inlineHistorySettled:
            self = .inlineHistorySettled(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner),
                depth: try container.decode(Int.self, forKey: .depth),
                historySize: try container.decode(Int.self, forKey: .historySize),
                canDeepen: try container.decode(Bool.self, forKey: .canDeepen)
            )
        case .refreshCompleted:
            self = .refreshCompleted(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner),
                stage: try container.decode(RenderStage.self, forKey: .stage),
                correlation: try container.decode(UInt64.self, forKey: .correlation)
            )
        case .refreshFailed:
            self = .refreshFailed(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                correlation: try container.decode(UInt64.self, forKey: .correlation),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .requestCorrelatedTransportFullFrame:
            self = .requestCorrelatedTransportFullFrame(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decodeIfPresent(RenderOwner.self, forKey: .owner),
                correlation: try container.decode(UInt64.self, forKey: .correlation),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .transportFullFrameCompleted:
            self = .transportFullFrameCompleted(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decodeIfPresent(RenderOwner.self, forKey: .owner),
                correlation: try container.decode(UInt64.self, forKey: .correlation)
            )
        case .transportFullFrameFailed:
            self = .transportFullFrameFailed(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                correlation: try container.decode(UInt64.self, forKey: .correlation),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .diagnostic:
            self = .diagnostic(try container.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sendCommand(let command):
            try container.encode(Kind.sendCommand, forKey: .kind)
            try container.encode(command, forKey: .command)
        case .commandReply(let tag, let success, let lines, let parts):
            try container.encode(Kind.commandReply, forKey: .kind)
            try container.encode(tag, forKey: .tag)
            try container.encode(success, forKey: .success)
            try container.encode(lines, forKey: .lines)
            if !parts.isEmpty { try container.encode(parts, forKey: .parts) }
        case .bindSurface(let surfaceID, let owner):
            try container.encode(Kind.bindSurface, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
        case .feed(let surfaceID, let owner, let bytes, let source):
            try container.encode(Kind.feed, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
            try container.encode(bytes, forKey: .bytesRef)
            try container.encode(source, forKey: .source)
        case .saveWindowModes(let surfaceID, let window):
            try container.encode(Kind.saveWindowModes, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(window.rawValue, forKey: .windowID)
        case .restoreWindowModes(let surfaceID, let window, let paneInAltScreen):
            try container.encode(Kind.restoreWindowModes, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(window.rawValue, forKey: .windowID)
            try container.encode(paneInAltScreen, forKey: .paneInAltScreen)
        case .resolveSurfaceState(let surfaceID, let request):
            try container.encode(Kind.resolveSurfaceState, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(request, forKey: .request)
        case .armTimer(let token, let milliseconds):
            try container.encode(Kind.armTimer, forKey: .kind)
            try container.encode(token, forKey: .token)
            try container.encode(milliseconds, forKey: .milliseconds)
        case .cancelTimer(let token):
            try container.encode(Kind.cancelTimer, forKey: .kind)
            try container.encode(token, forKey: .token)
        case .initialRenderReady:
            try container.encode(Kind.initialRenderReady, forKey: .kind)
        case .requestTransportFullFrame:
            try container.encode(Kind.requestTransportFullFrame, forKey: .kind)
        case .historyReady(let surfaceID, let owner, let depth, let historySize, let placement):
            try container.encode(Kind.historyReady, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
            try container.encode(depth, forKey: .depth)
            try container.encode(historySize, forKey: .historySize)
            try container.encode(placement, forKey: .placement)
        case .inlineHistorySettled(let surfaceID, let owner, let depth, let historySize, let canDeepen):
            try container.encode(Kind.inlineHistorySettled, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
            try container.encode(depth, forKey: .depth)
            try container.encode(historySize, forKey: .historySize)
            try container.encode(canDeepen, forKey: .canDeepen)
        case .refreshCompleted(let surfaceID, let owner, let stage, let correlation):
            try container.encode(Kind.refreshCompleted, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
            try container.encode(stage, forKey: .stage)
            try container.encode(correlation, forKey: .correlation)
        case .refreshFailed(let surfaceID, let correlation, let reason):
            try container.encode(Kind.refreshFailed, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(correlation, forKey: .correlation)
            try container.encode(reason, forKey: .reason)
        case .requestCorrelatedTransportFullFrame(let surfaceID, let owner, let correlation, let reason):
            try container.encode(Kind.requestCorrelatedTransportFullFrame, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encodeIfPresent(owner, forKey: .owner)
            try container.encode(correlation, forKey: .correlation)
            try container.encode(reason, forKey: .reason)
        case .transportFullFrameCompleted(let surfaceID, let owner, let correlation):
            try container.encode(Kind.transportFullFrameCompleted, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encodeIfPresent(owner, forKey: .owner)
            try container.encode(correlation, forKey: .correlation)
        case .transportFullFrameFailed(let surfaceID, let correlation, let reason):
            try container.encode(Kind.transportFullFrameFailed, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(correlation, forKey: .correlation)
            try container.encode(reason, forKey: .reason)
        case .diagnostic(let message):
            try container.encode(Kind.diagnostic, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

public enum RenderFact: Equatable, Sendable, Codable {
    case transportAttached(RenderProfile)
    case transportLost
    case programStatusPaneOutput(enabled: Bool)
    case surfacesDeclared([SurfaceDeclaration])
    case clientSize(columns: Int, rows: Int)
    /// Nonempty natural output from the whole-window Mosh painter. The
    /// adapter excludes forced frame replays and unproven identity handoffs.
    /// The exact source owner (the painter's, or a pane reader's in the same
    /// window) prevents delayed activity from freezing another window's
    /// history; the reducer owns which history surfaces it affects.
    case transportOutputObserved(SurfaceId, owner: RenderOwner)
    case surfaceState(
        SurfaceId,
        request: UInt64,
        altScreen: Bool,
        mouseMode: RenderMouseMode,
        columns: Int,
        rows: Int
    )
    case appForeground
    case appBackground
    case timerFired(token: UInt64)
    case scrollbackRequested(SurfaceId, pointsY: Double, isInertial: Bool)
    case scrollbackReturnedToTail(SurfaceId)
    /// Confirms that the platform admitted and presented the exact staged
    /// Mosh history payload. `historyReady` alone is not presentation: an
    /// adapter may still be waiting on a painter receipt or a mounted view.
    case historyPresented(SurfaceId, owner: RenderOwner)
    /// The adapter could not present the staged bytes because their physical
    /// surface or owner disappeared. This exact-owner failure releases the
    /// staged latch without treating stale callbacks as current work.
    case historyPresentationFailed(SurfaceId, owner: RenderOwner)
    case findOpened(SurfaceId)
    case userInput
    case scrollbackLimit(lines: Int)
    case refreshRequested(SurfaceId, stage: RenderStage, reason: String)
    case correlatedRefreshRequested(
        SurfaceId,
        stage: RenderStage,
        reason: String,
        correlation: UInt64
    )
    /// Reserve one transport-painted full frame under `correlation`. The
    /// side-channel analogue of `correlatedRefreshRequested`: the ledger owns
    /// the reservation and re-issues it across its own surface rebinds, but
    /// the bytes come from the transport rather than from a capture.
    case correlatedTransportFullFrameRequested(
        SurfaceId,
        reason: String,
        correlation: UInt64
    )
    /// The reserved transport frame was rendered by `owner`. Like
    /// `historyPresented`, this is an acceptance by a mounted surface, not an
    /// acknowledgement that the driver was asked: enqueueing the operation is
    /// never evidence that the frame reached the screen.
    case transportFullFramePresented(
        SurfaceId,
        owner: RenderOwner?,
        correlation: UInt64
    )
    case transportFullFramePresentationFailed(
        SurfaceId,
        owner: RenderOwner?,
        correlation: UInt64,
        reason: String
    )
    case reorderBegan(token: UInt64, order: [WindowId])
    case reorderConfirmed(token: UInt64)
    case reorderAbandoned(token: UInt64)
    case unwrittenCommandsCancelled(tags: [UInt64])
    case orderRefreshCompleted(succeeded: Bool)

    private enum CodingKeys: String, CodingKey {
        case version, kind, profile, surfaces, columns, rows, surfaceID, request
        case altScreen, mouseMode, token, pointsY, isInertial, lines, stage, reason
        case correlation, owner, order, succeeded, tags, enabled
    }

    private enum Kind: String, Codable {
        case transportAttached, transportLost, surfacesDeclared, clientSize, surfaceState
        case transportOutputObserved, programStatusPaneOutput
        case appForeground, appBackground, timerFired, scrollbackRequested
        case scrollbackReturnedToTail, historyPresented, historyPresentationFailed
        case findOpened, userInput, scrollbackLimit
        case refreshRequested, correlatedRefreshRequested
        case correlatedTransportFullFrameRequested
        case transportFullFramePresented, transportFullFramePresentationFailed
        case reorderBegan, reorderConfirmed, reorderAbandoned, orderRefreshCompleted, unwrittenCommandsCancelled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "unsupported render fact version"
            )
        }
        switch try container.decode(Kind.self, forKey: .kind) {
        case .transportAttached:
            self = .transportAttached(try container.decode(RenderProfile.self, forKey: .profile))
        case .transportLost:
            self = .transportLost
        case .programStatusPaneOutput:
            self = .programStatusPaneOutput(enabled: try container.decode(Bool.self, forKey: .enabled))
        case .surfacesDeclared:
            self = .surfacesDeclared(try container.decode([SurfaceDeclaration].self, forKey: .surfaces))
        case .clientSize:
            self = .clientSize(
                columns: try container.decode(Int.self, forKey: .columns),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .transportOutputObserved:
            self = .transportOutputObserved(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner)
            )
        case .surfaceState:
            self = .surfaceState(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                request: try container.decode(UInt64.self, forKey: .request),
                altScreen: try container.decode(Bool.self, forKey: .altScreen),
                mouseMode: try container.decode(RenderMouseMode.self, forKey: .mouseMode),
                columns: try container.decode(Int.self, forKey: .columns),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .appForeground:
            self = .appForeground
        case .appBackground:
            self = .appBackground
        case .timerFired:
            self = .timerFired(token: try container.decode(UInt64.self, forKey: .token))
        case .scrollbackRequested:
            self = .scrollbackRequested(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                pointsY: try container.decode(Double.self, forKey: .pointsY),
                isInertial: try container.decode(Bool.self, forKey: .isInertial)
            )
        case .scrollbackReturnedToTail:
            self = .scrollbackReturnedToTail(try container.decode(SurfaceId.self, forKey: .surfaceID))
        case .historyPresented:
            self = .historyPresented(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner)
            )
        case .historyPresentationFailed:
            self = .historyPresentationFailed(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decode(RenderOwner.self, forKey: .owner)
            )
        case .findOpened:
            self = .findOpened(try container.decode(SurfaceId.self, forKey: .surfaceID))
        case .userInput:
            self = .userInput
        case .scrollbackLimit:
            self = .scrollbackLimit(lines: try container.decode(Int.self, forKey: .lines))
        case .refreshRequested:
            self = .refreshRequested(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                stage: try container.decode(RenderStage.self, forKey: .stage),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .correlatedRefreshRequested:
            self = .correlatedRefreshRequested(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                stage: try container.decode(RenderStage.self, forKey: .stage),
                reason: try container.decode(String.self, forKey: .reason),
                correlation: try container.decode(UInt64.self, forKey: .correlation)
            )
        case .correlatedTransportFullFrameRequested:
            self = .correlatedTransportFullFrameRequested(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                reason: try container.decode(String.self, forKey: .reason),
                correlation: try container.decode(UInt64.self, forKey: .correlation)
            )
        case .transportFullFramePresented:
            self = .transportFullFramePresented(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decodeIfPresent(RenderOwner.self, forKey: .owner),
                correlation: try container.decode(UInt64.self, forKey: .correlation)
            )
        case .transportFullFramePresentationFailed:
            self = .transportFullFramePresentationFailed(
                try container.decode(SurfaceId.self, forKey: .surfaceID),
                owner: try container.decodeIfPresent(RenderOwner.self, forKey: .owner),
                correlation: try container.decode(UInt64.self, forKey: .correlation),
                reason: try container.decode(String.self, forKey: .reason)
            )
        case .reorderBegan:
            self = .reorderBegan(
                token: try container.decode(UInt64.self, forKey: .token),
                order: try container.decode([WindowId].self, forKey: .order)
            )
        case .reorderConfirmed:
            self = .reorderConfirmed(token: try container.decode(UInt64.self, forKey: .token))
        case .reorderAbandoned:
            self = .reorderAbandoned(token: try container.decode(UInt64.self, forKey: .token))
        case .unwrittenCommandsCancelled:
            self = .unwrittenCommandsCancelled(tags: try container.decode([UInt64].self, forKey: .tags))
        case .orderRefreshCompleted:
            self = .orderRefreshCompleted(
                succeeded: try container.decode(Bool.self, forKey: .succeeded)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        switch self {
        case .transportAttached(let profile):
            try container.encode(Kind.transportAttached, forKey: .kind)
            try container.encode(profile, forKey: .profile)
        case .transportLost:
            try container.encode(Kind.transportLost, forKey: .kind)
        case .programStatusPaneOutput(let enabled):
            try container.encode(Kind.programStatusPaneOutput, forKey: .kind)
            try container.encode(enabled, forKey: .enabled)
        case .surfacesDeclared(let surfaces):
            try container.encode(Kind.surfacesDeclared, forKey: .kind)
            try container.encode(surfaces, forKey: .surfaces)
        case .clientSize(let columns, let rows):
            try container.encode(Kind.clientSize, forKey: .kind)
            try container.encode(columns, forKey: .columns)
            try container.encode(rows, forKey: .rows)
        case .transportOutputObserved(let surfaceID, let owner):
            try container.encode(Kind.transportOutputObserved, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
        case .surfaceState(let surfaceID, let request, let altScreen, let mouseMode, let columns, let rows):
            try container.encode(Kind.surfaceState, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(request, forKey: .request)
            try container.encode(altScreen, forKey: .altScreen)
            try container.encode(mouseMode, forKey: .mouseMode)
            try container.encode(columns, forKey: .columns)
            try container.encode(rows, forKey: .rows)
        case .appForeground:
            try container.encode(Kind.appForeground, forKey: .kind)
        case .appBackground:
            try container.encode(Kind.appBackground, forKey: .kind)
        case .timerFired(let token):
            try container.encode(Kind.timerFired, forKey: .kind)
            try container.encode(token, forKey: .token)
        case .scrollbackRequested(let surfaceID, let pointsY, let isInertial):
            try container.encode(Kind.scrollbackRequested, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(pointsY, forKey: .pointsY)
            try container.encode(isInertial, forKey: .isInertial)
        case .scrollbackReturnedToTail(let surfaceID):
            try container.encode(Kind.scrollbackReturnedToTail, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
        case .historyPresented(let surfaceID, let owner):
            try container.encode(Kind.historyPresented, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
        case .historyPresentationFailed(let surfaceID, let owner):
            try container.encode(Kind.historyPresentationFailed, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(owner, forKey: .owner)
        case .findOpened(let surfaceID):
            try container.encode(Kind.findOpened, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
        case .userInput:
            try container.encode(Kind.userInput, forKey: .kind)
        case .scrollbackLimit(let lines):
            try container.encode(Kind.scrollbackLimit, forKey: .kind)
            try container.encode(lines, forKey: .lines)
        case .refreshRequested(let surfaceID, let stage, let reason):
            try container.encode(Kind.refreshRequested, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(stage, forKey: .stage)
            try container.encode(reason, forKey: .reason)
        case .correlatedRefreshRequested(let surfaceID, let stage, let reason, let correlation):
            try container.encode(Kind.correlatedRefreshRequested, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(stage, forKey: .stage)
            try container.encode(reason, forKey: .reason)
            try container.encode(correlation, forKey: .correlation)
        case .correlatedTransportFullFrameRequested(let surfaceID, let reason, let correlation):
            try container.encode(Kind.correlatedTransportFullFrameRequested, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encode(reason, forKey: .reason)
            try container.encode(correlation, forKey: .correlation)
        case .transportFullFramePresented(let surfaceID, let owner, let correlation):
            try container.encode(Kind.transportFullFramePresented, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encodeIfPresent(owner, forKey: .owner)
            try container.encode(correlation, forKey: .correlation)
        case .transportFullFramePresentationFailed(let surfaceID, let owner, let correlation, let reason):
            try container.encode(Kind.transportFullFramePresentationFailed, forKey: .kind)
            try container.encode(surfaceID, forKey: .surfaceID)
            try container.encodeIfPresent(owner, forKey: .owner)
            try container.encode(correlation, forKey: .correlation)
            try container.encode(reason, forKey: .reason)
        case .reorderBegan(let token, let order):
            try container.encode(Kind.reorderBegan, forKey: .kind)
            try container.encode(token, forKey: .token)
            try container.encode(order, forKey: .order)
        case .reorderConfirmed(let token):
            try container.encode(Kind.reorderConfirmed, forKey: .kind)
            try container.encode(token, forKey: .token)
        case .reorderAbandoned(let token):
            try container.encode(Kind.reorderAbandoned, forKey: .kind)
            try container.encode(token, forKey: .token)
        case .unwrittenCommandsCancelled(let tags):
            try container.encode(Kind.unwrittenCommandsCancelled, forKey: .kind)
            try container.encode(tags, forKey: .tags)
        case .orderRefreshCompleted(let succeeded):
            try container.encode(Kind.orderRefreshCompleted, forKey: .kind)
            try container.encode(succeeded, forKey: .succeeded)
        }
    }
}

/// Pure owner/staging reducer shared by Apple and Android tmux clients.
public struct TmuxRenderLedger: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var deepHistoryDepth: Int
        public var moshPageDepth: Int
        public var scrollbackLimit: Int
        public var commandQueueWaitMilliseconds: Int
        public var commandQueuePollMilliseconds: Int
        public var renderRetryMilliseconds: Int
        public var initialRenderWatchdogMilliseconds: Int
        public var sideChannelWatchdogMilliseconds: Int
        public var maximumSizeResyncAttempts: Int
        /// How often, and for how long, a finished inline capture waits for
        /// its surface to reach the pane's grid (see `awaitSurfaceGrid`).
        public var surfaceGridPollMilliseconds: Int
        public var surfaceGridWaitMilliseconds: Int
        public var maximumViewportRetryAttempts: Int
        public var maximumDeepRetryAttempts: Int
        public var maximumFifoResyncAttempts: Int
        public var maximumForegroundOutputBytes: Int
        public var maximumRenderBytes: Int
        public var inlineClientSizeReplayBelongsToClaim: Bool
        /// P6: send `refresh-client -C` only when the grid differs from the
        /// one this connection last advertised (see `advertisedClientSize`).
        /// Off by default so an adapter opts in once its own replays route
        /// every `-C` through the ledger or report it through
        /// `noteAppliedClientSize` (which makes the next replay send again).
        public var suppressesUnchangedClientSizeReplay: Bool
        /// P8: a take-back's visible-rows refresh (a correlated one, or any
        /// while a peer holds the grid) sends its capture in the same burst
        /// as its metadata query (the viewport capture does not depend on
        /// the metadata, unlike a deep one), and a correlated refresh is
        /// queued behind whatever its adapter already sent instead of
        /// waiting for the FIFO to drain: ordering it behind its own fence
        /// is the point. Ordinary owner refreshes keep their two-step
        /// sequence. Off by default; an adapter opts in.
        public var pipelinesVisibleCapture: Bool

        public init(
            deepHistoryDepth: Int = 2_000,
            moshPageDepth: Int = 240,
            scrollbackLimit: Int = 10_000,
            commandQueueWaitMilliseconds: Int = 250,
            commandQueuePollMilliseconds: Int = 20,
            renderRetryMilliseconds: Int = 500,
            initialRenderWatchdogMilliseconds: Int = 4_000,
            sideChannelWatchdogMilliseconds: Int = 4_000,
            maximumSizeResyncAttempts: Int = 3,
            // Covers the terminal's resize settle (0.12 s on iOS) and the
            // layout pass before it, with room for an animated relayout.
            surfaceGridPollMilliseconds: Int = 40,
            surfaceGridWaitMilliseconds: Int = 400,
            maximumViewportRetryAttempts: Int = 8,
            maximumDeepRetryAttempts: Int = 1,
            maximumFifoResyncAttempts: Int = 4,
            maximumForegroundOutputBytes: Int = 64 * 1_024,
            // A dense 10 000-line `capture-pane -p -e -N` of a wide pane
            // weighs 470-680 KB, so the former 1 MiB ceiling sat exactly at
            // the size of a full-depth inline history capture and would have
            // turned the deepest rung of the ladder into a dropped frame.
            maximumRenderBytes: Int = 8_388_608,
            inlineClientSizeReplayBelongsToClaim: Bool = false,
            suppressesUnchangedClientSizeReplay: Bool = false,
            pipelinesVisibleCapture: Bool = false
        ) {
            self.deepHistoryDepth = max(0, deepHistoryDepth)
            self.moshPageDepth = max(1, moshPageDepth)
            self.scrollbackLimit = max(0, scrollbackLimit)
            self.commandQueueWaitMilliseconds = max(0, commandQueueWaitMilliseconds)
            self.commandQueuePollMilliseconds = max(1, commandQueuePollMilliseconds)
            self.renderRetryMilliseconds = max(0, renderRetryMilliseconds)
            self.initialRenderWatchdogMilliseconds = max(0, initialRenderWatchdogMilliseconds)
            self.sideChannelWatchdogMilliseconds = max(0, sideChannelWatchdogMilliseconds)
            self.maximumSizeResyncAttempts = max(0, maximumSizeResyncAttempts)
            self.surfaceGridPollMilliseconds = max(1, surfaceGridPollMilliseconds)
            self.surfaceGridWaitMilliseconds = max(0, surfaceGridWaitMilliseconds)
            self.maximumViewportRetryAttempts = max(0, maximumViewportRetryAttempts)
            self.maximumDeepRetryAttempts = max(0, maximumDeepRetryAttempts)
            self.maximumFifoResyncAttempts = max(0, maximumFifoResyncAttempts)
            self.maximumForegroundOutputBytes = max(0, maximumForegroundOutputBytes)
            self.maximumRenderBytes = max(1, maximumRenderBytes)
            self.inlineClientSizeReplayBelongsToClaim = inlineClientSizeReplayBelongsToClaim
            self.suppressesUnchangedClientSizeReplay = suppressesUnchangedClientSizeReplay
            self.pipelinesVisibleCapture = pipelinesVisibleCapture
        }
    }

    private enum CapturePhase: Sendable {
        case waitingForQueue(attempts: Int)
        case metadata
        case viewport
        case deepPrimary
        case settledPrimaryMetadata
        case settledPrimaryViewport
        case deepAltHistory
        case savedPrimary
        case settledAltMetadata
        case settledAltViewport
        case awaitingSurfaceState(request: UInt64)
        case moshMetadata(depth: Int, placement: RenderHistoryPlacement)
        case moshCapture(depth: Int, placement: RenderHistoryPlacement)

        /// Bare case name for diagnostics.
        var evidenceName: String {
            switch self {
            case .waitingForQueue: return "waitingForQueue"
            case .metadata: return "metadata"
            case .viewport: return "viewport"
            case .deepPrimary: return "deepPrimary"
            case .settledPrimaryMetadata: return "settledPrimaryMetadata"
            case .settledPrimaryViewport: return "settledPrimaryViewport"
            case .deepAltHistory: return "deepAltHistory"
            case .savedPrimary: return "savedPrimary"
            case .settledAltMetadata: return "settledAltMetadata"
            case .settledAltViewport: return "settledAltViewport"
            case .awaitingSurfaceState: return "awaitingSurfaceState"
            case .moshMetadata: return "moshMetadata"
            case .moshCapture: return "moshCapture"
            }
        }
    }

    private struct PendingRefresh: Sendable {
        var generation: UInt64
        var owner: RenderOwner
        var stage: RenderStage
        var reason: String
        var completionCorrelation: UInt64?
        var target: String
        var sizeEpoch: UInt64
        var foregroundRecovery: Bool
        var phase: CapturePhase
        /// History rows this capture asks tmux for, when it is not the
        /// default first fill. Nil keeps `inlineHistoryDepth`; a deepen
        /// raises it to `fullInlineDepth`.
        var historyDepth: Int?
        var metadata: TmuxRenderedPaneState?
        var captureLines: [String] = []
        var historyLines: [String] = []
        var savedPrimaryLines: [String] = []
        var altScreenLines: [String]?
        var scrubLines: [String]?
        var sizeResyncAttempts = 0
        /// Surface-state polls spent waiting for the surface's grid to
        /// reach the captured pane's.
        var surfaceGridPolls = 0
        /// `%output` received after the capture reply but before the platform
        /// answers `resolveSurfaceState`. Those bytes are beyond the capture's
        /// FIFO cut and must follow the authoritative frame rather than being
        /// dropped while the UI hop is pending.
        var postCaptureOutput: [UInt8] = []
        var postCaptureOutputOverflowed = false
        /// The viewport capture went out with the metadata query
        /// (`pipelinesVisibleCapture`); the metadata reply must not send it
        /// again.
        var capturePipelined = false
        /// P7: this visible rebuild stands in for a relayout's deep rebuild
        /// that a yielded surface skipped, so it deepens afterwards whatever
        /// the surface's presentation. Ordinary grid-pane refreshes stay at
        /// visible rows; a relayout would have deepened every pane.
        var deepensAfterRebuild = false
        /// Aborted: a retry is armed (or the bounded retries are spent).
        /// The retry re-asks everything, so a reply still owed to this
        /// generation (the other half of a pipelined pair) is dropped: it
        /// must neither paint nor charge the retry budget a second time for
        /// the same failed refresh.
        var aborted = false
    }

    private struct SideChannelCaptureIntent: Sendable {
        let windowID: WindowId
        let paneID: PaneId
        let depth: Int
        let placement: RenderHistoryPlacement

        func matches(windowID: WindowId, paneID: PaneId) -> Bool {
            self.windowID == windowID && self.paneID == paneID
        }
    }

    private struct SideChannelState: Sendable {
        var depth = 0
        /// Remote history count at this page's retained tail. Deepens can
        /// drop newer rows, so their fresh metadata count is not the baseline
        /// for the next anchor alignment.
        var anchorHistorySize = 0
        var hasSynthesizedHistory = false
        var revealed = false
        var frozen = false
        /// `historyReady` has crossed the shared ABI, but the platform has not
        /// yet confirmed that the exact owned bytes reached their surface.
        var pendingPresentationOwner: RenderOwner?
        /// Preserve painter motion observed after staging. The history still
        /// has to be delivered exactly once; presentation then freezes it.
        var outputWhilePresentationPending = false
        var inFlightEpoch: UInt64?
        var watchdogToken: UInt64?
        /// The user's latest capture request, retained from admission through
        /// presentation. Geometry can invalidate several successive capture
        /// generations before any reply returns, so pending/rendered state is
        /// not a durable enough record of the gesture by itself.
        var requestedIntent: SideChannelCaptureIntent?
        /// The history rows of the capture last delivered, while it holds
        /// only part of the pane's history. See `SideChannelHistoryAnchor`.
        var historyAnchor: SideChannelHistoryAnchor?
    }

    /// Rows that preserve a revealed point-in-time page while reading deeper.
    ///
    /// A deeper capture replaces the reader's page and is placed at the
    /// reader's distance from its end. Output that scrolled rows into tmux
    /// history since the page was captured would shift every row by that
    /// many, even when SSP carries no visible change. Rows in tmux history
    /// never change, though: the page's history rows appear again in the
    /// deeper capture, and whatever follows them beyond the page's own
    /// tail is newer than the revealed page. Dropping those rows puts every
    /// row the reader sees back at its distance from the end. In-place
    /// redraws (a spinner, a status line) add nothing and drop nothing.
    struct SideChannelHistoryAnchor: Equatable, Sendable {
        /// The rows as text, escape sequences and trailing blanks removed.
        var rows: [String]
        /// Capture rows that followed them: the pane's visible grid.
        var rowsAfter: Int

        static let minimumDistinctText = 3
        /// A first page's whole history (`moshPageDepth`).
        static let maximumRows = 512
        /// The page's newest rows, looked for alone once its oldest ones
        /// have left the deeper capture (trimmed at a small `history-limit`,
        /// or beyond the deepen's depth after a flood of output).
        static let fallbackRows = 64

        struct Alignment: Equatable {
            /// The capture without the rows newer than the page's tail.
            var lines: [String]
            var dropped: Int
            /// Whether the whole page was found, not only its newest rows.
            var wholePage: Bool
        }

        enum AlignmentFailure: String, Error {
            /// The page's rows are no longer in the capture.
            case lost = "frozen-anchor-lost"
            /// Only the page's newest rows were found, more than once.
            case ambiguous = "frozen-anchor-ambiguous"
        }

        /// The history rows of `lines` above its visible grid (the newest
        /// `historyRows`, at most `maximumRows`), or nil when they are too
        /// uniform to find again. The whole page, not just its newest rows:
        /// output that repeats a short block (the same command's output, a
        /// redrawn box) must not match in place of the page.
        init?(captureLines lines: [String], historyRows: Int) {
            let end = min(max(0, historyRows), lines.count)
            let rows = lines[max(0, end - Self.maximumRows)..<end].map(Self.text(of:))
            guard Set(rows.filter { !$0.isEmpty }).count >= Self.minimumDistinctText else { return nil }
            self.rows = rows
            rowsAfter = lines.count - end
        }

        /// `lines` without the rows newer than the anchored page's own tail.
        /// The whole page is looked for first. Where it occurs more than
        /// once (output repeated it verbatim), the shift nearest
        /// `expectedShift`, how much tmux's history grew between the
        /// captures, wins; without a usable estimate, the smallest. Either
        /// copy puts the same text at the reader's distance from the end,
        /// and both are real history. Only then are the page's newest
        /// `fallbackRows` looked for alone, and they must occur once: the
        /// reader may be above them, where another copy's context would
        /// show different rows.
        func aligning(_ lines: [String], expectedShift: Int?) -> Result<Alignment, AlignmentFailure> {
            let expectedEnd = lines.count - rowsAfter
            guard expectedEnd > 0 else { return .failure(.lost) }
            let text = lines[0..<expectedEnd].map(Self.text(of:))
            func aligned(_ shift: Int, wholePage: Bool) -> Result<Alignment, AlignmentFailure> {
                .success(Alignment(lines: Array(lines[0..<(lines.count - shift)]), dropped: shift, wholePage: wholePage))
            }
            let shifts = Self.matchEnds(of: rows, in: text).map { expectedEnd - $0 }
            let nearest: Int?
            if let expectedShift, expectedShift >= 0 {
                nearest = shifts.min { (abs($0 - expectedShift), $0) < (abs($1 - expectedShift), $1) }
            } else {
                nearest = shifts.min()
            }
            if let nearest { return aligned(nearest, wholePage: true) }
            let newest = Array(rows.suffix(Self.fallbackRows))
            guard rows.count > newest.count,
                  Set(newest.filter { !$0.isEmpty }).count >= Self.minimumDistinctText
            else { return .failure(.lost) }
            let newestShifts = Self.matchEnds(of: newest, in: text).map { expectedEnd - $0 }
            guard let shift = newestShifts.first else { return .failure(.lost) }
            guard newestShifts.count == 1 else { return .failure(.ambiguous) }
            return aligned(shift, wholePage: false)
        }

        /// Every index just past an occurrence of `pattern` in `text`, in
        /// linear time however repetitive the rows (Knuth-Morris-Pratt).
        static func matchEnds(of pattern: [String], in text: [String]) -> [Int] {
            guard !pattern.isEmpty, pattern.count <= text.count else { return [] }
            var failure = [Int](repeating: 0, count: pattern.count)
            var matched = 0
            for index in 1..<pattern.count {
                while matched > 0, pattern[index] != pattern[matched] { matched = failure[matched - 1] }
                if pattern[index] == pattern[matched] { matched += 1 }
                failure[index] = matched
            }
            var ends: [Int] = []
            matched = 0
            for (index, row) in text.enumerated() {
                while matched > 0, row != pattern[matched] { matched = failure[matched - 1] }
                if row == pattern[matched] { matched += 1 }
                if matched == pattern.count {
                    ends.append(index + 1)
                    matched = failure[matched - 1]
                }
            }
            return ends
        }

        /// A capture row as text: CSI and OSC sequences and trailing blanks
        /// removed, so the same cells compare equal whatever attributes
        /// `capture-pane -e` carried over from the row above.
        static func text(of line: String) -> String {
            var scalars = String.UnicodeScalarView()
            var iterator = line.unicodeScalars.makeIterator()
            while let scalar = iterator.next() {
                guard scalar == "\u{1B}" else {
                    scalars.append(scalar)
                    continue
                }
                switch iterator.next() {
                case "["?:
                    while let next = iterator.next(), !(0x40...0x7E).contains(next.value) {}
                case "]"?:
                    while let next = iterator.next() {
                        if next == "\u{07}" { break }
                        if next == "\u{1B}" { _ = iterator.next(); break }
                    }
                default:
                    break
                }
            }
            var text = String(scalars)
            while text.last == " " { text.removeLast() }
            return text
        }
    }

    /// Inline (SSH+tmux) local history credited to one surface.
    ///
    /// The mosh side channel has carried a depth ladder in `SideChannelState`
    /// for as long as it has synthesized scrollback; this is the inline
    /// profile's equivalent, expressed against the `.deep` refresh stage so
    /// every repaint invariant is reused rather than duplicated.
    private struct InlineHistoryState: Sendable {
        /// History rows the last completed inline `.deep` capture is credited
        /// with. It is `fullInlineDepth` once a capture demonstrably held the
        /// pane's whole history, so exhaustion is a comparison rather than a
        /// separate flag that a later shallow repaint could contradict.
        var creditedDepth = 0
        /// `history_size` as that capture's metadata reported it.
        var historySize = 0
        /// A later `scrollbackRequested` can still fetch older rows. A surface
        /// that has never settled answers `true`: the first request is then
        /// answered by a capture or by an immediate settle, never by silence.
        var canDeepen = true
        /// A platform gesture is waiting for a settle the ledger could not
        /// answer with a capture of its own — it arrived while a refresh was
        /// already pending, or the refresh that would have answered it was
        /// replaced. Whatever terminates that refresh releases the gesture.
        var deepenRequestedWhilePending = false

        /// The surface now describes a different window/pane, so its credit
        /// says nothing about the new history. The waiting-gesture latch
        /// deliberately survives: a reader that asked for older rows still
        /// needs exactly one answer, whichever pane the surface ends up on.
        mutating func resetForNewIdentity() {
            creditedDepth = 0
            historySize = 0
            canDeepen = true
        }
    }

    private struct SurfaceState: Sendable {
        /// The latest capture spent its retries without painting. Separate
        /// from `pending`: foreground failures retain their ownership cut,
        /// ordinary failures may release it, and an unmounted surface has
        /// not failed a capture at all. A new request clears this verdict.
        var refreshFailedWithoutFrame = false
        var declaration: SurfaceDeclaration
        var owner: RenderOwner?
        /// The last concrete target resolved for this surface. Adapters can
        /// publish a fixed declaration one turn after the wire notification
        /// that changed the active identity, so the global snapshot edge is
        /// not sufficient to decide whether this particular surface moved.
        var lastResolvedWindowID: WindowId?
        var lastResolvedPaneID: PaneId?
        /// Nil until an authoritative capture has described the pane. A
        /// surface first latched by live output must not treat "unknown" as
        /// primary-screen and needlessly promote an in-place alt repair.
        var renderedPaneInAltScreen: Bool?
        var pending: PendingRefresh?
        var retryAttemptsByStage: [RenderStage: Int] = [:]
        var sideChannel = SideChannelState()
        var inlineHistory = InlineHistoryState()
        /// One outstanding transport-painted full frame reserved under a
        /// platform correlation. The ledger keeps this across its own surface
        /// rebinds so a transaction waiting on the frame (an authority claim's
        /// veil) is not aborted by a relayout the transaction itself caused.
        var transportFullFrame: TransportFullFrameReservation?
        /// A surface/pane grid pair that outlasted a whole grid wait. Frames
        /// with the same pair, under the same client size and transport,
        /// paint at once; the surface evidently keeps a different grid
        /// (another client sizes the window, say), and waiting again would
        /// only delay every repaint.
        var persistentGridMismatch: GridMismatch?
        /// P7: the window's layout changed while a peer held the grid, so
        /// what this surface holds no longer matches the pane. Nothing
        /// captures it then (the peer's every keyboard toggle would cost a
        /// 2,000-row capture); the next refresh asked for, normally the
        /// claim's, rebuilds it at visible rows, or the ledger does once the
        /// authority stops naming a peer. A rebuild the app's inactivity
        /// dropped unpainted is owed the same way (`oweDroppedRefresh`).
        var repaintOwedSinceYield = false
        /// P8: a visible-rows rebuild finished while a peer held the grid
        /// (the claim's own repaint, typically). Its history deepening waits
        /// until the authority stops naming a peer, so a 2,000-row capture
        /// never sits in the FIFO ahead of the claim's stamp commit. Also
        /// a deepening the app's inactivity dropped before it ran.
        var deepRebuildOwedSinceYield = false
    }

    private struct GridMismatch: Equatable, Sendable {
        let surfaceColumns: Int?
        let paneColumns: Int?
        let surfaceRows: Int?
        let paneRows: Int?
        let sizeEpoch: UInt64

        var hasDimensions: Bool { surfaceColumns != nil || surfaceRows != nil }
        var matches: Bool { surfaceColumns == paneColumns && surfaceRows == paneRows }
        var evidence: String {
            "columns=\(surfaceColumns.map(String.init) ?? "unknown") paneColumns=\(paneColumns.map(String.init) ?? "unknown")"
                + " rows=\(surfaceRows.map(String.init) ?? "unknown") paneRows=\(paneRows.map(String.init) ?? "unknown")"
        }
    }

    private struct TransportFullFrameReservation: Sendable {
        let correlation: UInt64
        let reason: String
        /// The owner the outstanding request was tagged to. Nil before the
        /// surface's first bind, which is admissible: mosh paints the whole
        /// PTY, so a frame forced before any bind arrives through the untagged
        /// painter feed.
        var owner: RenderOwner?
        /// A held history page reserves the correlation without asking mosh
        /// to clear and redraw that page. Only an issued frame can complete.
        var issued = false
    }

    private enum ReplyPurpose: Sendable {
        case capture(surfaceID: SurfaceId, generation: UInt64, phase: CapturePhase)
        case discard
        case programStatusPaneOutput(enabled: Bool, sequence: UInt64)
        /// A FIFO synchronisation probe. Its reply is matched by content, so
        /// this purpose exists only to keep the entry addressable.
        case fifoSync
        /// A ledger `refresh-client -C`. Its rejection withdraws the
        /// advertisement so the next replay sends the size again.
        case clientSizeAdvertisement(columns: Int, rows: Int)
    }

    private enum TimerPurpose: Sendable {
        case initialWatchdog(attachment: UInt64)
        case queueWait(surfaceID: SurfaceId, generation: UInt64, attempts: Int)
        case retry(surfaceID: SurfaceId, generation: UInt64, stage: RenderStage, reason: String)
        case sideChannelWatchdog(surfaceID: SurfaceId, epoch: UInt64)
        case surfaceGrid(surfaceID: SurfaceId, generation: UInt64)
    }

    public enum ProgramStatusPaneOutputState: Sendable {
        case off, requested, on, refused
    }

    public private(set) var programStatusPaneOutputState: ProgramStatusPaneOutputState = .off
    private var wantsProgramStatusPaneOutput = false
    private var programStatusPaneOutputSequence: UInt64 = 0

    public var isProgramStatusPaneOutput: Bool {
        profile == .sideChannel
            && (programStatusPaneOutputState == .requested || programStatusPaneOutputState == .on)
    }

    public private(set) var profile: RenderProfile?
    public private(set) var isInitialRenderReady = false

    public private(set) var configuration: Configuration
    private var commandQueue = RenderCommandQueue()
    private var replyPurposes: [UInt64: ReplyPurpose] = [:]
    private var fifoSyncToken: UInt64?
    private var fifoSyncMarker: String?
    private var fifoSyncSequence: UInt64 = 0
    private var fifoResyncAttempts = 0
    private var timerPurposes: [UInt64: TimerPurpose] = [:]
    private var surfaces: [SurfaceId: SurfaceState] = [:]
    private var surfaceOrder: [SurfaceId] = []
    /// Hot-path guard: the rebind reconciliation walk is skipped entirely
    /// while nothing holds a transport full-frame reservation.
    private var hasTransportFullFrameReservation = false
    /// Some surface owes a repaint or a deep rebuild deferred while a peer
    /// held the grid; keeps the per-reduce release check O(1) otherwise.
    private var hasRepaintOwedSinceYield = false
    private var snapshot: TmuxSnapshot?
    private var lastObservedActiveWindowID: WindowId?
    private var lastObservedActivePaneID: PaneId?
    private var pausedPanes: Set<PaneId> = []
    private var isAppInactive = false
    private var isForegroundOutputCoalescing = false
    private var coalescedOutput: [PaneId: [UInt8]] = [:]
    private var liveOutputFramers: [PaneId: TmuxLiveOutputFramer] = [:]
    private var coalescedByteCount = 0
    private var overflowedOutputPanes: Set<PaneId> = []
    private var size: (columns: Int, rows: Int)?
    private var sizeEpoch: UInt64 = 0
    /// The grid this control connection last sent with `refresh-client -C`
    /// and tmux has not rejected (P6). A control client's tty size is set
    /// only by `-C` (cmd-refresh-client.c `tty_set_size`; tmux ignores
    /// `MSG_RESIZE` from control clients) and lasts for the connection, so
    /// while it holds, an identical `-C` changes nothing but still costs a
    /// server-wide pass: it recalculates with `now` set
    /// (`recalculate_sizes_now(1)`), which skips `recalculate_size`'s
    /// "no size change" test and resizes every window, so every control
    /// client gets `%layout-change`, every tty client repaints and zoomed
    /// panes are resized twice. Unlike `size` (the platform's grid, which
    /// survives a reconnect), this belongs to one connection: attach,
    /// transport loss, a command-queue reset and `%session-changed` clear it.
    private var advertisedClientSize: (columns: Int, rows: Int)?
    private var nextGeneration: UInt64 = 1
    private var nextEpoch: UInt64 = 1
    private var nextReplyToken: UInt64 = 1
    private var nextTimerToken: UInt64 = 1
    private var nextSurfaceRequest: UInt64 = 1
    private var nextBytesReference: UInt64 = 1
    private var retainedBytes: [RenderBytesRef: [UInt8]] = [:]
    private var retainedByteOrder: [RenderBytesRef] = []
    private var retainedRefreshGeneration: [RenderBytesRef: (surfaceID: SurfaceId, generation: UInt64)] = [:]
    private var attachmentGeneration: UInt64 = 0
    private var initialWatchdogToken: UInt64?
    /// Some shells/proxies replace the tab separators in command-reply bodies.
    /// Once observed, every capture body on that control path is untrustworthy:
    /// initial attach may fail open to live `%output`, while an established
    /// surface stays fail-closed behind its last authoritative frame.
    private var commandRepliesSanitized = false
    /// Once-per-attachment wire evidence. A device log has to tell a silent
    /// pane from a desynchronised FIFO from a reply nobody could parse; each
    /// is said once so the bounded log keeps the attach that mattered.
    private var unmatchedReplyReports = 0
    private var reportedUnroutedOutput = false
    private var reportedGatedOutput = false

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public var pendingCommandCount: Int { commandQueue.pendingCount }
    public var hasPendingRender: Bool {
        surfaces.values.contains { $0.pending != nil }
            || (profile == .inline
                && isForegroundOutputCoalescing
                && snapshot?.activeWindowID != nil)
    }

    /// The surface whose still-current rendered-pane metadata command is next
    /// in the shared response FIFO. Platform projections may use this to copy
    /// titles and interaction flags only from an authenticated metadata reply;
    /// ordinary platform replies, capture bodies and superseded generations
    /// deliberately return nil.
    public var nextAuthoritativeMetadataSurfaceID: SurfaceId? {
        guard let token = commandQueue.nextLedgerToken,
              case .capture(let surfaceID, let generation, let phase) = replyPurposes[token],
              surfaces[surfaceID]?.pending?.generation == generation
        else { return nil }
        switch phase {
        case .metadata, .settledPrimaryMetadata, .settledAltMetadata, .moshMetadata:
            return surfaceID
        default:
            return nil
        }
    }

    /// True through capture, painter handoff, and the platform's placement receipt.
    /// A temporarily empty rebinding buffer is not the end of remote history.
    public func isHistoryPresentationPending(for surfaceID: SurfaceId) -> Bool {
        guard let state = surfaces[surfaceID]?.sideChannel else { return false }
        return state.inFlightEpoch != nil || state.pendingPresentationOwner != nil
    }

    public func owner(for surfaceID: SurfaceId) -> RenderOwner? { surfaces[surfaceID]?.owner }
    /// A capture or its bounded retry can still deliver a repaint. An
    /// exhausted foreground recovery retains its ownership cut to reject
    /// live output, but that terminal state is no longer work in flight.
    public func isRefreshInFlight(for surfaceID: SurfaceId) -> Bool {
        guard let pending = surfaces[surfaceID]?.pending else { return false }
        if !pending.aborted { return true }
        return timerPurposes.values.contains { purpose in
            guard case .retry(let retrySurface, let generation, _, _) = purpose else { return false }
            return retrySurface == surfaceID && generation == pending.generation
        }
    }

    public func hasFailedRefresh(for surfaceID: SurfaceId) -> Bool {
        surfaces[surfaceID]?.refreshFailedWithoutFrame == true
    }

    public func pendingStage(for surfaceID: SurfaceId) -> RenderStage? {
        surfaces[surfaceID]?.pending?.stage
    }
    public func pendingReason(for surfaceID: SurfaceId) -> String? {
        surfaces[surfaceID]?.pending?.reason
    }

    public mutating func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public mutating func cancelUnwrittenPlatformCommands(tags: [UInt64]) -> Bool {
        commandQueue.cancelUnwrittenPlatformSuffix(tags: tags)
    }

    public mutating func enqueuePlatformCommand(_ command: String) -> RenderCommandSubmission {
        commandQueue.enqueuePlatform(command)
    }

    public mutating func enqueuePlatformCommandList(_ commands: [String]) -> RenderCommandSubmission? {
        commandQueue.enqueuePlatformList(commands)
    }

    /// Queue a command group before the adapter writes its first byte. This
    /// preserves adjacency even when the transport's write callback re-enters
    /// the controller synchronously.
    public mutating func enqueuePlatformCommands(_ commands: [String]) -> [RenderCommandSubmission] {
        commands.map { commandQueue.enqueuePlatform($0) }
    }

    /// Invalidate command purposes after the platform has fenced or replaced
    /// the control transport. Render ownership remains intact.
    public mutating func resetCommandQueue() {
        commandQueue.reset()
        replyPurposes.removeAll(keepingCapacity: true)
        // The reply that could have withdrawn an in-flight `-C` is gone.
        advertisedClientSize = nil
        commandRepliesSanitized = false
        fifoSyncToken = nil
        fifoSyncMarker = nil
    }

    public mutating func reduce(
        _ event: TmuxRuntimeBatch.OrderedEvent,
        snapshot suppliedSnapshot: TmuxSnapshot
    ) -> [RenderEffect] {
        let previousSnapshot = snapshot
        snapshot = suppliedSnapshot
        var effects: [RenderEffect]
        switch event {
        case .correlation(let event):
            effects = reconcilingTransportFullFrameReservations(reduceCorrelation(event))
        case .message(let message):
            effects = reconcilingTransportFullFrameReservations(reduceMessage(
                message,
                snapshot: suppliedSnapshot,
                previousSnapshot: previousSnapshot
            ))
        }
        if hasRepaintOwedSinceYield {
            effects.append(contentsOf: reconcilingTransportFullFrameReservations(
                releaseRepaintsOwedSinceYield()
            ))
        }
        return effects
    }

    public mutating func reduce(
        _ fact: RenderFact,
        snapshot suppliedSnapshot: TmuxSnapshot? = nil
    ) -> [RenderEffect] {
        if let suppliedSnapshot { snapshot = suppliedSnapshot }
        var effects = reconcilingTransportFullFrameReservations(reduceFact(fact))
        if hasRepaintOwedSinceYield {
            effects.append(contentsOf: reconcilingTransportFullFrameReservations(
                releaseRepaintsOwedSinceYield()
            ))
        }
        return effects
    }

    /// The adapter changed the authority it reports in `snapshot` outside
    /// the wire stream (a claim settled). Releases what P7/P8 deferred while
    /// a peer held the grid; any later reduce would too, this one is prompt.
    public mutating func noteAuthority(snapshot suppliedSnapshot: TmuxSnapshot) -> [RenderEffect] {
        snapshot = suppliedSnapshot
        guard hasRepaintOwedSinceYield else { return [] }
        return reconcilingTransportFullFrameReservations(releaseRepaintsOwedSinceYield())
    }

    private mutating func reduceFact(_ fact: RenderFact) -> [RenderEffect] {
        switch fact {
        case .transportAttached(let profile):
            return attach(profile)
        case .transportLost:
            return transportLost()
        case .programStatusPaneOutput(let enabled):
            guard profile == nil || profile == .sideChannel else { return [] }
            guard wantsProgramStatusPaneOutput != enabled else { return [] }
            wantsProgramStatusPaneOutput = enabled
            return updateProgramStatusPaneOutput()
        case .surfacesDeclared(let declarations):
            return declareSurfaces(declarations)
        case .clientSize(let columns, let rows):
            return clientSizeChanged(columns: columns, rows: rows)
        case .transportOutputObserved(let surfaceID, let owner):
            return transportOutputObserved(surfaceID, owner: owner)
        case .surfaceState(let surfaceID, let request, let altScreen, _, let columns, let rows):
            return resolvedSurfaceState(
                surfaceID: surfaceID,
                request: request,
                altScreen: altScreen,
                columns: columns,
                rows: rows
            )
        case .appForeground:
            return appForegrounded()
        case .appBackground:
            isAppInactive = true
            isForegroundOutputCoalescing = profile == .inline
            var effects: [RenderEffect] = []
            if profile == .inline {
                for surfaceID in surfaceOrder {
                    if let pending = surfaces[surfaceID]?.pending,
                       let failure = correlatedRefreshFailure(
                           surfaceID: surfaceID,
                           pending: pending,
                           reason: "app-background"
                       ) {
                        effects.append(failure)
                    }
                    // A reader's deepen dropped here (one waiting for its
                    // surface's grid, say) still owes that reader a settle;
                    // foreground recovery repaints without history.
                    if let pending = surfaces[surfaceID]?.pending,
                       pending.historyDepth != nil
                        || surfaces[surfaceID]?.inlineHistory.deepenRequestedWhilePending == true {
                        effects.append(contentsOf: settleInlineHistoryAfterTermination(
                            surfaceID: surfaceID,
                            pending: pending
                        ))
                    }
                    if let pending = surfaces[surfaceID]?.pending {
                        oweDroppedRefresh(surfaceID: surfaceID, pending: pending)
                    }
                    surfaces[surfaceID]?.pending = nil
                }
            }
            return effects
        case .timerFired(let token):
            return timerFired(token)
        case .scrollbackRequested(let surfaceID, _, let isInertial):
            if profile == .inline {
                return requestInlineHistoryDeepen(surfaceID: surfaceID, reason: "scrollback-deepen")
            }
            return requestSideChannelHistory(surfaceID: surfaceID, isInertial: isInertial, forceFullDepth: false)
        case .scrollbackReturnedToTail(let surfaceID):
            return returnedToTail(surfaceID)
        case .historyPresented(let surfaceID, let owner):
            return historyPresented(surfaceID, owner: owner)
        case .historyPresentationFailed(let surfaceID, let owner):
            return historyPresentationFailed(surfaceID, owner: owner)
        case .findOpened(let surfaceID):
            if profile == .inline {
                return requestInlineHistoryDeepen(surfaceID: surfaceID, reason: "find-deepen")
            }
            return requestSideChannelHistory(surfaceID: surfaceID, isInertial: false, forceFullDepth: true)
        case .userInput:
            return invalidateSideChannelHistory(reason: "user-input")
        case .scrollbackLimit(let lines):
            configuration.scrollbackLimit = max(0, lines)
            return []
        case .refreshRequested(let surfaceID, let stage, let reason):
            return requestRefresh(surfaceID: surfaceID, stage: stage, reason: reason, continuityBreak: stage != .viewportOnly)
        case .correlatedRefreshRequested(let surfaceID, let stage, let reason, let correlation):
            guard correlation > 0 else {
                return [
                    .diagnostic("render-ledger rejected-refresh-correlation surface=\(surfaceID)"),
                    .refreshFailed(surfaceID, correlation: correlation, reason: "invalid-correlation"),
                ]
            }
            return requestRefresh(
                surfaceID: surfaceID,
                stage: stage,
                reason: reason,
                continuityBreak: stage != .viewportOnly,
                completionCorrelation: correlation
            )
        case .correlatedTransportFullFrameRequested(let surfaceID, let reason, let correlation):
            return reserveTransportFullFrame(
                surfaceID: surfaceID,
                reason: reason,
                correlation: correlation
            )
        case .transportFullFramePresented(let surfaceID, let owner, let correlation):
            return resolveTransportFullFrame(
                surfaceID: surfaceID,
                owner: owner,
                correlation: correlation,
                failure: nil
            )
        case .transportFullFramePresentationFailed(let surfaceID, let owner, let correlation, let reason):
            return resolveTransportFullFrame(
                surfaceID: surfaceID,
                owner: owner,
                correlation: correlation,
                failure: reason
            )
        case .unwrittenCommandsCancelled(let tags):
            _ = cancelUnwrittenPlatformCommands(tags: tags)
            return []
        case .reorderBegan, .reorderConfirmed, .reorderAbandoned, .orderRefreshCompleted:
            return []
        }
    }

    /// Reconcile topology after an adapter ingests an authoritative fixed
    /// query outside the parser's ordinary notification stream.
    public mutating func synchronize(snapshot suppliedSnapshot: TmuxSnapshot) -> [RenderEffect] {
        snapshot = suppliedSnapshot
        return reconcilingTransportFullFrameReservations(
            synchronizeActiveIdentity(snapshot: suppliedSnapshot, reason: "snapshot")
        )
    }

    /// Record a client grid that was applied by an already-enqueued platform
    /// command. Most callers submit `.clientSize`, which both records and
    /// emits the shared replay. A platform transaction that must inspect the
    /// acknowledgement of its own `refresh-client -C` uses this after that
    /// acknowledgement so the ledger's size epoch still invalidates any
    /// younger capture without transmitting the size command twice.
    ///
    /// It is not counted as advertised (P6). The one such transaction, the
    /// reverse-attach cede, sizes this client to a peer's grid while changing
    /// which client tmux sizes the window from (`-f ignore-size`), so an
    /// acknowledged `-C` there is no proof the window follows it. Were it
    /// trusted, the next claim at that grid would drop its `-C` and its fence
    /// would take `latest` at a size tmux may never have applied; forgetting
    /// costs that claim one `-C`.
    public mutating func noteAppliedClientSize(columns: Int, rows: Int) -> [RenderEffect] {
        guard columns > 0, rows > 0 else {
            return [.diagnostic("render-ledger rejected-applied-client-size columns=\(columns) rows=\(rows)")]
        }
        advertisedClientSize = nil
        let geometryChanged = size?.columns != columns || size?.rows != rows
        guard geometryChanged else { return [] }
        size = (columns, rows)
        sizeEpoch &+= 1
        if profile == .sideChannel {
            return reconcilingTransportFullFrameReservations(
                invalidateSideChannelHistory(reason: "client-size", forceBind: true)
            )
        }
        return []
    }

    public func renderBytes(for reference: RenderBytesRef) -> [UInt8]? {
        retainedBytes[reference]
    }

    /// Preserve the ledger's refresh generation when render bytes cross an
    /// ABI boundary. The C handle uses it to evict a superseded same-owner
    /// payload without making the generation part of the public effect JSON.
    public func refreshGeneration(for reference: RenderBytesRef) -> UInt64? {
        retainedRefreshGeneration[reference]?.generation
    }

    public mutating func takeRenderBytes(_ reference: RenderBytesRef) -> [UInt8]? {
        retainedByteOrder.removeAll { $0 == reference }
        retainedRefreshGeneration.removeValue(forKey: reference)
        return retainedBytes.removeValue(forKey: reference)
    }

    public mutating func reset() -> [RenderEffect] {
        transportLost()
    }

    private mutating func attach(_ newProfile: RenderProfile) -> [RenderEffect] {
        liveOutputFramers.removeAll()
        var effects = invalidateAllTimers()
        let wasInline = profile == .inline
        profile = newProfile
        programStatusPaneOutputState = .off
        // A new control client starts at tmux's default 80x24 whatever this
        // device last advertised on the previous connection.
        advertisedClientSize = nil
        attachmentGeneration &+= 1
        if !commandQueue.isEmpty {
            // A platform command admitted ahead of this boundary can never be
            // answered: its wire reply drains a FIFO that no longer holds it.
            // Say so, on both platforms; the adapter must attach the
            // transport before it sends anything (Android's initial-attach
            // authority claim once raced this and waited on a fence forever).
            effects.append(.diagnostic(
                "render-ledger attach discarded-pending-commands count=\(commandQueue.pendingCount)"
            ))
        }
        commandQueue.reset()
        replyPurposes.removeAll(keepingCapacity: true)
        commandRepliesSanitized = false
        fifoSyncToken = nil
        fifoSyncMarker = nil
        fifoResyncAttempts = 0
        unmatchedReplyReports = 0
        reportedUnroutedOutput = false
        reportedGatedOutput = false
        pausedPanes.removeAll(keepingCapacity: true)
        clearRepaintsOwedSinceYield()
        for surfaceID in surfaceOrder {
            if let pending = surfaces[surfaceID]?.pending,
               let failure = correlatedRefreshFailure(
                   surfaceID: surfaceID,
                   pending: pending,
                   reason: "transport-attached"
               ) {
                effects.append(failure)
            }
            if let surface = surfaces[surfaceID] {
                effects.append(contentsOf: settleInlineHistoryAtTransportBoundary(
                    surfaceID: surfaceID,
                    surface: surface,
                    wasInline: wasInline
                ))
            }
            // A frame reserved against the transport being replaced can never
            // be painted by the one attaching, whichever profile it brings.
            if let reservation = surfaces[surfaceID]?.transportFullFrame {
                surfaces[surfaceID]?.transportFullFrame = nil
                effects.append(.transportFullFrameFailed(
                    surfaceID,
                    correlation: reservation.correlation,
                    reason: "transport-attached"
                ))
            }
            surfaces[surfaceID]?.pending = nil
            surfaces[surfaceID]?.retryAttemptsByStage.removeAll(keepingCapacity: true)
            // The new transport re-captures every established surface from
            // tmux truth, so no depth credited across the boundary survives.
            surfaces[surfaceID]?.inlineHistory = .init()
            surfaces[surfaceID]?.persistentGridMismatch = nil
        }
        recomputeTransportFullFrameReservationFlag()
        isInitialRenderReady = newProfile == .sideChannel
        if newProfile == .inline {
            let token = allocateTimer(.initialWatchdog(attachment: attachmentGeneration))
            initialWatchdogToken = token
            effects.append(.armTimer(token: token, milliseconds: configuration.initialRenderWatchdogMilliseconds))

            // A control transport attachment is a continuity break even when
            // hydration returns the same window and pane.  Repaint every
            // established surface from tmux truth under a fresh owner epoch;
            // identity-only synchronization would otherwise regard a
            // same-pane reconnect as already current and leave stale local
            // scrollback in place.  If topology is not known yet, clearing the
            // internal owner makes the later hydration synchronization take
            // the same initial-deep path while the platform seam remains
            // fail-closed on its old owner until the authoritative bind/feed.
            for surfaceID in surfaceOrder where surfaces[surfaceID]?.owner != nil {
                if resolvedRefreshTarget(for: surfaceID) != nil {
                    effects.append(contentsOf: requestRefresh(
                        surfaceID: surfaceID,
                        stage: .deep,
                        reason: "transport-attached",
                        continuityBreak: true
                    ))
                } else {
                    surfaces[surfaceID]?.owner = nil
                }
            }
        } else {
            // Mosh remains the painter, so reattach never captures a viewport.
            // It does invalidate every parked history buffer immediately: a
            // fresh epoch forces the platform seam to empty the old transcript
            // and makes any pre-reattach capture reply foreign by construction.
            for surfaceID in surfaceOrder {
                guard var surface = surfaces[surfaceID], let prior = surface.owner else { continue }
                let target = resolvedTarget(for: surfaceID)
                let owner = allocateOwner(
                    windowID: target?.windowID ?? prior.windowID,
                    paneID: target?.paneID ?? prior.paneID
                )
                surface.owner = owner
                surface.sideChannel = .init()
                surfaces[surfaceID] = surface
                effects.append(.bindSurface(surfaceID, owner: owner))
            }
        }
        effects.append(contentsOf: synchronizeActiveIdentity(snapshot: snapshot, reason: "transport-attached"))
        if wantsProgramStatusPaneOutput {
            effects.append(contentsOf: updateProgramStatusPaneOutput())
        }
        return effects
    }

    private mutating func transportLost() -> [RenderEffect] {
        liveOutputFramers.removeAll()
        var effects = invalidateAllTimers()
        let wasInline = profile == .inline
        profile = nil
        programStatusPaneOutputState = .off
        advertisedClientSize = nil
        attachmentGeneration &+= 1
        nextGeneration &+= 1
        commandQueue.reset()
        replyPurposes.removeAll(keepingCapacity: true)
        fifoSyncToken = nil
        fifoSyncMarker = nil
        fifoResyncAttempts = 0
        clearRepaintsOwedSinceYield()
        for surfaceID in surfaceOrder {
            guard var surface = surfaces[surfaceID] else { continue }
            if let pending = surface.pending,
               let failure = correlatedRefreshFailure(
                   surfaceID: surfaceID,
                   pending: pending,
                   reason: "transport-lost"
               ) {
                effects.append(failure)
            }
            effects.append(contentsOf: settleInlineHistoryAtTransportBoundary(
                surfaceID: surfaceID,
                surface: surface,
                wasInline: wasInline
            ))
            if let reservation = surface.transportFullFrame {
                surface.transportFullFrame = nil
                effects.append(.transportFullFrameFailed(
                    surfaceID,
                    correlation: reservation.correlation,
                    reason: "transport-lost"
                ))
            }
            surface.pending = nil
            surface.sideChannel = .init()
            surface.inlineHistory = .init()
            surface.persistentGridMismatch = nil
            surfaces[surfaceID] = surface
        }
        recomputeTransportFullFrameReservationFlag()
        isForegroundOutputCoalescing = false
        coalescedOutput.removeAll(keepingCapacity: true)
        overflowedOutputPanes.removeAll(keepingCapacity: true)
        coalescedByteCount = 0
        retainedBytes.removeAll(keepingCapacity: true)
        retainedByteOrder.removeAll(keepingCapacity: true)
        retainedRefreshGeneration.removeAll(keepingCapacity: true)
        initialWatchdogToken = nil
        effects.append(.diagnostic("render-ledger transport-lost"))
        return effects
    }

    private mutating func declareSurfaces(_ declarations: [SurfaceDeclaration]) -> [RenderEffect] {
        var effects: [RenderEffect] = []
        let previouslyDeclared = Set(surfaces.keys)
        let unique = declarations.reduce(into: [SurfaceId: SurfaceDeclaration]()) { partial, declaration in
            partial[declaration.surfaceID] = declaration
        }
        let removed = surfaceOrder.filter { unique[$0] == nil }
        for surfaceID in removed {
            let timerTokens = timerPurposes.compactMap { token, purpose -> UInt64? in
                switch purpose {
                case .queueWait(let candidate, _, _),
                     .retry(let candidate, _, _, _),
                     .sideChannelWatchdog(let candidate, _),
                     .surfaceGrid(let candidate, _):
                    return candidate == surfaceID ? token : nil
                case .initialWatchdog:
                    return nil
                }
            }
            for token in timerTokens {
                timerPurposes.removeValue(forKey: token)
                effects.append(.cancelTimer(token: token))
            }
            if let token = surfaces[surfaceID]?.sideChannel.watchdogToken {
                timerPurposes.removeValue(forKey: token)
                if !timerTokens.contains(token) {
                    effects.append(.cancelTimer(token: token))
                }
            }
            if let pending = surfaces[surfaceID]?.pending,
               let failure = correlatedRefreshFailure(
                   surfaceID: surfaceID,
                   pending: pending,
                   reason: "surface-removed"
               ) {
                effects.append(failure)
            }
            // Undeclaring a surface is not a rebind, but it is still the end of
            // any frame reserved against it, and a reservation that simply
            // vanished would strand the transaction waiting on its outcome.
            if let reservation = surfaces[surfaceID]?.transportFullFrame {
                effects.append(.transportFullFrameFailed(
                    surfaceID,
                    correlation: reservation.correlation,
                    reason: "surface-removed"
                ))
            }
            surfaces.removeValue(forKey: surfaceID)
        }
        if !removed.isEmpty { recomputeTransportFullFrameReservationFlag() }
        surfaceOrder = declarations.map(\.surfaceID).reduce(into: []) { order, id in
            if !order.contains(id) { order.append(id) }
        }
        for declaration in declarations {
            if var existing = surfaces[declaration.surfaceID] {
                existing.declaration = declaration
                surfaces[declaration.surfaceID] = existing
            } else {
                surfaces[declaration.surfaceID] = .init(declaration: declaration)
            }
        }
        // Mounting a fresh emulator is a two-step platform operation: declare
        // it, then explicitly request the appropriate first stage once its
        // state seam is ready.  Starting a capture from declaration alone can
        // put a command in flight before SwiftUI/Compose has attached the
        // surface, and it prevents the caller from choosing viewport versus
        // deep.  Surfaces that already existed still reconcile immediately
        // when their fixed target changes. A sized single Mosh painter needs
        // only its first owner bind, so it can also reconcile on its initial
        // declaration after metadata has already hydrated.
        var eligibleSurfaceIDs = previouslyDeclared
        if profile == .sideChannel, size != nil {
            eligibleSurfaceIDs.formUnion(declarations.filter { $0.presentation == .single }.map(\.surfaceID))
        }
        effects.append(contentsOf: synchronizeActiveIdentity(
            snapshot: snapshot,
            reason: "surfaces-declared",
            eligibleSurfaceIDs: eligibleSurfaceIDs
        ))
        if surfaceOrder.isEmpty, snapshot?.activeWindowID == nil {
            endForegroundCoalescing()
        }
        return effects
    }

    private mutating func clientSizeChanged(columns: Int, rows: Int) -> [RenderEffect] {
        guard columns > 0, rows > 0 else {
            return [.diagnostic("render-ledger rejected-client-size columns=\(columns) rows=\(rows)")]
        }
        let geometryChanged = size?.columns != columns || size?.rows != rows
        if geometryChanged {
            size = (columns, rows)
            sizeEpoch &+= 1
        }
        var effects: [RenderEffect] = []
        if let profile {
            let path: TmuxClientSizeReplay.Path = profile == .inline ? .inline : .sideChannel
            let alreadyAdvertised = configuration.suppressesUnchangedClientSizeReplay
                && advertisedClientSize?.columns == columns
                && advertisedClientSize?.rows == rows
            for command in TmuxClientSizeReplay.commands(
                columns: columns,
                rows: rows,
                path: path,
                belongsToClaim: profile == .inline
                    && configuration.inlineClientSizeReplayBelongsToClaim,
                sizeAlreadyAdvertised: alreadyAdvertised
            ) {
                guard command != TmuxClientSizeReplay.latestFenceCommand else {
                    effects.append(enqueueLedgerCommand(command, purpose: nil))
                    continue
                }
                let token = allocateReplyToken()
                replyPurposes[token] = .clientSizeAdvertisement(columns: columns, rows: rows)
                advertisedClientSize = (columns, rows)
                effects.append(enqueueLedgerCommand(command, purpose: token))
            }
        }
        if profile == .sideChannel, geometryChanged {
            effects.append(contentsOf: invalidateSideChannelHistory(
                reason: "client-size",
                forceBind: true
            ))
        }
        return effects
    }

    private mutating func appForegrounded() -> [RenderEffect] {
        isAppInactive = false
        guard profile == .inline else { return [] }
        isForegroundOutputCoalescing = true
        var effects: [RenderEffect] = []
        for surfaceID in surfaceOrder {
            guard let target = resolvedRefreshTarget(for: surfaceID) else { continue }
            let state = surfaces[surfaceID]
            let sameIdentity = state?.owner?.windowID == target.windowID
                && state?.owner?.paneID == target.paneID
            let isUnpaintedFocusedGridSurface = state?.owner == nil
                && state?.declaration.presentation == .grid
                && target.paneID == snapshot?.windows
                    .first(where: { $0.id == target.windowID })?
                    .activePaneID
            effects.append(contentsOf: requestRefresh(
                surfaceID: surfaceID,
                stage: sameIdentity
                    ? .viewportOnly
                    : (isUnpaintedFocusedGridSurface ? .deep : .viewport),
                reason: "app-foreground",
                continuityBreak: !sameIdentity
            ))
        }
        // A grid topology can become authoritative one turn before SwiftUI or
        // Compose mounts its pane surfaces. Keep the barrier and its retained
        // bytes through that intentional empty-surface interval; the mounted
        // pane's explicit refresh takes ownership. With no active window there
        // is nothing left to recover, so release immediately.
        if effects.isEmpty, snapshot?.activeWindowID == nil {
            endForegroundCoalescing()
        }
        return effects
    }

    private mutating func reduceCorrelation(_ event: TmuxCorrelationEvent) -> [RenderEffect] {
        if isFifoSyncReply(event) { return realignCommandQueue() }
        let hadQueuedCommand = !commandQueue.isEmpty
        guard let completion = commandQueue.consume(event) else {
            if hadQueuedCommand, case .frameCompleted(let frame) = event, frame.isClientResponse {
                return []
            }
            return unattributedFrameEvidence(event)
        }
        return deliver(completion)
    }

    private mutating func deliver(_ completion: RenderCommandCompletion) -> [RenderEffect] {
        switch completion {
        case .platform(let tag, let result):
            return [.commandReply(tag: tag, success: result.success, lines: result.lines, parts: result.parts)]
        case .ledger(let token, let result):
            guard let purpose = replyPurposes.removeValue(forKey: token) else {
                return [.diagnostic("render-ledger missing-reply-purpose token=\(token)")]
            }
            if case .fifoSync = purpose { return [] }
            return handleLedgerReply(purpose, result: result)
        }
    }

    /// The one reply the ledger can recognise without trusting the FIFO.
    private func isFifoSyncReply(_ event: TmuxCorrelationEvent) -> Bool {
        guard let marker = fifoSyncMarker,
              case .frameCompleted(let frame) = event,
              frame.isClientResponse,
              frame.status == .success
        else { return false }
        return frame.lines.filter { !$0.isEmpty } == [marker]
    }

    /// Ask the server to echo a marker, so a reply stream that has drifted out
    /// of step with this queue can be put back in step.
    ///
    /// A control-mode reply carries nothing that identifies the command it
    /// answers, so one command that is registered but never written — or
    /// written out of registration order — silently shifts every later reply
    /// onto its neighbour's purpose. Empty replies are legal, so the shift can
    /// stay invisible until a reply has to be parsed, and then every retry
    /// inherits the same shift and the surface never binds. The probe's reply
    /// is matched by content instead of by position, which makes the drift
    /// measurable and recoverable exactly once per failure.
    private mutating func beginFifoResync(reason: String) -> [RenderEffect] {
        guard profile != nil,
              fifoSyncToken == nil,
              fifoResyncAttempts < configuration.maximumFifoResyncAttempts
        else { return [] }
        fifoResyncAttempts += 1
        fifoSyncSequence &+= 1
        let marker = RenderCommands.fifoSyncMarker(sequence: fifoSyncSequence)
        let token = allocateReplyToken()
        replyPurposes[token] = .fifoSync
        fifoSyncToken = token
        fifoSyncMarker = marker
        let head = commandQueue.headCommand ?? ""
        return [
            .diagnostic(
                "render-ledger fifo-resync reason=\(reason) attempt=\(fifoResyncAttempts)"
                    + " pending=\(commandQueue.pendingCount)"
                    + " head=\(TmuxWireEvidence.snippet(head, limit: 80))"
            ),
            enqueueLedgerCommand(RenderCommands.fifoSync(marker: marker), purpose: token),
        ]
    }

    /// Put the queue back in step with the wire, failing every purpose the
    /// drift stranded so no caller waits on a reply that can never arrive.
    private mutating func realignCommandQueue() -> [RenderEffect] {
        guard let token = fifoSyncToken else { return [] }
        fifoSyncToken = nil
        fifoSyncMarker = nil
        var effects: [RenderEffect] = []
        var stranded = 0
        // The marker belongs to the probe, even if a partial list still
        // heads the FIFO. Drain without appending it to that list's parts.
        for completion in commandQueue.drainThrough(ledgerToken: token) ?? [] {
            if case .ledger(let drained, _) = completion, drained == token {
                replyPurposes.removeValue(forKey: token)
                continue
            }
            stranded += 1
            effects.append(contentsOf: deliver(completion))
        }
        effects.insert(
            .diagnostic(
                "render-ledger fifo-resynced stranded=\(stranded) pending=\(commandQueue.pendingCount)"
            ),
            at: 0
        )
        return effects
    }

    /// A client-response frame the FIFO could not attribute is the one
    /// symptom that distinguishes a wire desynchronisation from a host that
    /// answers slowly or badly: every later reply is then someone else's.
    /// Server frames (flags bit 0 clear) are expected and stay silent.
    private mutating func unattributedFrameEvidence(_ event: TmuxCorrelationEvent) -> [RenderEffect] {
        guard unmatchedReplyReports < 8 else { return [] }
        switch event {
        case .frameStarted(_, let discarded?, let discardedLineCount):
            unmatchedReplyReports += 1
            return [.diagnostic(
                "render-ledger torn-frame discarded=\(discarded.commandNumber) lines=\(discardedLineCount)"
            )]
        case .frameCompleted(let frame) where frame.isClientResponse:
            unmatchedReplyReports += 1
            let head = frame.lines.first(where: { !$0.isEmpty }) ?? ""
            return [.diagnostic(
                "render-ledger unmatched-reply status=\(frame.status.rawValue) number=\(frame.end.commandNumber)"
                    + " lines=\(frame.lines.count) head=\(TmuxWireEvidence.snippet(head, limit: 160))"
            )]
        default:
            return []
        }
    }

    private mutating func reduceMessage(
        _ message: TmuxMessage,
        snapshot suppliedSnapshot: TmuxSnapshot,
        previousSnapshot: TmuxSnapshot?
    ) -> [RenderEffect] {
        switch message {
        case .output(let paneID, let data), .extendedOutput(let paneID, _, let data):
            return handlePaneOutput(paneID: paneID, bytes: data, snapshot: suppliedSnapshot)
        case .pause(let paneID):
            return handlePause(paneID: paneID, snapshot: suppliedSnapshot)
        case .layoutChange(let windowID, _, _, _):
            var effects = synchronizeActiveIdentity(
                snapshot: suppliedSnapshot,
                reason: messageReason(message)
            )
            guard suppliedSnapshot.activeWindowID == windowID else { return effects }
            // A size replay can echo a layout notification without changing
            // any visible geometry. Both painters keep their current owner
            // in that case: re-binding Mosh would discard its framebuffer and
            // re-arm a full-frame handoff for an acknowledgement alone.
            if let before = previousSnapshot?.windows.first(where: { $0.id == windowID }),
               let after = suppliedSnapshot.windows.first(where: { $0.id == windowID }),
               before.layout == after.layout,
               before.visibleLayout == after.visibleLayout,
               before.isZoomed == after.isZoomed,
               before.panes.map(\.id) == after.panes.map(\.id),
               before.panes.map(\.contentRect) == after.panes.map(\.contentRect) {
                return effects
            }
            switch profile {
            case .inline:
                // A split/collapse/zoom swaps the mounted surface set; its new
                // emulator explicitly requests its mount refresh. A relayout
                // that keeps the same visible panes leaves those emulators
                // mounted, so force a fresh owner and authoritative rebuild
                // even though every pane id still compares equal.
                guard declaredSurfaceSetMatches(
                    windowID: windowID,
                    currentSnapshot: suppliedSnapshot
                ) else { return effects }
                // P7: while a peer holds the grid, its layout changes (every
                // keyboard toggle on a phone) cost no capture here. The veil
                // hides this surface, and only a claim can make it ours
                // again, so record the debt and let that one repaint pay it.
                let yielded = suppliedSnapshot.authority.isPeer
                for surfaceID in surfaceOrder {
                    guard surfaces[surfaceID]?.owner != nil,
                          resolvedRefreshTarget(for: surfaceID)?.windowID == windowID
                    else { continue }
                    if yielded {
                        guard let pending = surfaces[surfaceID]?.pending else {
                            surfaces[surfaceID]?.repaintOwedSinceYield = true
                            hasRepaintOwedSinceYield = true
                            continue
                        }
                        // Nothing of it answered yet: tmux writes this
                        // notification only after applying the resize, so a
                        // query still unanswered runs against the new
                        // geometry (the take-back that just asked for it).
                        // It must still rebuild, not scrub in place: the
                        // surface's history was laid out for the old grid.
                        guard pending.metadata != nil else {
                            rebuildUnansweredRefresh(surfaceID: surfaceID)
                            continue
                        }
                        // A refresh someone asked for (a claim's repaint, a
                        // window switch) is in flight against the old
                        // geometry: re-ask at visible rows. Its deep rebuild
                        // still waits for the peer to be gone.
                        // A correlated one (Android's claim repaint) keeps its
                        // correlation: the new capture is the one it waits for.
                        // It pays this relayout, so it deepens afterwards.
                        surfaces[surfaceID]?.repaintOwedSinceYield = true
                        hasRepaintOwedSinceYield = true
                        effects.append(contentsOf: requestRefresh(
                            surfaceID: surfaceID,
                            stage: .viewport,
                            reason: "layout-change-yielded",
                            continuityBreak: true,
                            completionCorrelation: surfaces[surfaceID]?.pending?.completionCorrelation
                        ))
                        continue
                    }
                    effects.append(contentsOf: requestRefresh(
                        surfaceID: surfaceID,
                        stage: .deep,
                        reason: "layout-change",
                        continuityBreak: true
                    ))
                }
            case .sideChannel:
                // SSP owns the visible screen, but any synthesized scrollback
                // was wrapped for the old geometry. Rebind all surviving
                // surfaces under a new epoch, clear their history, and ask
                // mosh for the new full frame.
                effects.append(contentsOf: invalidateSideChannelHistory(
                    reason: "layout-change",
                    forceBind: true
                ))
                effects.append(.requestTransportFullFrame)
            case nil:
                break
            }
            return effects
        case .sessionWindowChanged, .windowPaneChanged, .windowClose, .unlinkedWindowClose:
            return synchronizeActiveIdentity(snapshot: suppliedSnapshot, reason: messageReason(message))
        case .sessionChanged:
            // The client's tty size survives a session switch, but the
            // windows it now sizes were last sized without it: advertise the
            // grid again on the next replay instead of trusting the old one.
            advertisedClientSize = nil
            return []
        default:
            return []
        }
    }

    private mutating func synchronizeActiveIdentity(
        snapshot suppliedSnapshot: TmuxSnapshot?,
        reason: String,
        eligibleSurfaceIDs: Set<SurfaceId>? = nil
    ) -> [RenderEffect] {
        guard let suppliedSnapshot, let profile else { return [] }
        let paneIDs = Set(suppliedSnapshot.windows.flatMap { $0.panes.map(\.id) })
        liveOutputFramers = liveOutputFramers.filter { paneIDs.contains($0.key) }
        let activeWindowID = suppliedSnapshot.activeWindowID
        let activePaneID = activeWindowID.flatMap { windowID in
            suppliedSnapshot.windows.first { $0.id == windowID }?.activePaneID
        }
        let windowChanged = lastObservedActiveWindowID != nil
            && activeWindowID != nil
            && lastObservedActiveWindowID != activeWindowID
        let paneChanged = lastObservedActivePaneID != nil
            && activePaneID != nil
            && lastObservedActivePaneID != activePaneID
        lastObservedActiveWindowID = activeWindowID ?? lastObservedActiveWindowID
        lastObservedActivePaneID = activePaneID ?? lastObservedActivePaneID

        var effects: [RenderEffect] = []
        for surfaceID in surfaceOrder {
            if let eligibleSurfaceIDs, !eligibleSurfaceIDs.contains(surfaceID) {
                continue
            }
            guard let target = resolvedRefreshTarget(for: surfaceID) else { continue }
            guard var surface = surfaces[surfaceID] else { continue }
            let surfaceWindowChanged = surface.lastResolvedWindowID != nil
                && surface.lastResolvedWindowID != target.windowID
            let surfacePaneChanged = surface.lastResolvedPaneID != nil
                && surface.lastResolvedPaneID != target.paneID
            surface.lastResolvedWindowID = target.windowID
            surface.lastResolvedPaneID = target.paneID
            surfaces[surfaceID] = surface
            let identityChanged = surface.owner.map {
                $0.windowID != target.windowID || $0.paneID != target.paneID
            } ?? true

            switch profile {
            case .inline:
                if surface.pending != nil {
                    let pending = surface.pending!
                    if pending.owner.windowID == target.windowID,
                       pending.owner.paneID == target.paneID {
                        continue
                    }
                }
                if surface.owner == nil {
                    effects.append(contentsOf: requestRefresh(
                        surfaceID: surfaceID,
                        stage: .deep,
                        reason: "\(reason)-initial",
                        continuityBreak: true
                    ))
                } else if identityChanged || windowChanged || paneChanged {
                    effects.append(contentsOf: requestRefresh(
                        surfaceID: surfaceID,
                        stage: .viewport,
                        reason: reason,
                        continuityBreak: true
                    ))
                }
            case .sideChannel:
                guard let targetPaneID = target.paneID else { continue }
                let pendingTargetChanged = surface.pending.map {
                    $0.owner.windowID != target.windowID
                        || $0.owner.paneID != targetPaneID
                } ?? false
                if pendingTargetChanged {
                    effects.append(contentsOf: cancelSideChannelCapture(in: &surface))
                    surfaces[surfaceID] = surface
                }
                if surface.owner == nil {
                    // Size can arrive before topology, when its force-bind
                    // has no target. Establish the single painter's owner as
                    // soon as that target hydrates, independently of layout
                    // echoes. A size-less first observation still only seeds
                    // the identity latch; a real window transition clears the
                    // previous painter's transcript even without history.
                    let declarationTracksActiveWindow = surface.declaration.windowID == nil
                        || surface.declaration.windowID == suppliedSnapshot.activeWindowID
                    let sizedSinglePainter = size != nil && surface.declaration.presentation == .single
                    guard declarationTracksActiveWindow,
                          surfaceWindowChanged || sizedSinglePainter
                    else { continue }
                    let owner = allocateOwner(windowID: target.windowID, paneID: targetPaneID)
                    effects.append(contentsOf: cancelSideChannelCapture(in: &surface))
                    effects.append(.bindSurface(surfaceID, owner: owner))
                    surface.owner = owner
                    surface.sideChannel = .init()
                    surfaces[surfaceID] = surface
                } else if surface.owner?.windowID != target.windowID
                    || (identityChanged && surface.declaration.presentation == .overlay) {
                    let owner = allocateOwner(windowID: target.windowID, paneID: targetPaneID)
                    effects.append(contentsOf: cancelSideChannelCapture(in: &surface))
                    effects.append(.bindSurface(surfaceID, owner: owner))
                    surface.owner = owner
                    surface.sideChannel = .init()
                    surfaces[surfaceID] = surface
                } else if (surface.owner?.paneID != targetPaneID || surfacePaneChanged)
                    && (surface.sideChannel.hasSynthesizedHistory
                        || surface.sideChannel.pendingPresentationOwner != nil) {
                    let owner = allocateOwner(windowID: target.windowID, paneID: targetPaneID)
                    effects.append(contentsOf: cancelSideChannelCapture(in: &surface))
                    effects.append(.bindSurface(surfaceID, owner: owner))
                    surface.owner = owner
                    surface.sideChannel = .init()
                    surfaces[surfaceID] = surface
                }
            }
        }
        return effects
    }

    private mutating func requestRefresh(
        surfaceID: SurfaceId,
        stage requestedStage: RenderStage,
        reason: String,
        continuityBreak requestedContinuityBreak: Bool,
        completionCorrelation: UInt64? = nil,
        historyDepth: Int? = nil,
        surfaceGridPolls: Int = 0
    ) -> [RenderEffect] {
        var stage = requestedStage
        var continuityBreak = requestedContinuityBreak
        guard profile == .inline else {
            return rejectedCorrelatedRefresh(
                surfaceID: surfaceID,
                correlation: completionCorrelation,
                reason: "profile-not-inline"
            )
        }
        guard var surface = surfaces[surfaceID] else {
            return rejectedCorrelatedRefresh(
                surfaceID: surfaceID,
                correlation: completionCorrelation,
                reason: "surface-not-declared"
            )
        }
        guard let target = resolvedRefreshTarget(for: surfaceID) else {
            return rejectedCorrelatedRefresh(
                surfaceID: surfaceID,
                correlation: completionCorrelation,
                reason: "target-unavailable"
            )
        }

        if let existing = surface.owner,
           existing.windowID != target.windowID || existing.paneID != target.paneID {
            // This surface is being repainted from a different pane, so the
            // depth credited to the old one is meaningless for the new one.
            surface.inlineHistory.resetForNewIdentity()
        }
        if surface.pending?.deepensAfterRebuild == true {
            // A refresh replacing an unfinished payment of that debt inherits
            // it: the relayout it was rebuilding for is still unpainted.
            surface.repaintOwedSinceYield = true
        }
        var paysRelayoutDebt = false
        if surface.repaintOwedSinceYield {
            // P7: the surface missed a relayout while yielded. Whatever was
            // asked for, it is rebuilt: never an in-place scrub, and at
            // visible rows unless a deep rebuild was asked for anyway.
            surface.repaintOwedSinceYield = false
            surface.deepRebuildOwedSinceYield = false
            continuityBreak = true
            if stage == .viewportOnly { stage = .viewport }
            paysRelayoutDebt = stage != .deep
        } else if stage == .deep {
            surface.deepRebuildOwedSinceYield = false
        }
        if let replaced = surface.pending,
           let painted = surface.owner,
           replaced.owner != painted {
            // Any refresh replacing an unfinished rebuild (a fresh owner:
            // a relayout's, say) inherits it. The surface still holds rows
            // laid out for the old grid, so the replacement rebuilds too,
            // never scrubs in place. A deep rebuild it replaces at visible
            // rows is deepened afterwards (`deepensAfterRebuild`), as the
            // relayout would have deepened every pane. Typically: a
            // take-back that resized the window, whose foreground refresh
            // follows the ledger's own relayout rebuild.
            continuityBreak = true
            if stage == .viewportOnly { stage = .viewport }
            if stage != .deep, replaced.stage == .deep { paysRelayoutDebt = true }
        }

        var effects: [RenderEffect] = []
        if let replaced = surface.pending {
            if replaced.historyDepth != nil {
                // A deepen replaced before it completed still owes the reader
                // exactly one settle. Carry the obligation onto whatever
                // refresh takes its place: every terminal outcome below
                // settles a latched surface, so no separate watchdog is
                // needed to release the platform's single-flight latch.
                surface.inlineHistory.deepenRequestedWhilePending = true
            }
            if replaced.completionCorrelation != completionCorrelation,
               let failure = correlatedRefreshFailure(
                   surfaceID: surfaceID,
                   pending: replaced,
                   reason: "superseded"
               ) {
                effects.append(failure)
            }
        }

        let generation = allocateGeneration()
        let owner: RenderOwner
        if !continuityBreak,
           let existing = surface.owner,
           existing.windowID == target.windowID,
           existing.paneID == target.paneID {
            owner = existing
        } else {
            owner = allocateOwner(windowID: target.windowID, paneID: target.paneID)
        }
        surface.refreshFailedWithoutFrame = false
        var pending = PendingRefresh(
            generation: generation,
            owner: owner,
            stage: stage,
            reason: reason,
            completionCorrelation: completionCorrelation,
            target: target.target,
            sizeEpoch: sizeEpoch,
            foregroundRecovery: isForegroundOutputCoalescing,
            phase: .metadata,
            historyDepth: historyDepth
        )
        pending.surfaceGridPolls = surfaceGridPolls
        pending.deepensAfterRebuild = paysRelayoutDebt
        let foregroundMustRespectTheExistingCut = reason.hasPrefix("app-foreground")
        let queuesBehindItsAdapter = configuration.pipelinesVisibleCapture
            && completionCorrelation != nil
            && !foregroundMustRespectTheExistingCut
        let shouldWait = !commandQueue.isEmpty
            && !queuesBehindItsAdapter
            && (stage != .deep || foregroundMustRespectTheExistingCut)
        if shouldWait {
            pending.phase = .waitingForQueue(attempts: 0)
            surface.pending = pending
            surfaces[surfaceID] = surface
            let token = allocateTimer(.queueWait(surfaceID: surfaceID, generation: generation, attempts: 0))
            effects.append(.armTimer(token: token, milliseconds: configuration.commandQueuePollMilliseconds))
            return effects
        }
        surface.pending = pending
        surfaces[surfaceID] = surface
        effects.append(contentsOf: sendMetadataQuery(surfaceID: surfaceID))
        return effects
    }

    /// P7/P8: pay what was deferred while a peer held the grid, once the
    /// authority stops naming one (a claim settled, or the peer's stamp
    /// went away). A surface that missed a relayout is rebuilt at visible
    /// rows and then deepened, whatever its presentation: the rebuild pays
    /// the relayout debt, so it is marked `deepensAfterRebuild` (a grid
    /// pane's ordinary visible refresh would not deepen). One whose
    /// deepening waited gets it now. A surface with a refresh in flight
    /// keeps its debt: that refresh, or the release after it, settles it.
    private mutating func releaseRepaintsOwedSinceYield() -> [RenderEffect] {
        guard snapshot?.authority.isPeer != true else { return [] }
        guard profile == .inline else {
            clearRepaintsOwedSinceYield()
            return []
        }
        // An inactive app captures nothing; its foreground refresh pays
        // what is owed (`requestRefresh` turns it into the rebuild).
        guard !isAppInactive else { return [] }
        var effects: [RenderEffect] = []
        var stillOwed = false
        for surfaceID in surfaceOrder {
            guard let surface = surfaces[surfaceID],
                  surface.repaintOwedSinceYield || surface.deepRebuildOwedSinceYield
            else { continue }
            guard surface.pending == nil else {
                stillOwed = true
                continue
            }
            if surface.owner != nil, resolvedRefreshTarget(for: surfaceID) != nil {
                let rebuild = surface.repaintOwedSinceYield
                effects.append(.diagnostic(
                    "render-ledger yield-debt-released surface=\(surfaceID) kind=\(rebuild ? "rebuild" : "deepen")"
                ))
                effects.append(contentsOf: requestRefresh(
                    surfaceID: surfaceID,
                    stage: rebuild ? .viewport : .deep,
                    reason: rebuild ? "authority-released" : "authority-released-deep",
                    continuityBreak: rebuild
                ))
            }
            // An unbound or untargeted surface takes the initial capture
            // path when it binds; no debt survives that.
            surfaces[surfaceID]?.repaintOwedSinceYield = false
            surfaces[surfaceID]?.deepRebuildOwedSinceYield = false
        }
        hasRepaintOwedSinceYield = stillOwed
        return effects
    }

    /// P7: turn a refresh whose queries are still unanswered into a rebuild
    /// under a fresh owner. Its commands stay on the wire (a viewport and an
    /// in-place capture are the same command); only how its reply is
    /// presented changes. A visible rebuild is marked to deepen afterwards
    /// (`deepensAfterRebuild`), a grid pane's included, once no peer holds
    /// the grid.
    private mutating func rebuildUnansweredRefresh(surfaceID: SurfaceId) {
        guard var surface = surfaces[surfaceID], var pending = surface.pending else { return }
        if pending.stage == .viewportOnly { pending.stage = .viewport }
        if pending.stage != .deep { pending.deepensAfterRebuild = true }
        if let existing = surface.owner, existing == pending.owner {
            pending.owner = allocateOwner(windowID: existing.windowID, paneID: existing.paneID)
        }
        surface.pending = pending
        surfaces[surfaceID] = surface
    }

    /// A refresh dropped before it painted (the app went inactive) still
    /// owes what it was asked to pay. A rebuild under a fresh owner, or a
    /// payment of relayout debt, leaves the surface holding rows laid out
    /// for another grid, so the next refresh asked for, normally the
    /// foreground's, must rebuild and deepen rather than scrub in place
    /// (`repaintOwedSinceYield`). A deepening that had not run yet is owed
    /// as one (`deepRebuildOwedSinceYield`). A reader's own deepen
    /// (`historyDepth`) is no debt: its gesture is settled where it drops.
    private mutating func oweDroppedRefresh(surfaceID: SurfaceId, pending: PendingRefresh) {
        guard let painted = surfaces[surfaceID]?.owner else { return }
        if pending.deepensAfterRebuild || pending.owner != painted {
            surfaces[surfaceID]?.repaintOwedSinceYield = true
        } else if pending.stage == .deep, pending.historyDepth == nil {
            surfaces[surfaceID]?.deepRebuildOwedSinceYield = true
        } else {
            return
        }
        hasRepaintOwedSinceYield = true
    }

    /// A transport boundary re-captures every surface from tmux truth.
    private mutating func clearRepaintsOwedSinceYield() {
        guard hasRepaintOwedSinceYield else { return }
        for surfaceID in surfaceOrder {
            surfaces[surfaceID]?.repaintOwedSinceYield = false
            surfaces[surfaceID]?.deepRebuildOwedSinceYield = false
        }
        hasRepaintOwedSinceYield = false
    }

    /// The metadata query that opens every inline refresh, followed at once
    /// by the viewport capture when `pipelinesVisibleCapture` allows it for
    /// a take-back's refresh. A viewport capture names the same target and
    /// does not depend on the metadata (only a deep one does, for the
    /// alternate screen), so the pair costs one round trip instead of two.
    /// If the metadata reply restarts or aborts the refresh, the capture's
    /// reply arrives under a retired generation and is dropped like any
    /// stale reply.
    private mutating func sendMetadataQuery(surfaceID: SurfaceId) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID], var pending = surface.pending else { return [] }
        var effects = [sendCaptureCommand(
            RenderCommands.renderedPaneMetadata(target: pending.target),
            surfaceID: surfaceID,
            generation: pending.generation,
            phase: .metadata
        )]
        guard configuration.pipelinesVisibleCapture,
              pending.stage == .viewport || pending.stage == .viewportOnly,
              pending.completionCorrelation != nil || snapshot?.authority.isPeer == true
        else { return effects }
        pending.capturePipelined = true
        surface.pending = pending
        surfaces[surfaceID] = surface
        effects.append(sendCaptureCommand(
            RenderCommands.viewport(target: pending.target),
            surfaceID: surfaceID,
            generation: pending.generation,
            phase: .viewport
        ))
        return effects
    }

    private mutating func handleLedgerReply(
        _ purpose: ReplyPurpose,
        result: RenderCommandResult
    ) -> [RenderEffect] {
        switch purpose {
        case .programStatusPaneOutput(let enabled, let sequence):
            guard sequence == programStatusPaneOutputSequence else { return [] }
            programStatusPaneOutputState = result.success ? (enabled ? .on : .off) : .refused
            return []
        case .fifoSync:
            // Matched by content in `reduceCorrelation`; a probe reply that
            // reaches this point answered a different command entirely.
            return []
        case .capture(let surfaceID, let generation, let phase):
            guard var surface = surfaces[surfaceID],
                  var pending = surface.pending,
                  pending.generation == generation
            else {
                return [.diagnostic(
                    "render-ledger stale-reply surface=\(surfaceID) generation=\(generation)"
                        + " phase=\(phase.evidenceName) lines=\(result.lines.count)"
                )]
            }
            guard !pending.aborted else {
                return [.diagnostic(
                    "render-ledger aborted-reply surface=\(surfaceID) generation=\(generation)"
                        + " phase=\(phase.evidenceName) success=\(result.success)"
                )]
            }
            guard result.success else {
                return abortRefresh(surfaceID: surfaceID, generation: generation, reason: "command-error")
            }

            switch phase {
            case .metadata:
                guard let line = result.lines.first(where: { !$0.isEmpty }),
                      let metadata = TmuxRenderedPaneStateParser.parse(line)
                else {
                    // The bytes are the diagnosis: which separator the host
                    // used, or whether this is even the row that was asked
                    // for. Without them a parse failure only names itself.
                    let head = result.lines.first(where: { !$0.isEmpty }) ?? ""
                    var effects: [RenderEffect] = [.diagnostic(
                        "render-ledger metadata-unparsed surface=\(surfaceID) target=\(pending.target)"
                            + " lines=\(result.lines.count) head=\(TmuxWireEvidence.snippet(head, limit: 200))"
                    )]
                    // The query names its own target and asks for a fixed
                    // 24-field row, so a reply that cannot be parsed is far
                    // more likely to be another command's answer than a
                    // mangled one. Realign before retrying: a retry issued
                    // into a drifted queue inherits the same drift and the
                    // surface never binds.
                    effects.append(contentsOf: beginFifoResync(reason: "metadata-unparsed"))
                    effects.append(contentsOf: abortRefresh(
                        surfaceID: surfaceID,
                        generation: generation,
                        reason: "metadata-parse"
                    ))
                    return effects
                }
                if metadata.paneId != pending.owner.paneID {
                    // A single-surface query targets the window precisely so
                    // its metadata is the authoritative source of the active
                    // pane when topology has not named it yet (or changed
                    // during the round trip). Fixed grid/overlay declarations
                    // may never retarget to a different pane.
                    if let fixedPaneID = surface.declaration.paneID,
                       fixedPaneID != metadata.paneId {
                        return restartRefresh(
                            surfaceID: surfaceID,
                            pending: pending,
                            reason: "metadata-pane-changed"
                        )
                    }
                    pending.owner = allocateOwner(
                        windowID: pending.owner.windowID,
                        paneID: metadata.paneId
                    )
                }
                if !line.contains("\t") {
                    commandRepliesSanitized = true
                    if surface.owner == nil, !isInitialRenderReady {
                        surface.owner = pending.owner
                        surface.renderedPaneInAltScreen = metadata.paneInAltScreen
                        surface.pending = nil
                        surfaces[surfaceID] = surface
                        isInitialRenderReady = true
                        var effects = cancelInitialWatchdog()
                        effects.append(.bindSurface(surfaceID, owner: pending.owner))
                        if let windowID = pending.owner.windowID {
                            effects.append(.restoreWindowModes(
                                surfaceID,
                                window: windowID,
                                paneInAltScreen: metadata.paneInAltScreen
                            ))
                        }
                        effects.append(.initialRenderReady)
                        effects.append(.diagnostic(
                            "render-ledger capture-skipped surface=\(surfaceID) reason=replies-sanitized"
                        ))
                        if let failure = correlatedRefreshFailure(
                            surfaceID: surfaceID,
                            pending: pending,
                            reason: "metadata-sanitized"
                        ) {
                            effects.append(failure)
                        }
                        return effects
                    }
                    return abortRefresh(
                        surfaceID: surfaceID,
                        generation: generation,
                        reason: "metadata-sanitized"
                    )
                }
                guard !commandRepliesSanitized else {
                    return abortRefresh(
                        surfaceID: surfaceID,
                        generation: generation,
                        reason: "capture-suppressed-sanitized"
                    )
                }
                if pending.stage == .viewportOnly
                    && (surface.owner?.paneID != metadata.paneId
                        || surface.renderedPaneInAltScreen.map {
                            $0 != metadata.paneInAltScreen
                        } == true) {
                    pending.stage = .viewport
                }
                pending.metadata = metadata
                surface.pending = pending
                surfaces[surfaceID] = surface
                return beginCaptureAfterMetadata(surfaceID: surfaceID, pending: pending)

            case .viewport:
                guard !result.lines.isEmpty else {
                    return abortRefresh(surfaceID: surfaceID, generation: generation, reason: "viewport-empty")
                }
                pending.captureLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                return requestSurfaceState(surfaceID: surfaceID, pending: pending)

            case .deepPrimary:
                guard !result.lines.isEmpty else {
                    return abortRefresh(surfaceID: surfaceID, generation: generation, reason: "deep-primary-empty")
                }
                pending.captureLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                let gridSurfaceNeedsFreshViewport = surface.declaration.presentation == .grid
                if gridSurfaceNeedsFreshViewport
                    || (size?.rows).map({ $0 > 0 && result.lines.count > $0 }) == true {
                    return [
                        sendCaptureCommand(
                            RenderCommands.renderedPaneMetadata(target: pending.target),
                            surfaceID: surfaceID,
                            generation: generation,
                            phase: .settledPrimaryMetadata
                        ),
                        sendCaptureCommand(
                            RenderCommands.viewport(target: pending.target),
                            surfaceID: surfaceID,
                            generation: generation,
                            phase: .settledPrimaryViewport
                        ),
                    ]
                }
                return requestSurfaceState(surfaceID: surfaceID, pending: pending)

            case .settledPrimaryMetadata:
                guard let line = result.lines.first(where: { !$0.isEmpty }),
                      let settled = TmuxRenderedPaneStateParser.parse(line),
                      settled.paneId == pending.metadata?.paneId,
                      !settled.paneInAltScreen
                else {
                    return restartRefresh(surfaceID: surfaceID, pending: pending, reason: "deep-primary-settled-state")
                }
                pending.metadata = settled
                surface.pending = pending
                surfaces[surfaceID] = surface
                return []

            case .settledPrimaryViewport:
                guard !result.lines.isEmpty,
                      pending.metadata?.paneInAltScreen == false
                else {
                    return abortRefresh(surfaceID: surfaceID, generation: generation, reason: "deep-scrub-empty")
                }
                pending.scrubLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                return requestSurfaceState(surfaceID: surfaceID, pending: pending)

            case .deepAltHistory:
                pending.historyLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                return [sendCaptureCommand(
                    RenderCommands.savedPrimary(target: pending.target),
                    surfaceID: surfaceID,
                    generation: generation,
                    phase: .savedPrimary
                )]

            case .savedPrimary:
                pending.savedPrimaryLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                return [
                    sendCaptureCommand(
                        RenderCommands.renderedPaneMetadata(target: pending.target),
                        surfaceID: surfaceID,
                        generation: generation,
                        phase: .settledAltMetadata
                    ),
                    sendCaptureCommand(
                        RenderCommands.viewport(target: pending.target),
                        surfaceID: surfaceID,
                        generation: generation,
                        phase: .settledAltViewport
                    ),
                ]

            case .settledAltMetadata:
                guard let line = result.lines.first(where: { !$0.isEmpty }),
                      let settled = TmuxRenderedPaneStateParser.parse(line),
                      settled.paneId == pending.metadata?.paneId,
                      settled.paneInAltScreen
                else {
                    return restartRefresh(surfaceID: surfaceID, pending: pending, reason: "deep-alt-settled-state")
                }
                pending.metadata = settled
                surface.pending = pending
                surfaces[surfaceID] = surface
                return []

            case .settledAltViewport:
                guard !result.lines.isEmpty,
                      pending.metadata?.paneInAltScreen == true
                else {
                    return abortRefresh(surfaceID: surfaceID, generation: generation, reason: "deep-alt-viewport-empty")
                }
                pending.altScreenLines = result.lines
                pending.captureLines = result.lines
                surface.pending = pending
                surfaces[surfaceID] = surface
                return requestSurfaceState(surfaceID: surfaceID, pending: pending)

            case .moshMetadata(let depth, let placement):
                guard let line = result.lines.first(where: { !$0.isEmpty }),
                      let metadata = TmuxRenderedPaneStateParser.parse(line),
                      metadata.paneId == pending.owner.paneID
                else {
                    let head = result.lines.first(where: { !$0.isEmpty }) ?? ""
                    return [.diagnostic(
                        "render-ledger side-channel-metadata-rejected surface=\(surfaceID)"
                            + " target=\(pending.target) owner=\(pending.owner.paneID?.description ?? "none")"
                            + " lines=\(result.lines.count) head=\(TmuxWireEvidence.snippet(head, limit: 200))"
                    )] + finishMoshFailure(surfaceID: surfaceID, reason: "metadata")
                }
                if metadata.paneInAltScreen {
                    // A deepen under a presented page ends here, but its
                    // reader keeps reading that page (and its anchor, for a
                    // deepen once the pane is back on its primary screen).
                    if surface.sideChannel.revealed && surface.sideChannel.hasSynthesizedHistory {
                        return endSideChannelDeepen(surfaceID: surfaceID, reason: "alternate-screen", keepAnchor: true)
                    }
                    return finishMoshFailure(surfaceID: surfaceID, reason: "alternate-screen")
                }
                pending.metadata = metadata
                pending.phase = .moshCapture(depth: depth, placement: placement)
                surface.pending = pending
                surfaces[surfaceID] = surface
                // The capture is already queued behind this metadata query.
                // A rejected metadata reply retires the generation, so its
                // prefetched capture is discarded by the stale-reply guard.
                return []

            case .moshCapture(let depth, let placement):
                guard !result.lines.isEmpty else {
                    return finishMoshFailure(surfaceID: surfaceID, reason: "capture-empty")
                }
                pending.captureLines = result.lines
                pending.phase = .awaitingSurfaceState(request: 0)
                surface.pending = pending
                surfaces[surfaceID] = surface
                return requestSurfaceState(
                    surfaceID: surfaceID,
                    pending: pending,
                    moshDepth: depth,
                    moshPlacement: placement
                )

            case .waitingForQueue, .awaitingSurfaceState:
                return [.diagnostic("render-ledger unexpected-command-phase surface=\(surfaceID)")]
            }
        case .discard:
            return []
        case .clientSizeAdvertisement(let columns, let rows):
            guard !result.success else { return [] }
            // Only the newest advertisement is withdrawn; a younger `-C` that
            // tmux accepted still stands.
            if advertisedClientSize?.columns == columns, advertisedClientSize?.rows == rows {
                advertisedClientSize = nil
            }
            return [.diagnostic("render-ledger client-size-rejected columns=\(columns) rows=\(rows)")]
        }
    }

    private mutating func beginCaptureAfterMetadata(
        surfaceID: SurfaceId,
        pending: PendingRefresh
    ) -> [RenderEffect] {
        guard let metadata = pending.metadata else { return [] }
        // A deepen asks for more history than the first fill; every other
        // capture keeps the established depth.
        let depth = pending.historyDepth ?? inlineHistoryDepth
        switch pending.stage {
        case .viewport, .viewportOnly:
            // Already on the wire behind the metadata query.
            guard !pending.capturePipelined else { return [] }
            return [sendCaptureCommand(
                RenderCommands.viewport(target: pending.target),
                surfaceID: surfaceID,
                generation: pending.generation,
                phase: .viewport
            )]
        case .deep where !metadata.paneInAltScreen:
            return [sendCaptureCommand(
                RenderCommands.deepPrimary(target: pending.target, depth: depth),
                surfaceID: surfaceID,
                generation: pending.generation,
                phase: .deepPrimary
            )]
        case .deep:
            if (metadata.historySize ?? 0) > 0 {
                return [sendCaptureCommand(
                    RenderCommands.deepAltHistory(target: pending.target, depth: depth),
                    surfaceID: surfaceID,
                    generation: pending.generation,
                    phase: .deepAltHistory
                )]
            }
            return [sendCaptureCommand(
                RenderCommands.savedPrimary(target: pending.target),
                surfaceID: surfaceID,
                generation: pending.generation,
                phase: .savedPrimary
            )]
        }
    }

    /// A surface commits a new grid only once its layout settles (iOS holds
    /// a resize for the settle interval), so a capture can finish while the
    /// surface still has the previous layout's grid. A stale width wraps
    /// captures differently from the pane. Painted into a taller grid, the
    /// frame leaves the pane's newest history row on screen above the pane, where the grid
    /// scrub's erase-display loses it; into a shorter one, the pane's top
    /// rows scroll into history. Ask the surface again shortly instead.
    /// Output meanwhile queues behind the frame, as during any surface hop.
    private mutating func awaitSurfaceGrid(
        surfaceID: SurfaceId,
        pending suppliedPending: PendingRefresh,
        mismatch: GridMismatch
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              var pending = surface.pending,
              pending.generation == suppliedPending.generation
        else { return [] }
        var effects: [RenderEffect] = []
        if pending.surfaceGridPolls == 0 {
            effects.append(.diagnostic(
                "render-ledger surface-grid-wait surface=\(surfaceID) \(mismatch.evidence)"
            ))
        }
        pending.surfaceGridPolls += 1
        // No request is outstanding while the timer runs; requests start at 1.
        pending.phase = .awaitingSurfaceState(request: 0)
        surface.pending = pending
        surfaces[surfaceID] = surface
        let token = allocateTimer(.surfaceGrid(surfaceID: surfaceID, generation: pending.generation))
        effects.append(.armTimer(token: token, milliseconds: configuration.surfaceGridPollMilliseconds))
        return effects
    }

    private mutating func requestSurfaceState(
        surfaceID: SurfaceId,
        pending suppliedPending: PendingRefresh,
        moshDepth: Int? = nil,
        moshPlacement: RenderHistoryPlacement? = nil
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              var pending = surface.pending,
              pending.generation == suppliedPending.generation
        else { return [] }
        let request = allocateSurfaceRequest()
        pending.phase = .awaitingSurfaceState(request: request)
        if let moshDepth {
            pending.reason = "mosh:\(moshDepth):\((moshPlacement ?? .bottom).rawValue)"
        }
        surface.pending = pending
        surfaces[surfaceID] = surface
        return [.resolveSurfaceState(surfaceID, request: request)]
    }

    private mutating func resolvedSurfaceState(
        surfaceID: SurfaceId,
        request: UInt64,
        altScreen: Bool,
        columns: Int,
        rows: Int
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              let pending = surface.pending,
              case .awaitingSurfaceState(let expectedRequest) = pending.phase,
              request == expectedRequest,
              profile != nil
        else { return [.diagnostic("render-ledger stale-surface-state surface=\(surfaceID) request=\(request)")] }

        if pending.sizeEpoch != sizeEpoch,
           pending.sizeResyncAttempts < configuration.maximumSizeResyncAttempts,
           profile == .inline {
            var retry = pending
            retry.sizeResyncAttempts += 1
            retry.sizeEpoch = sizeEpoch
            retry.phase = .metadata
            retry.metadata = nil
            retry.captureLines = []
            retry.historyLines = []
            retry.savedPrimaryLines = []
            retry.altScreenLines = nil
            retry.scrubLines = nil
            retry.surfaceGridPolls = 0
            // A fresh capture includes every byte that followed the stale
            // capture's cut, so replaying this tail as well would duplicate it.
            retry.postCaptureOutput = []
            retry.postCaptureOutputOverflowed = false
            // The first metadata/capture pair was answered; this one is new.
            retry.capturePipelined = false
            surface.pending = retry
            surfaces[surfaceID] = surface
            return [
                .diagnostic("render-ledger size-resync surface=\(surfaceID) attempt=\(retry.sizeResyncAttempts)"),
            ] + sendMetadataQuery(surfaceID: surfaceID)
        }

        if pending.sizeEpoch != sizeEpoch, profile == .inline {
            // Never paint metadata/capture rows that are known to describe a
            // different grid. The bounded immediate resync budget is
            // exhausted; leave the existing surface untouched and let a
            // subsequent lifecycle/layout/manual refresh establish a stable
            // cut. Keeping this pending latch also prevents live output from
            // turning the incomplete frame into a new source of truth.
            var retainedPending = pending
            retainedPending.completionCorrelation = nil
            surface.pending = retainedPending
            surfaces[surfaceID] = surface
            var effects: [RenderEffect] = [.diagnostic(
                "render-ledger size-resync-gave-up surface=\(surfaceID) attempts=\(pending.sizeResyncAttempts)"
            )]
            if let failure = correlatedRefreshFailure(
                surfaceID: surfaceID,
                pending: pending,
                reason: "size-resync-exhausted"
            ) {
                effects.append(failure)
            }
            // This branch stops issuing traffic and keeps the pending cut, so
            // no later completion is guaranteed for this capture. Release the
            // reader's gesture here rather than leaving it latched until some
            // unrelated lifecycle refresh happens to supersede the cut.
            effects.append(contentsOf: settleInlineHistoryAfterTermination(
                surfaceID: surfaceID,
                pending: pending
            ))
            return effects
        }

        if pending.postCaptureOutputOverflowed {
            // The authoritative capture predates at least one byte we could
            // not retain. Start a new cut instead of presenting a frame with a
            // silent hole. This path is independently bounded by the byte cap:
            // each retry discards the old tail because the new capture
            // contains it.
            surface.pending = nil
            if pending.deepensAfterRebuild {
                // Still paying a relayout skipped while yielded (P7), as a
                // restart or a retry is: the new cut is that rebuild.
                surface.repaintOwedSinceYield = true
                hasRepaintOwedSinceYield = true
            }
            surfaces[surfaceID] = surface
            var effects: [RenderEffect] = [.diagnostic(
                "render-ledger post-capture-output-resync surface=\(surfaceID)"
            )]
            effects.append(contentsOf: requestRefresh(
                surfaceID: surfaceID,
                stage: pending.stage,
                reason: "post-capture-output-resync",
                continuityBreak: pending.stage != .viewportOnly,
                completionCorrelation: pending.completionCorrelation,
                historyDepth: pending.historyDepth,
                // The new cut spends only what is left of the grid wait, so
                // output that overflows every wait cannot keep a surface
                // with a lasting mismatch from ever painting.
                surfaceGridPolls: pending.surfaceGridPolls
            ))
            return effects
        }

        guard let metadata = pending.metadata else {
            return abortRefresh(surfaceID: surfaceID, generation: pending.generation, reason: "missing-metadata")
        }
        let clientRows = rows > 0 ? rows : size?.rows
        let isMosh = profile == .sideChannel
        var gridEffects: [RenderEffect] = []
        // Compare only dimensions known on both sides. Older tmux metadata
        // lacks the pane grid, and a surface can temporarily report zero;
        // neither is evidence that its known dimension disagrees.
        let paneColumns = columns > 0 ? metadata.paneWidth : nil
        let paneRows = rows > 0 ? metadata.paneHeight : nil
        let mismatch = GridMismatch(
            surfaceColumns: paneColumns != nil ? columns : nil,
            paneColumns: paneColumns,
            surfaceRows: paneRows != nil ? rows : nil,
            paneRows: paneRows,
            sizeEpoch: sizeEpoch
        )
        if !isMosh, mismatch.hasDimensions {
            if mismatch.matches {
                surface.persistentGridMismatch = nil
                if pending.surfaceGridPolls > 0 {
                    gridEffects.append(.diagnostic(
                        "render-ledger surface-grid-settled surface=\(surfaceID) \(mismatch.evidence) polls=\(pending.surfaceGridPolls)"
                    ))
                }
            } else if surface.persistentGridMismatch != mismatch {
                let waited = pending.surfaceGridPolls * configuration.surfaceGridPollMilliseconds
                if waited < configuration.surfaceGridWaitMilliseconds {
                    return awaitSurfaceGrid(surfaceID: surfaceID, pending: pending, mismatch: mismatch)
                }
                surface.persistentGridMismatch = mismatch
                gridEffects.append(.diagnostic(
                    "render-ledger surface-grid-wait-expired surface=\(surfaceID) \(mismatch.evidence) waitedMs=\(waited)"
                ))
            }
        }
        // A revealed page is a point-in-time read, even when SSP reports no
        // framebuffer difference (identical scrolling rows or a hidden pane).
        // Align every available anchor on deepen, using fresh tmux metadata
        // rather than painter activity to preserve its distance from the end.
        var captureLines = pending.captureLines
        var anchoredDeepen: String?
        let historyChanged = metadata.historySize.map { $0 != surface.sideChannel.anchorHistorySize } ?? false
        let preservesRevealedPage = surface.sideChannel.revealed
            && surface.sideChannel.hasSynthesizedHistory
            && (surface.sideChannel.historyAnchor != nil || historyChanged)
        if isMosh, surface.sideChannel.frozen || preservesRevealedPage {
            // Output scrolled this many rows into tmux history since the page.
            let expectedShift = metadata.historySize.map { $0 - surface.sideChannel.anchorHistorySize }
            let alignment: SideChannelHistoryAnchor.Alignment
            switch surface.sideChannel.historyAnchor?.aligning(captureLines, expectedShift: expectedShift)
                ?? .failure(.lost) {
            case .success(let found):
                alignment = found
            case .failure(let failure):
                return endSideChannelDeepen(surfaceID: surfaceID, reason: failure.rawValue, keepAnchor: false)
            }
            anchoredDeepen = "dropped=\(alignment.dropped) expected=\(expectedShift.map(String.init) ?? "-")"
                + " anchor=\(alignment.wholePage ? "page" : "newest")"
            captureLines = alignment.lines
        }
        let refreshesInPlace = !isMosh
            && pending.stage == .viewportOnly
            && surface.owner?.windowID == pending.owner.windowID
            && surface.owner?.paneID == pending.owner.paneID
            && altScreen == metadata.paneInAltScreen
        let bytes = TmuxRepaintAssembly.assemble(
            state: metadata,
            captureLines: captureLines,
            historyLines: pending.historyLines,
            savedPrimaryLines: pending.savedPrimaryLines,
            altScreenLines: pending.altScreenLines,
            terminalIsInAltScreen: altScreen,
            clientRows: clientRows,
            paneRows: isMosh ? nil : metadata.paneHeight,
            preservePrimaryDuringAltRefresh: refreshesInPlace && metadata.paneInAltScreen
        )
        guard let reference = retain(
            bytes: bytes,
            surfaceID: surfaceID,
            generation: pending.generation
        ) else {
            return abortRefresh(
                surfaceID: surfaceID,
                generation: pending.generation,
                reason: "render-bytes-too-large"
            )
        }
        var effects = gridEffects
        if let anchoredDeepen {
            // Rows that scrolled into history since the frozen page.
            effects.append(.diagnostic(
                "render-ledger side-channel-anchored-deepen surface=\(surfaceID) \(anchoredDeepen)"
            ))
        }

        if !refreshesInPlace {
            if let oldWindow = surface.owner?.windowID {
                effects.append(.saveWindowModes(surfaceID, window: oldWindow))
            }
            effects.append(.bindSurface(surfaceID, owner: pending.owner))
        }
        // Foreground bytes belong immediately before the authoritative frame.
        // Preserve the pre-refresh cut exactly as the platform controller
        // historically did. An in-place repair needs no bind, while a newly
        // mounted grid surface binds before the replay. The authoritative
        // frame follows immediately and restores the exact terminal state.
        if !isMosh, pending.foregroundRecovery {
            let isProvisionalSingleSurfaceAttach = !isInitialRenderReady
                && surface.owner == nil
                && surface.declaration.presentation == .single
            if !isProvisionalSingleSurfaceAttach,
               let retained = takeCoalescedOutput(for: metadata.paneId),
               !retained.isEmpty,
               let replayReference = retain(
                   bytes: retained,
                   surfaceID: surfaceID,
                   generation: pending.generation
               ) {
                effects.append(.feed(
                    surfaceID,
                    owner: pending.owner,
                    bytes: replayReference,
                    source: .foregroundReplay
                ))
            } else if isProvisionalSingleSurfaceAttach {
                // The first single-surface capture already contains every
                // byte before its FIFO cut. Replaying provisional boot output
                // would duplicate it immediately before that source of truth.
                _ = takeCoalescedOutput(for: metadata.paneId)
            }
        }
        let source: RenderFeedSource
        if isMosh {
            source = .moshHistory
        } else {
            switch pending.stage {
            case .viewport: source = .viewportRepaint
            case .viewportOnly: source = .viewportRefresh
            case .deep: source = .deepRepaint
            }
        }
        effects.append(.feed(surfaceID, owner: pending.owner, bytes: reference, source: source))

        let requiresGridScrub = surface.declaration.presentation == .grid
        let deepCaptureExceedsViewport = clientRows.map {
            $0 > 0 && pending.captureLines.count > $0
        } ?? false
        if !isMosh,
           pending.stage == .deep,
           !metadata.paneInAltScreen,
           !altScreen,
           let scrubLines = pending.scrubLines,
           requiresGridScrub || deepCaptureExceedsViewport {
            let scrubBytes = TmuxRepaintAssembly.assemble(
                state: metadata,
                captureLines: scrubLines,
                historyLines: [],
                savedPrimaryLines: [],
                altScreenLines: nil,
                terminalIsInAltScreen: false,
                clientRows: clientRows,
                paneRows: metadata.paneHeight
            )
            if let scrubReference = retain(
                bytes: scrubBytes,
                surfaceID: surfaceID,
                generation: pending.generation
            ) {
                effects.append(.feed(
                    surfaceID,
                    owner: pending.owner,
                    bytes: scrubReference,
                    source: .repaintScrub
                ))
            } else {
                effects.append(.diagnostic("render-ledger scrub-bytes-too-large surface=\(surfaceID)"))
            }
        }

        if let windowID = pending.owner.windowID {
            effects.append(.restoreWindowModes(
                surfaceID,
                window: windowID,
                paneInAltScreen: metadata.paneInAltScreen
            ))
        }
        if !isMosh,
           !pending.postCaptureOutput.isEmpty,
           let liveReference = retain(bytes: pending.postCaptureOutput) {
            effects.append(.feed(
                surfaceID,
                owner: pending.owner,
                bytes: liveReference,
                source: .paneOutput
            ))
        }
        if !isMosh, let correlation = pending.completionCorrelation {
            effects.append(.refreshCompleted(
                surfaceID,
                owner: pending.owner,
                stage: pending.stage,
                correlation: correlation
            ))
        }
        let identityChanged = surface.owner.map {
            $0.windowID != pending.owner.windowID || $0.paneID != pending.owner.paneID
        } ?? false
        let rebound = surface.owner != pending.owner
        surface.owner = pending.owner
        surface.renderedPaneInAltScreen = metadata.paneInAltScreen
        surface.pending = nil
        surface.retryAttemptsByStage[pending.stage] = nil

        if isMosh {
            let components = pending.reason.split(separator: ":", omittingEmptySubsequences: false)
            let depth = components.count > 1 ? Int(components[1]) ?? configuration.moshPageDepth : configuration.moshPageDepth
            let placement = components.count > 2
                ? RenderHistoryPlacement(rawValue: String(components[2])) ?? .bottom
                : .bottom
            let historySize = max(0, metadata.historySize ?? max(0, pending.captureLines.count - rows))
            let creditedDepth = historySize <= depth ? max(depth, configuration.scrollbackLimit) : depth
            surface.sideChannel.depth = max(surface.sideChannel.depth, creditedDepth)
            let droppedHistoryRows = pending.captureLines.count - captureLines.count
            surface.sideChannel.anchorHistorySize = max(0, historySize - droppedHistoryRows)
            // A capture of part of the history held exactly `depth` history
            // rows above the visible grid; its newest ones anchor every
            // deeper read of this point-in-time page.
            surface.sideChannel.historyAnchor = historySize > depth
                ? SideChannelHistoryAnchor(
                    captureLines: captureLines,
                    historyRows: depth - droppedHistoryRows
                )
                : nil
            // The feed and historyReady effects are staged work, not proof
            // that a platform renderer accepted these bytes. Keep the reader
            // unrevealed until the adapter submits the exact owner ack.
            surface.sideChannel.hasSynthesizedHistory = false
            surface.sideChannel.revealed = false
            surface.sideChannel.frozen = false
            surface.sideChannel.pendingPresentationOwner = pending.owner
            surface.sideChannel.outputWhilePresentationPending = false
            surface.sideChannel.inFlightEpoch = nil
            if let token = surface.sideChannel.watchdogToken {
                timerPurposes.removeValue(forKey: token)
                effects.append(.cancelTimer(token: token))
            }
            surface.sideChannel.watchdogToken = nil
            surface.sideChannel.requestedIntent = sideChannelCaptureIntent(from: pending)
            // Ask the painter to restore its authoritative live viewport
            // before presentation reveals the synthesized history.  Both
            // effects are still after the owned history feed; ordering them
            // this way lets a suspending platform adapter preserve the batch
            // contract without exposing an overlay over a stale live frame.
            effects.append(.requestTransportFullFrame)
            effects.append(.historyReady(
                surfaceID,
                owner: pending.owner,
                depth: creditedDepth,
                historySize: historySize,
                placement: placement
            ))
        } else {
            if identityChanged {
                surface.inlineHistory.resetForNewIdentity()
            } else if rebound, pending.stage != .deep {
                // A fresh owner makes the platform clear the surface's
                // scrollback, and a visible capture puts none back, so the
                // credit an earlier deep capture earned no longer describes
                // what the reader can scroll through. Until a deep capture
                // credits it again (the one chained below, or the reader's
                // own deepen), a scroll-up must fetch history rather than be
                // told the surface already holds all of it.
                surface.inlineHistory.resetForNewIdentity()
            }
            if !isInitialRenderReady {
                isInitialRenderReady = true
                effects.append(contentsOf: cancelInitialWatchdog())
                effects.append(.initialRenderReady)
            }
            if pausedPanes.remove(metadata.paneId) != nil {
                effects.append(enqueueLedgerCommand(RenderCommands.continuePane(metadata.paneId), purpose: nil))
            }
            if pending.stage == .deep {
                // A capture whose reply covered the pane's whole history is
                // credited with the full ladder depth rather than the depth it
                // happened to ask for, so a small pane is exhausted at the
                // first fill and a later shallow repaint cannot un-exhaust it.
                let depth = pending.historyDepth ?? inlineHistoryDepth
                let historySize = max(0, metadata.historySize ?? max(0, pending.captureLines.count - rows))
                let creditedDepth = historySize <= depth ? fullInlineDepth : depth
                let canDeepen = creditedDepth < fullInlineDepth && historySize > creditedDepth
                surface.inlineHistory.creditedDepth = creditedDepth
                surface.inlineHistory.historySize = historySize
                surface.inlineHistory.canDeepen = canDeepen
                surface.inlineHistory.deepenRequestedWhilePending = false
                effects.append(.inlineHistorySettled(
                    surfaceID,
                    owner: pending.owner,
                    depth: creditedDepth,
                    historySize: historySize,
                    canDeepen: canDeepen
                ))
            } else if surface.inlineHistory.deepenRequestedWhilePending {
                // A gesture arrived while this shallower refresh held the
                // surface. It captured no new history, but it is the terminal
                // outcome the reader is waiting on, so answer with what the
                // surface currently knows.
                surface.inlineHistory.deepenRequestedWhilePending = false
                effects.append(.inlineHistorySettled(
                    surfaceID,
                    owner: pending.owner,
                    depth: surface.inlineHistory.creditedDepth,
                    historySize: surface.inlineHistory.historySize,
                    canDeepen: surface.inlineHistory.canDeepen
                ))
            }
        }
        surfaces[surfaceID] = surface

        let chainsDeepRebuild = (surface.declaration.presentation == .single || pending.deepensAfterRebuild)
            && (pending.stage == .viewport
                || (pending.stage == .viewportOnly && !refreshesInPlace))
        if !isMosh, chainsDeepRebuild, snapshot?.authority.isPeer == true {
            // P8: the visible rows are painted; the history deepening waits
            // until no peer holds the grid. During a take-back that is the
            // claim's settlement, so the claim's stamp commit never queues
            // behind a 2,000-row capture.
            surfaces[surfaceID]?.deepRebuildOwedSinceYield = true
            hasRepaintOwedSinceYield = true
            effects.append(contentsOf: finishForegroundIfPossible())
        } else if !isMosh, chainsDeepRebuild {
            effects.append(contentsOf: requestRefresh(
                surfaceID: surfaceID,
                stage: .deep,
                reason: "\(pending.reason)-deep",
                continuityBreak: false
            ))
        } else if !isMosh {
            effects.append(contentsOf: finishForegroundIfPossible())
        }
        return effects
    }

    private mutating func transportOutputObserved(
        _ sourceSurfaceID: SurfaceId,
        owner: RenderOwner
    ) -> [RenderEffect] {
        guard profile == .sideChannel,
              let source = surfaces[sourceSurfaceID],
              source.declaration.presentation != .grid,
              source.owner == owner,
              let windowID = owner.windowID,
              snapshot?.activeWindowID == windowID
        else { return [] }
        // SSP carries the complete tmux window, not an individual pane. A
        // detached reader and the live surface share this activity source,
        // while a parked reader for another window remains untouched. Either
        // one's owner can vouch for the window: a split's painter shows
        // several panes, so only its pane readers are ever bound.
        var effects: [RenderEffect] = []
        for surfaceID in surfaceOrder where surfaces[surfaceID]?.owner?.windowID == windowID {
            effects.append(contentsOf: sideChannelOutputObserved(surfaceID))
        }
        return effects
    }

    private mutating func sideChannelOutputObserved(_ surfaceID: SurfaceId) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID] else { return [] }
        if surface.sideChannel.revealed && surface.sideChannel.hasSynthesizedHistory {
            // A frozen page does not change again on subsequent heartbeats.
            guard !surface.sideChannel.frozen else { return [] }
            surface.sideChannel.frozen = true
            surface.sideChannel.requestedIntent = nil
            if let token = surface.sideChannel.watchdogToken {
                timerPurposes.removeValue(forKey: token)
            }
            surface.sideChannel.watchdogToken = nil
            surface.sideChannel.inFlightEpoch = nil
            surface.pending = nil
            surfaces[surfaceID] = surface
            return [.diagnostic("render-ledger side-channel-frozen surface=\(surfaceID)")]
        }
        if surface.sideChannel.pendingPresentationOwner != nil {
            surface.sideChannel.outputWhilePresentationPending = true
            surfaces[surfaceID] = surface
            return []
        }
        // Keep an already-queued point-in-time capture revealable, even for a
        // chatty window. Activity freezes it only after its presentation cut.
        if surface.sideChannel.inFlightEpoch != nil { return [] }
        if surface.sideChannel.hasSynthesizedHistory {
            surface.sideChannel.hasSynthesizedHistory = false
            bumpOwnerEpoch(&surface)
            surfaces[surfaceID] = surface
        }
        return []
    }

    private mutating func handlePaneOutput(
        paneID: PaneId,
        bytes: [UInt8],
        snapshot suppliedSnapshot: TmuxSnapshot
    ) -> [RenderEffect] {
        // tmux can legally report an empty `%output` record. It carries no
        // render information and must not freeze side-channel history, consume
        // a render-byte reference, or grow an ABI adapter's retained-ref table.
        guard !bytes.isEmpty else { return [] }
        if profile == .sideChannel {
            guard !isProgramStatusPaneOutput else { return [] }
            // Compatibility with servers predating the no-output client flag.
            guard let surfaceID = surfaceID(for: paneID, snapshot: suppliedSnapshot) else { return [] }
            return sideChannelOutputObserved(surfaceID)
        }
        guard profile == .inline else { return [] }
        var framer = liveOutputFramers[paneID] ?? TmuxLiveOutputFramer()
        let bytes = framer.process(bytes)
        liveOutputFramers[paneID] = framer.isGround ? nil : framer
        guard !bytes.isEmpty else { return [] }
        guard let surfaceID = surfaceID(for: paneID, snapshot: suppliedSnapshot),
              var surface = surfaces[surfaceID]
        else {
            // The foreground barrier is session-wide, so it must retain
            // output through the intentional grid mount interval where no
            // surface is declared yet.
            if isAppInactive || isForegroundOutputCoalescing {
                coalesce(paneID: paneID, bytes: bytes)
            }
            guard !reportedUnroutedOutput else { return [] }
            reportedUnroutedOutput = true
            return [.diagnostic(
                "render-ledger output-unrouted pane=\(paneID) bytes=\(bytes.count)"
                    + " ready=\(isInitialRenderReady) surfaces=\(surfaceOrder.count) queue=\(commandQueue.pendingCount)"
            )]
        }
        // Once a capture reply has crossed the FIFO, later output belongs
        // after that exact frame even while the session-wide foreground
        // barrier remains raised. Retain it on the pending transaction before
        // consulting the generic coalescer; an overflow recapture deliberately
        // leaves the pane's old coalesced marker saturated.
        if var pending = surface.pending,
           case .awaitingSurfaceState = pending.phase {
            guard pending.metadata?.paneId == paneID else { return [] }
            let byteLimit = min(
                configuration.maximumForegroundOutputBytes,
                configuration.maximumRenderBytes
            )
            let retainedForegroundBytes = surfaces.values.reduce(
                min(coalescedByteCount, byteLimit)
            ) { total, candidate in
                min(
                    byteLimit,
                    total + min(
                        candidate.pending?.postCaptureOutput.count ?? 0,
                        byteLimit
                    )
                )
            }
            if !pending.postCaptureOutputOverflowed,
               bytes.count <= byteLimit,
               retainedForegroundBytes <= byteLimit - bytes.count {
                pending.postCaptureOutput.append(contentsOf: bytes)
                surface.pending = pending
                surfaces[surfaceID] = surface
                return []
            }
            pending.postCaptureOutput.removeAll(keepingCapacity: false)
            let firstOverflow = !pending.postCaptureOutputOverflowed
            pending.postCaptureOutputOverflowed = true
            surface.pending = pending
            surfaces[surfaceID] = surface
            return firstOverflow
                ? [.diagnostic("render-ledger post-capture-output-overflow surface=\(surfaceID)")]
                : []
        }
        if isAppInactive || isForegroundOutputCoalescing {
            coalesce(paneID: paneID, bytes: bytes)
            return []
        }
        // During attach hydration, `%output` may identify the pane but cannot
        // make a partial terminal authoritative while older discovery replies
        // are still ahead in the shared FIFO. Once hydration drains, the same
        // first-output bind is the safe fail-open path for a newly created
        // single-pane window.
        if !isInitialRenderReady, !commandQueue.isEmpty {
            return []
        }
        if let pending = surface.pending {
            // A viewport-only repair does not move ownership. Before its
            // capture cut, live output keeps flowing through the established
            // owner; viewport/deep refreshes remain intentionally gated.
            guard pending.stage == .viewportOnly,
                  let owner = surface.owner,
                  owner.paneID == paneID,
                  let reference = retain(bytes: bytes)
            else {
                // After the initial render is ready (bound, or failed open)
                // the first-output bind is the only remaining route to a
                // paint; say once when a refresh in flight swallows it.
                guard isInitialRenderReady, surface.owner == nil, !reportedGatedOutput else { return [] }
                reportedGatedOutput = true
                return [.diagnostic(
                    "render-ledger output-gated surface=\(surfaceID) pane=\(paneID) bytes=\(bytes.count)"
                        + " stage=\(pending.stage.rawValue) phase=\(pending.phase.evidenceName) reason=\(pending.reason)"
                )]
            }
            return [.feed(surfaceID, owner: owner, bytes: reference, source: .paneOutput)]
        }
        let owner: RenderOwner
        var bindEffects: [RenderEffect] = []
        if let existing = surface.owner, existing.paneID == paneID {
            owner = existing
        } else if surface.owner == nil,
                  let target = resolvedTarget(for: surfaceID),
                  target.paneID == paneID {
            // A freshly mounted per-pane emulator is allowed to start from its
            // first authenticated `%output`.  The clear/bind is emitted in the
            // same effect batch immediately before that first feed; declaration
            // itself never claims ownership.
            owner = !isInitialRenderReady && surfaceID == .live
                ? RenderOwner(windowID: target.windowID, paneID: paneID, epoch: 0)
                : allocateOwner(windowID: target.windowID, paneID: paneID)
            var updated = surface
            updated.owner = owner
            surfaces[surfaceID] = updated
            bindEffects.append(.bindSurface(surfaceID, owner: owner))
        } else if surface.owner == nil,
                  isInitialRenderReady,
                  surface.declaration.presentation == .single {
            // Initial watchdog fail-open: hydration may not have produced any
            // window yet, but authenticated `%output` still names its pane.
            owner = allocateOwner(
                windowID: suppliedSnapshot.activeWindowID,
                paneID: paneID
            )
            var updated = surface
            updated.owner = owner
            surfaces[surfaceID] = updated
            bindEffects.append(.bindSurface(surfaceID, owner: owner))
        } else {
            return []
        }
        guard let reference = retain(bytes: bytes) else {
            return [.diagnostic("render-ledger pane-output-too-large pane=\(paneID) bytes=\(bytes.count)")]
        }
        bindEffects.append(.feed(surfaceID, owner: owner, bytes: reference, source: .paneOutput))
        if !isInitialRenderReady {
            isInitialRenderReady = true
            bindEffects.append(contentsOf: cancelInitialWatchdog())
            bindEffects.append(.initialRenderReady)
        }
        return bindEffects
    }

    private mutating func handlePause(
        paneID: PaneId,
        snapshot suppliedSnapshot: TmuxSnapshot
    ) -> [RenderEffect] {
        pausedPanes.insert(paneID)
        if isProgramStatusPaneOutput {
            pausedPanes.remove(paneID)
            return [enqueueLedgerCommand(RenderCommands.continuePane(paneID), purpose: nil)]
        }
        guard profile == .inline,
              !isForegroundOutputCoalescing,
              let surfaceID = surfaceID(for: paneID, snapshot: suppliedSnapshot),
              let surface = surfaces[surfaceID],
              surface.owner?.paneID == paneID,
              resolvedTarget(for: surfaceID)?.paneID == paneID,
              surface.pending == nil
        else { return [] }
        var effects = [enqueueLedgerCommand(RenderCommands.continuePane(paneID), purpose: nil)]
        pausedPanes.remove(paneID)
        effects.append(contentsOf: requestRefresh(
            surfaceID: surfaceID,
            stage: .deep,
            reason: "pause-resync",
            continuityBreak: true
        ))
        return effects
    }

    /// The inline (SSH+tmux) rung of the history ladder.
    ///
    /// The side channel deepens by re-capturing through mosh; inline deepens
    /// by re-running the ordinary `.deep` refresh at a greater depth, which
    /// keeps metadata -> capture -> settled scrub, the FIFO cut and the
    /// post-capture output replay identical to every other repaint.
    ///
    /// Every return path is terminal for the reader's gesture: a capture whose
    /// completion settles, an immediate settle, or a diagnostic for a surface
    /// that cannot settle at all because it has no owner to tag one to.
    private mutating func requestInlineHistoryDeepen(
        surfaceID: SurfaceId,
        reason: String
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID] else {
            return [.diagnostic(
                "render-ledger inline-history-request-ignored surface=\(surfaceID) reason=unknown-surface"
            )]
        }
        // Without an owner there is nothing to tag a settle to, and the
        // platform has no transcript for this surface to place rows into.
        guard let owner = surface.owner else {
            return [.diagnostic(
                "render-ledger inline-history-request-ignored surface=\(surfaceID) reason=unowned"
            )]
        }
        guard resolvedRefreshTarget(for: surfaceID) != nil else {
            return [.diagnostic(
                "render-ledger inline-history-request-ignored surface=\(surfaceID) reason=target-unavailable"
            )]
        }
        if surface.pending != nil {
            // Single-flight: the refresh already holding this surface owns the
            // next terminal outcome, and that outcome settles the gesture.
            surface.inlineHistory.deepenRequestedWhilePending = true
            surfaces[surfaceID] = surface
            return []
        }
        guard surface.inlineHistory.canDeepen else {
            return [.inlineHistorySettled(
                surfaceID,
                owner: owner,
                depth: surface.inlineHistory.creditedDepth,
                historySize: surface.inlineHistory.historySize,
                canDeepen: false
            )]
        }
        return requestRefresh(
            surfaceID: surfaceID,
            stage: .deep,
            reason: reason,
            // The deepened capture replaces the surface's transcript rather
            // than appending to it. A fresh owner epoch is what makes the
            // platform bind clear the local scrollback before the full
            // capture replays into it.
            continuityBreak: true,
            historyDepth: fullInlineDepth
        )
    }

    private mutating func requestSideChannelHistory(
        surfaceID: SurfaceId,
        isInertial: Bool,
        forceFullDepth: Bool
    ) -> [RenderEffect] {
        guard profile == .sideChannel else { return [] }
        guard let surface = surfaces[surfaceID], resolvedTarget(for: surfaceID) != nil else {
            if forceFullDepth { return [] }
            return [.diagnostic("render-ledger side-channel-request-ignored surface=\(surfaceID) reason=unavailable")]
        }
        guard surface.sideChannel.inFlightEpoch == nil,
              surface.sideChannel.pendingPresentationOwner == nil
        else { return [] }
        if surface.sideChannel.frozen {
            if forceFullDepth { return [] }
            // Output froze the reader's page. It can still read deeper when
            // the page's rows can be found again (`SideChannelHistoryAnchor`).
            if surface.sideChannel.historyAnchor == nil {
                return [.diagnostic("render-ledger side-channel-request-ignored surface=\(surfaceID) reason=frozen")]
            }
        }
        if isInertial && !surface.sideChannel.hasSynthesizedHistory { return [] }
        let depth: Int
        if forceFullDepth || surface.sideChannel.depth > 0 {
            depth = max(configuration.moshPageDepth, configuration.scrollbackLimit)
        } else {
            depth = configuration.moshPageDepth
        }
        if surface.sideChannel.depth >= depth {
            if forceFullDepth { return [] }
            return [.diagnostic("render-ledger side-channel-request-ignored surface=\(surfaceID) reason=exhausted")]
        }
        let placement: RenderHistoryPlacement = surface.sideChannel.hasSynthesizedHistory
            ? .preserveDistanceFromBottom
            : .bottom
        return startSideChannelHistory(
            surfaceID: surfaceID,
            depth: depth,
            placement: placement
        )
    }

    private mutating func startSideChannelHistory(
        surfaceID: SurfaceId,
        depth: Int,
        placement: RenderHistoryPlacement
    ) -> [RenderEffect] {
        // A frozen reader reaches this only for an anchored deepen.
        guard profile == .sideChannel,
              var surface = surfaces[surfaceID],
              surface.sideChannel.inFlightEpoch == nil,
              surface.sideChannel.pendingPresentationOwner == nil,
              let target = resolvedTarget(for: surfaceID)
        else { return [] }
        // Every mosh capture contains the complete requested history plus the
        // live viewport.  A deepen therefore replaces the prior capture; it
        // must never append into the same emulator transcript.  Allocate a
        // fresh epoch even when the pane identity is unchanged so the
        // adjacent bind emitted at finish performs the platform clear.
        let owner = allocateOwner(windowID: target.windowID, paneID: target.paneID)
        let generation = allocateGeneration()
        surface.pending = PendingRefresh(
            generation: generation,
            owner: owner,
            stage: .deep,
            reason: "mosh:\(depth):\(placement.rawValue)",
            completionCorrelation: nil,
            target: target.paneID.description,
            sizeEpoch: sizeEpoch,
            foregroundRecovery: false,
            phase: .moshMetadata(depth: depth, placement: placement)
        )
        surface.sideChannel.inFlightEpoch = owner.epoch
        surface.sideChannel.requestedIntent = SideChannelCaptureIntent(
            windowID: target.windowID,
            paneID: target.paneID,
            depth: depth,
            placement: placement
        )
        let watchdog = allocateTimer(.sideChannelWatchdog(surfaceID: surfaceID, epoch: owner.epoch))
        surface.sideChannel.watchdogToken = watchdog
        surfaces[surfaceID] = surface
        return [
            .armTimer(token: watchdog, milliseconds: configuration.sideChannelWatchdogMilliseconds),
            sendCaptureCommand(
                RenderCommands.renderedPaneMetadata(target: target.paneID),
                surfaceID: surfaceID,
                generation: generation,
                phase: .moshMetadata(depth: depth, placement: placement)
            ),
            // Both commands target the same immutable pane ID and tmux replies
            // in FIFO order. Queue them together to avoid another network round
            // trip on every reveal, including re-entry after returning to tail.
            sendCaptureCommand(
                RenderCommands.moshHistory(target: target.paneID, depth: depth),
                surfaceID: surfaceID,
                generation: generation,
                phase: .moshCapture(depth: depth, placement: placement)
            ),
        ]
    }

    private func sideChannelCaptureIntent(
        from pending: PendingRefresh?
    ) -> SideChannelCaptureIntent? {
        guard let pending,
              let windowID = pending.owner.windowID,
              let paneID = pending.owner.paneID
        else { return nil }
        switch pending.phase {
        case .moshMetadata(let depth, let placement),
             .moshCapture(let depth, let placement):
            return SideChannelCaptureIntent(
                windowID: windowID,
                paneID: paneID,
                depth: depth,
                placement: placement
            )
        case .awaitingSurfaceState:
            let components = pending.reason.split(
                separator: ":",
                omittingEmptySubsequences: false
            )
            guard components.count > 2,
                  components[0] == "mosh",
                  let depth = Int(components[1])
            else { return nil }
            let placement = RenderHistoryPlacement(rawValue: String(components[2])) ?? .bottom
            return SideChannelCaptureIntent(
                windowID: windowID,
                paneID: paneID,
                depth: depth,
                placement: placement
            )
        default:
            return nil
        }
    }

    private mutating func historyPresented(
        _ surfaceID: SurfaceId,
        owner: RenderOwner
    ) -> [RenderEffect] {
        guard profile == .sideChannel,
              var surface = surfaces[surfaceID],
              surface.owner == owner,
              surface.sideChannel.pendingPresentationOwner == owner
        else {
            return [.diagnostic("render-ledger history-presented-stale surface=\(surfaceID)")]
        }
        let freezeAfterPresentation = surface.sideChannel.outputWhilePresentationPending
        surface.sideChannel.pendingPresentationOwner = nil
        surface.sideChannel.outputWhilePresentationPending = false
        surface.sideChannel.hasSynthesizedHistory = true
        surface.sideChannel.revealed = true
        surface.sideChannel.frozen = freezeAfterPresentation
        if freezeAfterPresentation {
            surface.sideChannel.requestedIntent = nil
        }
        surfaces[surfaceID] = surface
        if freezeAfterPresentation {
            return [.diagnostic("render-ledger side-channel-frozen-after-presentation surface=\(surfaceID)")]
        }
        return []
    }

    private mutating func historyPresentationFailed(
        _ surfaceID: SurfaceId,
        owner: RenderOwner
    ) -> [RenderEffect] {
        guard profile == .sideChannel,
              var surface = surfaces[surfaceID],
              surface.owner == owner,
              surface.sideChannel.pendingPresentationOwner == owner
        else {
            return [.diagnostic("render-ledger history-presentation-failed-stale surface=\(surfaceID)")]
        }
        surface.pending = nil
        surface.sideChannel.depth = 0
        surface.sideChannel.historyAnchor = nil
        surface.sideChannel.anchorHistorySize = 0
        surface.sideChannel.hasSynthesizedHistory = false
        surface.sideChannel.revealed = false
        surface.sideChannel.frozen = false
        surface.sideChannel.inFlightEpoch = nil
        surface.sideChannel.watchdogToken = nil
        surface.sideChannel.pendingPresentationOwner = nil
        surface.sideChannel.outputWhilePresentationPending = false
        surface.sideChannel.requestedIntent = nil
        surfaces[surfaceID] = surface
        return [.diagnostic("render-ledger history-presentation-failed surface=\(surfaceID)")]
            + issueTransportFullFrameReservation(surfaceID: surfaceID)
    }

    private mutating func returnedToTail(_ surfaceID: SurfaceId) -> [RenderEffect] {
        guard profile == .sideChannel,
              var surface = surfaces[surfaceID]
        else { return [] }
        var effects: [RenderEffect] = []
        surface.sideChannel.revealed = false
        surface.sideChannel.frozen = false
        surface.sideChannel.inFlightEpoch = nil
        surface.pending = nil
        if let token = surface.sideChannel.watchdogToken {
            timerPurposes.removeValue(forKey: token)
            effects.append(.cancelTimer(token: token))
        }
        surface.sideChannel.watchdogToken = nil
        // A parked emulator may be reused, but its captured rows are not: SSP
        // can advance the live viewport while the reader is away and a frozen
        // reveal is stale by definition. Force the next reveal through one
        // authoritative fetch and a new owner bind, which clears before feed.
        surface.sideChannel.depth = 0
        surface.sideChannel.historyAnchor = nil
        surface.sideChannel.anchorHistorySize = 0
        surface.sideChannel.hasSynthesizedHistory = false
        surface.sideChannel.pendingPresentationOwner = nil
        surface.sideChannel.outputWhilePresentationPending = false
        surface.sideChannel.requestedIntent = nil
        bumpOwnerEpoch(&surface)
        surfaces[surfaceID] = surface
        if let owner = surface.owner {
            effects.append(.bindSurface(surfaceID, owner: owner))
        }
        effects.append(.requestTransportFullFrame)
        return effects
    }

    private mutating func invalidateSideChannelHistory(
        reason: String,
        forceBind: Bool = false
    ) -> [RenderEffect] {
        guard profile == .sideChannel else { return [] }
        var effects: [RenderEffect] = []
        for surfaceID in surfaceOrder {
            guard var surface = surfaces[surfaceID] else { continue }
            // A layout notification can arrive after a user scroll has
            // started its capture (notably while a side-channel selection is
            // still being mirrored to the visible Mosh client). The old rows
            // are invalid at the new geometry, but the user's request is not.
            // Preserve only that intent and restart it below under a fresh
            // owner/generation; other invalidation causes remain terminal.
            let target = resolvedTarget(for: surfaceID)
            let candidateIntent: SideChannelCaptureIntent?
            if let pending = surface.pending {
                candidateIntent = surface.sideChannel.inFlightEpoch == pending.owner.epoch
                    ? sideChannelCaptureIntent(from: pending)
                    : nil
            } else if forceBind {
                // A preceding geometry edge may already have retired the
                // current pending generation. The admitted request remains
                // durable until a terminal event clears it, so another resize
                // can still replace it instead of starving the gesture.
                candidateIntent = surface.sideChannel.requestedIntent
            } else {
                candidateIntent = nil
            }
            let restartIntent: SideChannelCaptureIntent?
            if forceBind,
               let candidateIntent,
               let target,
               candidateIntent.matches(windowID: target.windowID, paneID: target.paneID) {
                restartIntent = candidateIntent
            } else {
                restartIntent = nil
            }
            let shouldClear = surface.sideChannel.hasSynthesizedHistory
                || surface.sideChannel.pendingPresentationOwner != nil
            var shouldBind = shouldClear
            if let token = surface.sideChannel.watchdogToken {
                timerPurposes.removeValue(forKey: token)
                effects.append(.cancelTimer(token: token))
            }
            if forceBind,
               let target,
               let window = snapshot?.windows.first(where: { $0.id == target.windowID }),
               surface.declaration.presentation == .single
                    || window.panes.contains(where: { $0.id == target.paneID }) {
                surface.owner = allocateOwner(
                    windowID: target.windowID,
                    paneID: target.paneID
                )
                shouldBind = true
            } else if forceBind {
                // A platform declaration for a removed pane can remain mounted
                // until the next UI turn. Do not re-authorize that stale target.
                surface.owner = nil
                shouldBind = false
            } else {
                bumpOwnerEpoch(&surface)
            }
            surface.pending = nil
            surface.sideChannel.depth = 0
            surface.sideChannel.historyAnchor = nil
            surface.sideChannel.anchorHistorySize = 0
            surface.sideChannel.hasSynthesizedHistory = false
            surface.sideChannel.revealed = false
            surface.sideChannel.frozen = false
            surface.sideChannel.pendingPresentationOwner = nil
            surface.sideChannel.outputWhilePresentationPending = false
            surface.sideChannel.inFlightEpoch = nil
            surface.sideChannel.watchdogToken = nil
            surface.sideChannel.requestedIntent = nil
            surfaces[surfaceID] = surface
            if shouldBind, let owner = surface.owner {
                effects.append(.bindSurface(surfaceID, owner: owner))
            }
            if let restartIntent {
                effects.append(contentsOf: startSideChannelHistory(
                    surfaceID: surfaceID,
                    depth: restartIntent.depth,
                    placement: restartIntent.placement
                ))
            }
        }
        effects.append(.diagnostic("render-ledger side-channel-invalidated reason=\(reason)"))
        return effects
    }

    private mutating func cancelSideChannelCapture(
        in surface: inout SurfaceState
    ) -> [RenderEffect] {
        var effects: [RenderEffect] = []
        if let token = surface.sideChannel.watchdogToken {
            timerPurposes.removeValue(forKey: token)
            effects.append(.cancelTimer(token: token))
        }
        surface.pending = nil
        surface.sideChannel.inFlightEpoch = nil
        surface.sideChannel.watchdogToken = nil
        surface.sideChannel.requestedIntent = nil
        return effects
    }

    private func declaredSurfaceSetMatches(
        windowID: WindowId,
        currentSnapshot: TmuxSnapshot
    ) -> Bool {
        guard let current = currentSnapshot.windows.first(where: { $0.id == windowID }),
              !surfaceOrder.isEmpty
        else { return false }
        let currentIsGrid = !current.isZoomed
            && (current.layout?.paneCount ?? max(1, current.panes.count)) > 1
        let declarations = surfaceOrder.compactMap { surfaces[$0]?.declaration }
        if currentIsGrid {
            let expectedPaneIDs = Set(current.panes.map(\.id))
            let declaredPaneIDs = Set(declarations.compactMap(\.paneID))
            return declarations.count == expectedPaneIDs.count
                && declarations.allSatisfy { declaration in
                    declaration.presentation == .grid
                        && (declaration.windowID ?? currentSnapshot.activeWindowID) == windowID
                        && declaration.paneID != nil
                }
                && declaredPaneIDs == expectedPaneIDs
        }
        guard declarations.count == 1,
              declarations[0].presentation == .single,
              let target = resolvedRefreshTarget(for: declarations[0].surfaceID)
        else { return false }
        return target.windowID == windowID && target.paneID == current.activePaneID
    }

    private mutating func timerFired(_ token: UInt64) -> [RenderEffect] {
        guard let purpose = timerPurposes.removeValue(forKey: token) else { return [] }
        switch purpose {
        case .initialWatchdog(let attachment):
            guard attachment == attachmentGeneration, !isInitialRenderReady else { return [] }
            initialWatchdogToken = nil
            var effects = invalidateAllTimers()
            // Fail open means a subsequent authenticated `%output` may become
            // the renderer; it cannot remain blocked behind the abandoned
            // initial capture.  Drop every initial pending stage and forget
            // its internal owner so that first output emits an adjacent fresh
            // bind before feed.  The platform seam therefore clears an old
            // reconnect buffer even though the authoritative capture timed
            // out, while late command replies remain harmless stale replies.
            for surfaceID in surfaceOrder {
                if let pending = surfaces[surfaceID]?.pending,
                   let failure = correlatedRefreshFailure(
                       surfaceID: surfaceID,
                       pending: pending,
                       reason: "initial-watchdog"
                   ) {
                    effects.append(failure)
                }
                surfaces[surfaceID]?.pending = nil
                surfaces[surfaceID]?.retryAttemptsByStage.removeAll(keepingCapacity: true)
                surfaces[surfaceID]?.owner = nil
            }
            isInitialRenderReady = true
            effects.append(contentsOf: [
                .diagnostic("render-ledger initial-watchdog-fail-open"),
                .initialRenderReady,
            ])
            return effects
        case .queueWait(let surfaceID, let generation, let attempts):
            guard var surface = surfaces[surfaceID],
                  var pending = surface.pending,
                  pending.generation == generation
            else { return [] }
            let waited = (attempts + 1) * configuration.commandQueuePollMilliseconds
            if !commandQueue.isEmpty && waited < configuration.commandQueueWaitMilliseconds {
                pending.phase = .waitingForQueue(attempts: attempts + 1)
                surface.pending = pending
                surfaces[surfaceID] = surface
                let next = allocateTimer(.queueWait(
                    surfaceID: surfaceID,
                    generation: generation,
                    attempts: attempts + 1
                ))
                return [.armTimer(token: next, milliseconds: configuration.commandQueuePollMilliseconds)]
            }
            pending.phase = .metadata
            surface.pending = pending
            surfaces[surfaceID] = surface
            return sendMetadataQuery(surfaceID: surfaceID)
        case .retry(let surfaceID, let generation, let stage, let reason):
            guard let pending = surfaces[surfaceID]?.pending,
                  pending.generation == generation
            else { return [] }
            surfaces[surfaceID]?.pending = nil
            if pending.deepensAfterRebuild {
                // A peer relayout reached the refresh while its retry was
                // armed (P7): the retry is that rebuild, as a restart is.
                surfaces[surfaceID]?.repaintOwedSinceYield = true
                hasRepaintOwedSinceYield = true
            }
            return requestRefresh(
                surfaceID: surfaceID,
                stage: stage,
                reason: reason,
                continuityBreak: stage != .viewportOnly,
                completionCorrelation: pending.completionCorrelation
            )
        case .surfaceGrid(let surfaceID, let generation):
            guard let pending = surfaces[surfaceID]?.pending,
                  pending.generation == generation,
                  case .awaitingSurfaceState(request: 0) = pending.phase
            else { return [] }
            return requestSurfaceState(surfaceID: surfaceID, pending: pending)
        case .sideChannelWatchdog(let surfaceID, let epoch):
            guard var surface = surfaces[surfaceID],
                  surface.sideChannel.inFlightEpoch == epoch
            else { return [] }
            surface.pending = nil
            surface.sideChannel.inFlightEpoch = nil
            surface.sideChannel.watchdogToken = nil
            surface.sideChannel.requestedIntent = nil
            surfaces[surfaceID] = surface
            return [.diagnostic("render-ledger side-channel-watchdog surface=\(surfaceID)")]
        }
    }

    /// Settle an inline surface whose `.deep` capture ended without a feed,
    /// or whose shallower capture was carrying a reader's latched gesture.
    ///
    /// The ledger promises exactly one settle per `scrollbackRequested`, so a
    /// terminal outcome that produces no frame still has to answer. The stored
    /// credit is re-reported unchanged: nothing was captured, so nothing about
    /// the surface's depth changed, and `canDeepen` stays true for a retry.
    private mutating func settleInlineHistoryAfterTermination(
        surfaceID: SurfaceId,
        pending: PendingRefresh
    ) -> [RenderEffect] {
        guard profile == .inline,
              var surface = surfaces[surfaceID],
              let owner = surface.owner,
              pending.stage == .deep || surface.inlineHistory.deepenRequestedWhilePending
        else { return [] }
        surface.inlineHistory.deepenRequestedWhilePending = false
        let state = surface.inlineHistory
        surfaces[surfaceID] = surface
        return [.inlineHistorySettled(
            surfaceID,
            owner: owner,
            depth: state.creditedDepth,
            historySize: state.historySize,
            canDeepen: state.canDeepen
        )]
    }

    /// A transport boundary discards every pending refresh without a terminal
    /// outcome of its own. A deepen latched behind one still owes the reader
    /// exactly one settle, so it is answered with the state the boundary
    /// leaves behind: no credit, and deepening allowed again once the new
    /// transport has re-captured the surface. Both platforms also drop their
    /// own records at a boundary; this keeps the ledger's promise honest
    /// without relying on that.
    private func settleInlineHistoryAtTransportBoundary(
        surfaceID: SurfaceId,
        surface: SurfaceState,
        wasInline: Bool
    ) -> [RenderEffect] {
        guard wasInline,
              let owner = surface.owner,
              surface.pending?.historyDepth != nil || surface.inlineHistory.deepenRequestedWhilePending
        else { return [] }
        return [.inlineHistorySettled(surfaceID, owner: owner, depth: 0, historySize: 0, canDeepen: true)]
    }

    private mutating func abortRefresh(
        surfaceID: SurfaceId,
        generation: UInt64,
        reason: String
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              let pending = surface.pending,
              pending.generation == generation
        else { return [] }
        if profile == .sideChannel {
            return finishMoshFailure(surfaceID: surfaceID, reason: reason)
        }
        let ceiling = pending.stage == .deep
            ? configuration.maximumDeepRetryAttempts
            : configuration.maximumViewportRetryAttempts
        let attempts = surface.retryAttemptsByStage[pending.stage, default: 0]
        let ownerIdentityChanged = surface.owner.map {
            $0.windowID != pending.owner.windowID || $0.paneID != pending.owner.paneID
        } ?? false
        // Every retry stream is bounded. Foreground recovery and an
        // established cross-identity viewport remain fail-closed after the
        // final attempt, but they stop emitting commands until a later fact or
        // identity change explicitly supersedes them.
        guard attempts < ceiling else {
            surface.refreshFailedWithoutFrame = true
            let mustRemainFailClosed = pending.foregroundRecovery
                || (pending.stage != .deep && ownerIdentityChanged)
            if mustRemainFailClosed {
                // Stop issuing traffic after the bounded attempts, but retain
                // the pending ownership cut so live output cannot paint over
                // the stale surface. Keep the already-bounded foreground cut
                // for a later identity/lifecycle/manual refresh to supersede
                // this terminal failed state without losing intervening bytes.
                var retainedPending = pending
                retainedPending.completionCorrelation = nil
                retainedPending.aborted = true
                surface.pending = retainedPending
                surfaces[surfaceID] = surface
            } else {
                surface.pending = nil
                surfaces[surfaceID] = surface
            }
            var effects: [RenderEffect] = [.diagnostic("render-ledger refresh-gave-up surface=\(surfaceID) stage=\(pending.stage.rawValue) reason=\(reason)")]
            if let failure = correlatedRefreshFailure(
                surfaceID: surfaceID,
                pending: pending,
                reason: "retry-exhausted:\(reason)"
            ) {
                effects.append(failure)
            }
            effects.append(contentsOf: settleInlineHistoryAfterTermination(
                surfaceID: surfaceID,
                pending: pending
            ))
            if !mustRemainFailClosed {
                effects.append(contentsOf: finishForegroundIfPossible())
            }
            return effects
        }
        let nextAttempt = attempts == Int.max ? Int.max : attempts + 1
        surface.retryAttemptsByStage[pending.stage] = nextAttempt
        surface.pending?.aborted = true
        surfaces[surfaceID] = surface
        let token = allocateTimer(.retry(
            surfaceID: surfaceID,
            generation: generation,
            stage: pending.stage,
            reason: pending.reason
        ))
        return [
            .diagnostic("render-ledger refresh-retry surface=\(surfaceID) stage=\(pending.stage.rawValue) reason=\(reason) attempt=\(nextAttempt)"),
            .armTimer(token: token, milliseconds: configuration.renderRetryMilliseconds),
        ]
    }

    private mutating func restartRefresh(
        surfaceID: SurfaceId,
        pending: PendingRefresh,
        reason: String
    ) -> [RenderEffect] {
        guard surfaces[surfaceID]?.pending?.generation == pending.generation else { return [] }
        surfaces[surfaceID]?.pending = nil
        if pending.deepensAfterRebuild {
            // Still paying a relayout skipped while yielded (P7).
            surfaces[surfaceID]?.repaintOwedSinceYield = true
            hasRepaintOwedSinceYield = true
        }
        var effects: [RenderEffect] = [.diagnostic("render-ledger refresh-restart surface=\(surfaceID) reason=\(reason)")]
        // The restart re-requests the very same capture, so a deepen must
        // not be silently downgraded to the first-fill depth, and the
        // replacement refresh's own terminal outcome is what settles the
        // reader's gesture. Nothing is settled here.
        effects.append(contentsOf: requestRefresh(
            surfaceID: surfaceID,
            stage: pending.stage,
            reason: reason,
            continuityBreak: true,
            completionCorrelation: pending.completionCorrelation,
            historyDepth: pending.historyDepth
        ))
        return effects
    }

    // MARK: - Transport full-frame reservations

    /// Reserve one transport-painted full frame under a platform correlation.
    ///
    /// The side-channel analogue of a correlated refresh. The ledger cannot
    /// produce these bytes — on this profile mosh paints the visible screen
    /// outside the control connection — but it *can* own the reservation, and
    /// that is the point: the ledger is what rebinds surfaces and advances
    /// owner epochs, so it must also be what decides the fate of a frame
    /// reserved against an owner it is about to replace.
    private mutating func reserveTransportFullFrame(
        surfaceID: SurfaceId,
        reason: String,
        correlation: UInt64
    ) -> [RenderEffect] {
        guard correlation > 0 else {
            return [
                .diagnostic("render-ledger rejected-transport-frame-correlation surface=\(surfaceID)"),
                .transportFullFrameFailed(surfaceID, correlation: correlation, reason: "invalid-correlation"),
            ]
        }
        guard profile == .sideChannel else {
            return [.transportFullFrameFailed(
                surfaceID,
                correlation: correlation,
                reason: "profile-not-side-channel"
            )]
        }
        guard var surface = surfaces[surfaceID] else {
            return [.transportFullFrameFailed(
                surfaceID,
                correlation: correlation,
                reason: "unknown-surface"
            )]
        }
        var effects: [RenderEffect] = []
        // Exactly one terminal outcome per accepted reservation, including
        // when a newer reservation replaces an older one.
        if let previous = surface.transportFullFrame {
            effects.append(.transportFullFrameFailed(
                surfaceID,
                correlation: previous.correlation,
                reason: "superseded"
            ))
        }
        surface.transportFullFrame = TransportFullFrameReservation(
            correlation: correlation,
            reason: reason,
            owner: surface.owner
        )
        surfaces[surfaceID] = surface
        hasTransportFullFrameReservation = true
        effects.append(contentsOf: issueTransportFullFrameReservation(surfaceID: surfaceID))
        return effects
    }

    /// A correlated authority repaint would clear the transport viewport.
    /// Keep a revealed or staged history page intact until its tail/invalidation
    /// bind retires it; ordinary history hydration repaints remain independent.
    private mutating func issueTransportFullFrameReservation(
        surfaceID: SurfaceId
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              var reservation = surface.transportFullFrame,
              !reservation.issued,
              !surface.sideChannel.revealed,
              surface.sideChannel.pendingPresentationOwner == nil
        else { return [] }
        reservation.issued = true
        surface.transportFullFrame = reservation
        surfaces[surfaceID] = surface
        return [.requestCorrelatedTransportFullFrame(
            surfaceID,
            owner: reservation.owner,
            correlation: reservation.correlation,
            reason: reservation.reason
        )]
    }

    /// Discharge a reservation on the platform's exact-owner acknowledgement.
    /// A report naming a stale correlation or a different owner is a no-op:
    /// it describes a frame that no longer authorises anything.
    private mutating func resolveTransportFullFrame(
        surfaceID: SurfaceId,
        owner: RenderOwner?,
        correlation: UInt64,
        failure: String?
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              let reservation = surface.transportFullFrame,
              reservation.correlation == correlation,
              reservation.owner == owner,
              reservation.issued || failure != nil
        else { return [] }
        surface.transportFullFrame = nil
        surfaces[surfaceID] = surface
        recomputeTransportFullFrameReservationFlag()
        if let failure {
            return [.transportFullFrameFailed(
                surfaceID,
                correlation: correlation,
                reason: failure
            )]
        }
        return [.transportFullFrameCompleted(
            surfaceID,
            owner: owner,
            correlation: correlation
        )]
    }

    /// Decide what a rebind does to an outstanding reservation.
    ///
    /// A take-back forces tmux geometry; tmux echoes `%layout-change` for that
    /// force; this ledger rebinds the surface under a fresh epoch for the echo.
    /// The visible target has not moved — same window, same pane — so the
    /// reservation is re-issued against the replacement owner rather than
    /// failed. Retiring it here is what made every mosh take-back abort its own
    /// claim and leave the "continued elsewhere" veil up.
    ///
    /// A genuine window or pane switch still fails it: a frame forced for a
    /// departed pane can never authorise the surface now on screen.
    private mutating func reconcileTransportFullFrameReservation(
        surfaceID: SurfaceId,
        boundTo owner: RenderOwner
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID],
              var reservation = surface.transportFullFrame
        else { return [] }

        guard reservation.owner != owner else {
            return issueTransportFullFrameReservation(surfaceID: surfaceID)
        }

        let namesSameVisibleTarget = reservation.owner.map { previous in
            previous.windowID == owner.windowID && previous.paneID == owner.paneID
        } ?? true // a reservation taken before the first bind adopts that bind

        guard namesSameVisibleTarget else {
            surface.transportFullFrame = nil
            surfaces[surfaceID] = surface
            recomputeTransportFullFrameReservationFlag()
            return [.transportFullFrameFailed(
                surfaceID,
                correlation: reservation.correlation,
                reason: "owner-changed"
            )]
        }

        reservation.owner = owner
        reservation.issued = false
        surface.transportFullFrame = reservation
        surfaces[surfaceID] = surface
        return [
            .diagnostic(
                "render-ledger transport-frame-retargeted surface=\(surfaceID) "
                    + "correlation=\(reservation.correlation) owner=\(owner)"
            ),
        ] + issueTransportFullFrameReservation(surfaceID: surfaceID)
    }

    /// Every rebind flows through here, whichever of the eleven call sites
    /// emitted it. Hooking the sites individually is the same "one of them
    /// forgets" failure this reservation exists to prevent.
    private mutating func reconcilingTransportFullFrameReservations(
        _ effects: [RenderEffect]
    ) -> [RenderEffect] {
        guard hasTransportFullFrameReservation else { return effects }
        var result: [RenderEffect] = []
        result.reserveCapacity(effects.count)
        for effect in effects {
            result.append(effect)
            guard case .bindSurface(let surfaceID, let owner) = effect else { continue }
            result.append(contentsOf: reconcileTransportFullFrameReservation(
                surfaceID: surfaceID,
                boundTo: owner
            ))
        }
        return result
    }

    private mutating func recomputeTransportFullFrameReservationFlag() {
        hasTransportFullFrameReservation = surfaces.values.contains { $0.transportFullFrame != nil }
    }

    private func correlatedRefreshFailure(
        surfaceID: SurfaceId,
        pending: PendingRefresh,
        reason: String
    ) -> RenderEffect? {
        guard let correlation = pending.completionCorrelation else { return nil }
        return .refreshFailed(surfaceID, correlation: correlation, reason: reason)
    }

    private func rejectedCorrelatedRefresh(
        surfaceID: SurfaceId,
        correlation: UInt64?,
        reason: String
    ) -> [RenderEffect] {
        guard let correlation else { return [] }
        return [.refreshFailed(surfaceID, correlation: correlation, reason: reason)]
    }

    /// A deepen that ends without a page: the capture is dropped and the
    /// reader keeps the page it is reading. An anchored deepen whose rows
    /// were gone or ambiguous drops the anchor and freezes that page, so a
    /// later request cannot replace it without proving the reader's position.
    private mutating func endSideChannelDeepen(
        surfaceID: SurfaceId,
        reason: String,
        keepAnchor: Bool
    ) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID] else { return [] }
        var effects: [RenderEffect] = []
        if let token = surface.sideChannel.watchdogToken {
            timerPurposes.removeValue(forKey: token)
            effects.append(.cancelTimer(token: token))
        }
        surface.pending = nil
        surface.sideChannel.inFlightEpoch = nil
        surface.sideChannel.watchdogToken = nil
        surface.sideChannel.requestedIntent = nil
        if !keepAnchor {
            surface.sideChannel.historyAnchor = nil
            surface.sideChannel.frozen = surface.sideChannel.revealed
                && surface.sideChannel.hasSynthesizedHistory
        }
        surfaces[surfaceID] = surface
        effects.append(.diagnostic(
            "render-ledger side-channel-request-ignored surface=\(surfaceID) reason=\(reason)"
        ))
        return effects
    }

    private mutating func finishMoshFailure(surfaceID: SurfaceId, reason: String) -> [RenderEffect] {
        guard var surface = surfaces[surfaceID] else { return [] }
        var effects: [RenderEffect] = []
        if let token = surface.sideChannel.watchdogToken {
            timerPurposes.removeValue(forKey: token)
            effects.append(.cancelTimer(token: token))
        }
        surface.pending = nil
        surface.sideChannel.inFlightEpoch = nil
        surface.sideChannel.watchdogToken = nil
        surface.sideChannel.revealed = false
        surface.sideChannel.requestedIntent = nil
        surfaces[surfaceID] = surface
        effects.append(.diagnostic("render-ledger side-channel-skipped surface=\(surfaceID) reason=\(reason)"))
        // The terminal failure retires the reader, just like a failed
        // presentation. Its held authority frame can now repaint the tail.
        effects.append(contentsOf: issueTransportFullFrameReservation(surfaceID: surfaceID))
        return effects
    }

    private mutating func updateProgramStatusPaneOutput() -> [RenderEffect] {
        guard profile == .sideChannel else { return [] }
        programStatusPaneOutputSequence &+= 1
        programStatusPaneOutputState = .requested
        let token = allocateReplyToken()
        replyPurposes[token] = .programStatusPaneOutput(
            enabled: wantsProgramStatusPaneOutput, sequence: programStatusPaneOutputSequence
        )
        return [enqueueLedgerCommand(
            RenderCommands.sideChannelPaneOutput(enabled: wantsProgramStatusPaneOutput), purpose: token
        )]
    }

    private mutating func sendCaptureCommand(
        _ command: String,
        surfaceID: SurfaceId,
        generation: UInt64,
        phase: CapturePhase
    ) -> RenderEffect {
        let token = allocateReplyToken()
        replyPurposes[token] = .capture(surfaceID: surfaceID, generation: generation, phase: phase)
        return enqueueLedgerCommand(command, purpose: token)
    }

    private mutating func enqueueLedgerCommand(
        _ command: String,
        purpose: UInt64?
    ) -> RenderEffect {
        let token = purpose ?? allocateReplyToken()
        if purpose == nil {
            // Fire-and-forget ledger commands still occupy one FIFO entry; a
            // nil purpose intentionally drains without producing an effect.
            replyPurposes[token] = .discard
        }
        _ = commandQueue.enqueueLedger(command, token: token)
        return .sendCommand(command)
    }

    private mutating func cancelInitialWatchdog() -> [RenderEffect] {
        guard let token = initialWatchdogToken else { return [] }
        initialWatchdogToken = nil
        timerPurposes.removeValue(forKey: token)
        return [.cancelTimer(token: token)]
    }

    private mutating func invalidateAllTimers() -> [RenderEffect] {
        let tokens = timerPurposes.keys.sorted()
        timerPurposes.removeAll(keepingCapacity: true)
        return tokens.map { .cancelTimer(token: $0) }
    }

    private mutating func allocateGeneration() -> UInt64 {
        let generation = nextGeneration
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        return generation
    }

    private mutating func allocateOwner(windowID: WindowId?, paneID: PaneId?) -> RenderOwner {
        let epoch = nextEpoch
        nextEpoch &+= 1
        if nextEpoch == 0 { nextEpoch = 1 }
        return .init(windowID: windowID, paneID: paneID, epoch: epoch)
    }

    private mutating func allocateReplyToken() -> UInt64 {
        let token = nextReplyToken
        nextReplyToken &+= 1
        if nextReplyToken == 0 { nextReplyToken = 1 }
        return token
    }

    private mutating func allocateTimer(_ purpose: TimerPurpose) -> UInt64 {
        let token = nextTimerToken
        nextTimerToken &+= 1
        if nextTimerToken == 0 { nextTimerToken = 1 }
        timerPurposes[token] = purpose
        return token
    }

    private mutating func allocateSurfaceRequest() -> UInt64 {
        let request = nextSurfaceRequest
        nextSurfaceRequest &+= 1
        if nextSurfaceRequest == 0 { nextSurfaceRequest = 1 }
        return request
    }

    private var inlineHistoryDepth: Int {
        min(configuration.deepHistoryDepth, configuration.scrollbackLimit)
    }

    /// The deepest inline capture the ladder will ever ask for: the reader's
    /// own scrollback preference, never less than the first fill. A reader
    /// who set that preference to zero gets no ladder at all: the first fill
    /// is then already the full depth and nothing is ever deepened.
    private var fullInlineDepth: Int {
        max(inlineHistoryDepth, configuration.scrollbackLimit)
    }

    private mutating func retain(
        bytes: [UInt8],
        surfaceID: SurfaceId? = nil,
        generation: UInt64? = nil
    ) -> RenderBytesRef? {
        guard bytes.count <= configuration.maximumRenderBytes else { return nil }
        if let surfaceID, let generation {
            // An issued feed must remain readable until the platform consumes
            // it. Evict only when a newer authoritative payload is ready, not
            // merely when its follow-up stage is requested in the same effect
            // batch (viewport -> deep is the common case).
            evictSupersededRefreshBytes(surfaceID: surfaceID, before: generation)
        }
        let reference = RenderBytesRef(nextBytesReference)
        nextBytesReference &+= 1
        if nextBytesReference == 0 || nextBytesReference > UInt64(Int64.max) {
            nextBytesReference = 1
        }
        retainedBytes[reference] = bytes
        retainedByteOrder.append(reference)
        if let surfaceID, let generation {
            retainedRefreshGeneration[reference] = (surfaceID, generation)
        }
        return reference
    }

    private mutating func evictSupersededRefreshBytes(
        surfaceID: SurfaceId,
        before generation: UInt64
    ) {
        let stale = retainedRefreshGeneration.compactMap { reference, context in
            context.surfaceID == surfaceID && context.generation < generation
                ? reference
                : nil
        }
        guard !stale.isEmpty else { return }
        let staleSet = Set(stale)
        for reference in stale {
            retainedBytes.removeValue(forKey: reference)
            retainedRefreshGeneration.removeValue(forKey: reference)
        }
        retainedByteOrder.removeAll { staleSet.contains($0) }
    }

    private mutating func coalesce(paneID: PaneId, bytes: [UInt8]) {
        guard !overflowedOutputPanes.contains(paneID) else { return }
        if coalescedByteCount + bytes.count > configuration.maximumForegroundOutputBytes {
            coalescedByteCount -= coalescedOutput.removeValue(forKey: paneID)?.count ?? 0
            overflowedOutputPanes.insert(paneID)
            return
        }
        coalescedOutput[paneID, default: []].append(contentsOf: bytes)
        coalescedByteCount += bytes.count
    }

    private mutating func takeCoalescedOutput(for paneID: PaneId) -> [UInt8]? {
        guard overflowedOutputPanes.remove(paneID) == nil else {
            coalescedOutput[paneID] = nil
            return nil
        }
        let bytes = coalescedOutput.removeValue(forKey: paneID)
        coalescedByteCount -= bytes?.count ?? 0
        return bytes
    }

    private mutating func finishForegroundIfPossible() -> [RenderEffect] {
        guard isForegroundOutputCoalescing,
              !isAppInactive,
              !surfaces.values.contains(where: { $0.pending != nil }),
              surfaces.values.allSatisfy({ $0.owner != nil })
        else { return [] }
        // A grid surface can settle while another pane still holds the
        // session-wide foreground barrier. If the settled pane then overflows
        // its retained output, its earlier capture no longer covers the
        // dropped redraw. Re-capture every such surface before releasing the
        // barrier; the refresh consumes the overflow marker only when its new
        // authoritative viewport is ready.
        let overflowedSurfaces = surfaceOrder.filter { surfaceID in
            guard let paneID = surfaces[surfaceID]?.owner?.paneID else {
                return false
            }
            return overflowedOutputPanes.contains(paneID)
        }
        if !overflowedSurfaces.isEmpty {
            var effects: [RenderEffect] = []
            for surfaceID in overflowedSurfaces {
                effects.append(contentsOf: requestRefresh(
                    surfaceID: surfaceID,
                    stage: .viewportOnly,
                    reason: "app-foreground-overflow",
                    continuityBreak: false
                ))
            }
            return effects
        }
        var effects: [RenderEffect] = []
        var flushedPanes: Set<PaneId> = []
        for surfaceID in surfaceOrder {
            guard let owner = surfaces[surfaceID]?.owner,
                  let paneID = owner.paneID,
                  flushedPanes.insert(paneID).inserted,
                  let bytes = takeCoalescedOutput(for: paneID),
                  !bytes.isEmpty
            else { continue }
            guard let reference = retain(bytes: bytes) else {
                effects.append(.diagnostic(
                    "render-ledger foreground-replay-too-large pane=\(paneID) bytes=\(bytes.count)"
                ))
                continue
            }
            effects.append(.feed(
                surfaceID,
                owner: owner,
                bytes: reference,
                source: .foregroundReplay
            ))
        }
        endForegroundCoalescing()
        return effects
    }

    private mutating func endForegroundCoalescing() {
        isForegroundOutputCoalescing = false
        coalescedOutput.removeAll(keepingCapacity: true)
        overflowedOutputPanes.removeAll(keepingCapacity: true)
        coalescedByteCount = 0
    }

    private mutating func bumpSideChannelEpoch(surfaceID: SurfaceId, clearOwner: Bool) {
        guard var surface = surfaces[surfaceID] else { return }
        if clearOwner {
            surface.owner = nil
        } else {
            bumpOwnerEpoch(&surface)
        }
        surface.sideChannel = .init()
        surface.pending = nil
        surfaces[surfaceID] = surface
    }

    private mutating func bumpOwnerEpoch(_ surface: inout SurfaceState) {
        guard let owner = surface.owner else { return }
        surface.owner = allocateOwner(windowID: owner.windowID, paneID: owner.paneID)
    }

    private func resolvedRefreshTarget(for surfaceID: SurfaceId) -> (
        windowID: WindowId,
        paneID: PaneId?,
        target: String
    )? {
        guard let surface = surfaces[surfaceID], let snapshot else { return nil }
        let windowID = surface.declaration.windowID ?? snapshot.activeWindowID
        guard let windowID,
              let window = snapshot.windows.first(where: { $0.id == windowID })
        else { return nil }
        let paneID = surface.declaration.paneID ?? window.activePaneID
        if surface.declaration.presentation != .single, paneID == nil {
            return nil
        }
        let target = surface.declaration.presentation == .single
            ? windowID.description
            : paneID!.description
        return (windowID, paneID, target)
    }

    private func resolvedTarget(for surfaceID: SurfaceId) -> (
        windowID: WindowId,
        paneID: PaneId,
        target: String
    )? {
        guard let target = resolvedRefreshTarget(for: surfaceID),
              let paneID = target.paneID
        else { return nil }
        return (target.windowID, paneID, target.target)
    }

    private func surfaceID(for paneID: PaneId, snapshot: TmuxSnapshot) -> SurfaceId? {
        if profile == .sideChannel,
           let overlay = surfaceOrder.first(where: {
               surfaces[$0]?.declaration.presentation == .overlay
                   && surfaces[$0]?.declaration.paneID == paneID
           }) {
            // Mosh keeps painting the whole-window surface while a detached
            // pane history surface is revealed. Output freezes that revealed
            // overlay, not the live painter underneath it.
            return overlay
        }
        for surfaceID in surfaceOrder {
            guard let surface = surfaces[surfaceID] else { continue }
            if surface.declaration.paneID == paneID { return surfaceID }
        }
        if let activeWindowID = snapshot.activeWindowID,
           snapshot.windows.first(where: { $0.id == activeWindowID })?.activePaneID == paneID {
            return surfaceOrder.first { surfaces[$0]?.declaration.presentation == .single }
        }
        if isInitialRenderReady {
            return surfaceOrder.first {
                surfaces[$0]?.owner == nil
                    && surfaces[$0]?.declaration.presentation == .single
            }
        }
        return nil
    }

    private func messageReason(_ message: TmuxMessage) -> String {
        switch message {
        case .sessionWindowChanged: return "session-window-changed"
        case .windowPaneChanged: return "window-pane-changed"
        case .windowClose, .unlinkedWindowClose: return "window-closed"
        case .layoutChange: return "layout-change"
        case .windowAdd, .unlinkedWindowAdd: return "window-added"
        default: return "wire"
        }
    }
}
