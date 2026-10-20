import Foundation
import TmuxControlCore

private enum TmuxABIWindowOperation: String, Codable {
    case newWindowAtEnd
    case newWindowAfterCurrent
    case selectWindow
    case killWindow
    case renameWindow
    case moveWindowAfter
    case moveWindowBefore
    case swapWindows
    case renumber
    case splitPane
    case sessionGroupQuery
}

private struct TmuxABIWindowCommandRequest: Codable {
    let paneId: String?
    let horizontal: Bool?
    let before: Bool?
    let op: TmuxABIWindowOperation
    let windowId: String?
    let target: String?
    let name: String?
    let detached: Bool?
    let printFormat: String?
    let command: String?
    /// `selectWindow` only: the issuing client's own session. Present, it
    /// builds the session-qualified tab switch (W2); absent, the legacy bare
    /// `-t @W` that tmux may resolve in a grouped sibling.
    let sessionId: String?
}

private struct TmuxABIWindowReorderRequest: Codable {
    let order: [String]
    let moving: String
    let destination: Int
    let capabilities: TmuxWindowCapabilities
    let sessionID: String
    let activeWindowID: String?
    let highestIndex: Int?
}

private struct TmuxABIWindowReorderResponse: Codable {
    let commands: [String]
    let expectedOrder: [String]
}

private struct TmuxABIWindowCapabilitiesRequest: Codable {
    let version: String
}

private struct TmuxABISessionGroupMembersRequest: Codable {
    let lines: [String]
    let containingSessionID: String
}

private struct TmuxABISessionGroupMember: Codable {
    let sessionID: String
    let activeWindowID: String
}

private struct TmuxABISessionGroupRenumberRequest: Codable {
    let structured: Bool?
    let members: [TmuxABISessionGroupMember]
    let attachedSessionID: String
}

/// Decode one bounded, strict-UTF-8 canonical JSON document. Requiring the
/// caller's bytes to equal our sorted-key encoding makes unknown keys, `null`
/// optionals, and duplicate keys fail closed at this language boundary.
private func decodeCanonicalTmuxJSON<T: Codable>(
    _ type: T.Type,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int
) -> T? {
    guard let data = SharedABI.requiredData(bytes, count),
          String(data: data, encoding: .utf8) != nil,
          let value = try? JSONDecoder().decode(type, from: data),
          let canonical = try? SharedABI.encoder.encode(value),
          canonical == data
    else { return nil }
    return value
}

private func tmuxWindowID(_ value: String?) -> WindowId? {
    value.flatMap(WindowId.init(wireValue:))
}

private func tmuxSessionID(_ value: String?) -> SessionId? {
    value.flatMap(SessionId.init(wireValue:))
}

private func isSafeTmuxCommandArgument(_ value: String) -> Bool {
    !value.isEmpty && !value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
}

@_cdecl("tessera_tmux_window_command")
public func tesseraTmuxWindowCommand(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(
        TmuxABIWindowCommandRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }

    let command: String?
    switch request.op {
    case .newWindowAtEnd:
        guard request.windowId == nil,
              [request.target, request.name, request.printFormat, request.command]
                .compactMap({ $0 }).allSatisfy(isSafeTmuxCommandArgument)
        else { return -1 }
        if let target = request.target, !isSafeTmuxCommandArgument(target) { return -1 }
        command = TmuxWindowCommands.newWindowAtEnd(
            target: request.target,
            detached: request.detached ?? false,
            name: request.name,
            printFormat: request.printFormat,
            command: request.command
        )
    case .newWindowAfterCurrent:
        guard request.windowId == nil, request.target == nil, request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.newWindowAfterCurrent()
    case .selectWindow:
        guard let id = tmuxWindowID(request.windowId), request.target == nil, request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        if let rawSession = request.sessionId {
            guard let sessionID = tmuxSessionID(rawSession) else { return -1 }
            command = TmuxWindowCommands.selectWindow(id, inOwnSession: sessionID)
        } else {
            command = TmuxWindowCommands.selectWindow(id)
        }
    case .killWindow:
        guard let id = tmuxWindowID(request.windowId), request.target == nil, request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.killWindow(id)
    case .renameWindow:
        guard let id = tmuxWindowID(request.windowId), let name = request.name,
              isSafeTmuxCommandArgument(name), request.target == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.renameWindow(id, to: name)
    case .moveWindowAfter:
        guard let id = tmuxWindowID(request.windowId), let target = tmuxWindowID(request.target), request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.moveWindow(id, after: target)
    case .moveWindowBefore:
        guard let id = tmuxWindowID(request.windowId), let target = tmuxWindowID(request.target), request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.moveWindow(id, before: target)
    case .swapWindows:
        guard let id = tmuxWindowID(request.windowId), let target = tmuxWindowID(request.target), request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.swapWindows(id, target)
    case .renumber:
        guard request.windowId == nil, let target = request.target,
              isSafeTmuxCommandArgument(target), request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.renumber(target: target)
    case .splitPane:
        guard let raw = request.paneId, let id = PaneId(wireValue: raw), let horizontal = request.horizontal,
              request.windowId == nil, request.target == nil, request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxWindowCommands.splitPane(id, horizontal: horizontal, before: request.before ?? false)
    case .sessionGroupQuery:
        guard request.windowId == nil, request.target == nil, request.name == nil,
              request.detached == nil, request.printFormat == nil, request.command == nil else { return -1 }
        command = TmuxSessionGroupQuery.command
    }
    guard let command else { return -1 }
    if request.op != .splitPane && (request.paneId != nil || request.horizontal != nil || request.before != nil) { return -1 }
    if request.op != .selectWindow && request.sessionId != nil { return -1 }
    return SharedABI.copyOut(command, outputBytes, outputCapacity)
}

@_cdecl("tessera_tmux_window_reorder_plan")
public func tesseraTmuxWindowReorderPlan(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(
        TmuxABIWindowReorderRequest.self,
        requestBytes,
        requestCount
    ),
          let moving = WindowId(wireValue: request.moving),
          let sessionID = tmuxSessionID(request.sessionID)
    else { return -1 }
    let order = request.order.compactMap(WindowId.init(wireValue:))
    guard order.count == request.order.count else { return -1 }
    let activeWindowID: WindowId?
    if let rawActive = request.activeWindowID {
        guard let parsed = WindowId(wireValue: rawActive) else { return -1 }
        activeWindowID = parsed
    } else {
        activeWindowID = nil
    }
    guard let plan = TmuxWindowReorderPlanner.plan(
        order: order,
        moving: moving,
        to: request.destination,
        capabilities: request.capabilities,
        sessionID: sessionID,
        activeWindowID: activeWindowID,
        highestIndex: request.highestIndex
    ) else { return -1 }
    return SharedABI.copyOutJSON(
        TmuxABIWindowReorderResponse(
            commands: plan.commands,
            expectedOrder: plan.expectedOrder.map(\.description)
        ),
        outputBytes,
        outputCapacity
    )
}

@_cdecl("tessera_tmux_window_capabilities")
public func tesseraTmuxWindowCapabilities(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(
        TmuxABIWindowCapabilitiesRequest.self,
        requestBytes,
        requestCount
    ) else { return -1 }
    return SharedABI.copyOutJSON(
        TmuxWindowCapabilities.forVersion(request.version),
        outputBytes,
        outputCapacity
    )
}

@_cdecl("tessera_tmux_session_group_members")
public func tesseraTmuxSessionGroupMembers(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(
        TmuxABISessionGroupMembersRequest.self,
        requestBytes,
        requestCount
    ),
          request.lines.count <= 512,
          request.lines.allSatisfy({ $0.utf8.count <= 1_024 }),
          let containing = SessionId(wireValue: request.containingSessionID),
          let members = TmuxSessionGroupQuery.parse(lines: request.lines, containing: containing)
    else { return -1 }
    return SharedABI.copyOutJSON(
        members.map {
            TmuxABISessionGroupMember(
                sessionID: $0.sessionID.description,
                activeWindowID: $0.activeWindowID.description
            )
        },
        outputBytes,
        outputCapacity
    )
}

@_cdecl("tessera_tmux_session_group_renumber_commands")
public func tesseraTmuxSessionGroupRenumberCommands(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(
        TmuxABISessionGroupRenumberRequest.self,
        requestBytes,
        requestCount
    ),
          request.members.count <= 512,
          let attached = SessionId(wireValue: request.attachedSessionID)
    else { return -1 }
    let members = request.members.compactMap { member -> TmuxSessionGroupMember? in
        guard let sessionID = SessionId(wireValue: member.sessionID),
              let activeWindowID = WindowId(wireValue: member.activeWindowID)
        else { return nil }
        return .init(sessionID: sessionID, activeWindowID: activeWindowID)
    }
    guard members.count == request.members.count,
          let plan = TmuxSessionGroupQuery.renumberPlan(
            for: members,
            preservingAttached: attached
          )
    else { return -1 }
    if request.structured == true {
        return SharedABI.copyOutJSON(plan, outputBytes, outputCapacity)
    }
    return SharedABI.copyOutJSON(plan.commands, outputBytes, outputCapacity)
}

/// 1 when an Agent Center tmux command only reads; 0 otherwise; -1 for a
/// missing command. Reads may run while another device holds the grid.
@_cdecl("tessera_tmux_agent_command_is_read_only")
public func tesseraTmuxAgentCommandIsReadOnly(commandBytes: UnsafePointer<UInt8>?, commandCount: Int) -> Int32 {
    guard let command = optionalString(commandBytes, commandCount) else { return -1 }
    return TmuxAgentCommandAccess.isReadOnly(command) ? 1 : 0
}

/// 1 when an Agent Center tmux command only reads or sends to a proved pane,
/// without moving grid authority; 0 when it must wait on the authority gate;
/// -1 for a missing command.
@_cdecl("tessera_tmux_agent_command_is_authority_neutral")
public func tesseraTmuxAgentCommandIsAuthorityNeutral(commandBytes: UnsafePointer<UInt8>?, commandCount: Int) -> Int32 {
    guard let command = optionalString(commandBytes, commandCount) else { return -1 }
    return TmuxAgentCommandAccess.isAuthorityNeutral(command) ? 1 : 0
}

/// Decode a UTF-8 argument that the caller may legitimately omit.
private func optionalString(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> String? {
    guard let bytes, count > 0 else { return nil }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
}

/// Copy a built command out under the shared string contract: passing a nil or
/// zero-capacity buffer queries the required byte count, so a caller with no
/// fixed ceiling can size exactly. Returns -1 for invalid arguments.
private func copyOut(
    _ value: String,
    _ outputBytes: UnsafeMutablePointer<UInt8>?,
    _ outputCapacity: Int
) -> Int32 {
    let result = Array(value.utf8)
    guard let outputBytes, outputCapacity > 0 else { return Int32(result.count) }
    guard result.count <= outputCapacity else { return -1 }
    result.withUnsafeBytes { raw in
        guard let baseAddress = raw.baseAddress else { return }
        outputBytes.update(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: result.count)
    }
    return Int32(result.count)
}

@_cdecl("tessera_tmux_authority_visible_client_option")
public func tesseraTmuxAuthorityVisibleClientOption(
    deviceIDBytes: UnsafePointer<UInt8>?,
    deviceIDCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let deviceID = optionalString(deviceIDBytes, deviceIDCount) else { return -1 }
    return copyOut(
        TmuxGridAuthority.visibleClientOption(identityID: deviceID),
        outputBytes,
        outputCapacity
    )
}

@_cdecl("tessera_tmux_authority_stamp_value")
public func tesseraTmuxAuthorityStampValue(
    deviceIDBytes: UnsafePointer<UInt8>?,
    deviceIDCount: Int,
    displayNameBytes: UnsafePointer<UInt8>?,
    displayNameCount: Int,
    generation: UInt64,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let deviceID = optionalString(deviceIDBytes, deviceIDCount),
          let displayName = optionalString(displayNameBytes, displayNameCount)
    else { return -1 }
    return copyOut(
        TmuxGridAuthorityStamp(
            identity: .init(id: deviceID, displayName: displayName),
            generation: generation
        ).wireValue,
        outputBytes,
        outputCapacity
    )
}

/// The visible tmux client a mosh session runs. A zero-length device id means
/// this client publishes no grid-authority ownership option.
@_cdecl("tessera_tmux_mosh_visible_client_command")
public func tesseraTmuxMoshVisibleClientCommand(
    sessionTargetBytes: UnsafePointer<UInt8>?,
    sessionTargetCount: Int,
    gridAuthorityDeviceIDBytes: UnsafePointer<UInt8>?,
    gridAuthorityDeviceIDCount: Int,
    ignoresSize: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let sessionTarget = optionalString(sessionTargetBytes, sessionTargetCount)
    else { return -1 }
    return copyOut(
        AutoTmuxCommands.moshVisibleClientCommand(
            sessionTarget: sessionTarget,
            gridAuthorityDeviceID: optionalString(
                gridAuthorityDeviceIDBytes,
                gridAuthorityDeviceIDCount
            ),
            ignoresSize: ignoresSize != 0
        ),
        outputBytes,
        outputCapacity
    )
}

/// Tessera's private view of a user tmux session: a second session in the same
/// group, sharing its windows but carrying Tessera's own options.
@_cdecl("tessera_tmux_mosh_view_session_name")
public func tesseraTmuxMoshViewSessionName(
    sessionTargetBytes: UnsafePointer<UInt8>?,
    sessionTargetCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let sessionTarget = optionalString(sessionTargetBytes, sessionTargetCount)
    else { return -1 }
    return copyOut(
        AutoTmuxCommands.moshViewSessionName(for: sessionTarget),
        outputBytes,
        outputCapacity
    )
}

/// The `-CC` control channel a mosh session opens beside its visible client.
/// It joins Tessera's private view of the session, the same one the visible
/// client attaches to, so window selection moves both.
@_cdecl("tessera_tmux_mosh_control_channel_command")
public func tesseraTmuxMoshControlChannelCommand(
    sessionTargetBytes: UnsafePointer<UInt8>?,
    sessionTargetCount: Int,
    preserveInitialGeometry: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let sessionTarget = optionalString(sessionTargetBytes, sessionTargetCount)
    else { return -1 }
    return copyOut(
        AutoTmuxCommands.moshControlChannelCommand(
            sessionTarget: sessionTarget,
            preserveInitialGeometry: preserveInitialGeometry != 0
        ),
        outputBytes,
        outputCapacity
    )
}

/// The `-CC` control-mode client for a dedicated remote channel.
@_cdecl("tessera_tmux_control_mode_session_command")
public func tesseraTmuxControlModeSessionCommand(
    sessionTargetBytes: UnsafePointer<UInt8>?,
    sessionTargetCount: Int,
    preserveInitialGeometry: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let sessionTarget = optionalString(sessionTargetBytes, sessionTargetCount)
    else { return -1 }
    return copyOut(
        AutoTmuxCommands.controlModeSessionCommand(
            sessionTarget: sessionTarget,
            preserveInitialGeometry: preserveInitialGeometry != 0
        ),
        outputBytes,
        outputCapacity
    )
}

/// Frame one tmux window so its focused pane fills a compact viewport.
///
/// Writes `contentWidth, contentHeight, scale, offsetX, offsetY` into
/// `outputValues`. Returns 1 when a projection was written, 0 when the inputs
/// are degenerate and the caller should render at natural size with no
/// transform, and -1 when the output pointer is missing.
@_cdecl("tessera_tmux_compact_canvas_projection")
public func tesseraTmuxCompactCanvasProjection(
    windowColumns: Int32,
    windowRows: Int32,
    windowX: Int32,
    windowY: Int32,
    focusColumns: Int32,
    focusRows: Int32,
    focusX: Int32,
    focusY: Int32,
    cellWidth: Double,
    cellHeight: Double,
    viewportWidth: Double,
    viewportHeight: Double,
    outputValues: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let outputValues else { return -1 }
    guard let projection = TmuxCompactCanvas.projection(
        window: CellRect(
            width: Int(windowColumns),
            height: Int(windowRows),
            x: Int(windowX),
            y: Int(windowY)
        ),
        focus: CellRect(
            width: Int(focusColumns),
            height: Int(focusRows),
            x: Int(focusX),
            y: Int(focusY)
        ),
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight
    ) else { return 0 }
    outputValues[0] = projection.contentWidth
    outputValues[1] = projection.contentHeight
    outputValues[2] = projection.scale
    outputValues[3] = projection.offsetX
    outputValues[4] = projection.offsetY
    return 1
}

/// Decide whether a window resize this device did not initiate proves a
/// stamp-less peer took the grid. A negative `secondsSinceLocalSizeReplay`
/// means this device has never replayed a size on this connection.
@_cdecl("tessera_tmux_stampless_peer_should_raise")
public func tesseraTmuxStamplessPeerShouldRaise(
    participatesInAuthority: Int32,
    windowSizePolicyKnown: Int32,
    windowSizePolicyIsLatest: Int32,
    rederiveInFlight: Int32,
    alreadyPeer: Int32,
    reclaimInFlight: Int32,
    layoutIsForRenderedWindow: Int32,
    layoutColumns: Int32,
    layoutRows: Int32,
    localColumns: Int32,
    localRows: Int32,
    secondsSinceLocalSizeReplay: Double
) -> Int32 {
    let raise = TmuxStamplessPeer.shouldRaisePeer(
        participatesInAuthority: participatesInAuthority != 0,
        windowSizePolicyKnown: windowSizePolicyKnown != 0,
        windowSizePolicyIsLatest: windowSizePolicyIsLatest != 0,
        rederiveInFlight: rederiveInFlight != 0,
        alreadyPeer: alreadyPeer != 0,
        reclaimInFlight: reclaimInFlight != 0,
        layoutIsForRenderedWindow: layoutIsForRenderedWindow != 0,
        layoutColumns: Int(layoutColumns),
        layoutRows: Int(layoutRows),
        localColumns: Int(localColumns),
        localRows: Int(localRows),
        secondsSinceLocalSizeReplay: secondsSinceLocalSizeReplay < 0
            ? nil
            : secondsSinceLocalSizeReplay
    )
    return raise ? 1 : 0
}

/// Name whoever currently holds the shared grid. `knownDeviceNames` is a
/// tab-separated list of the device classes the calling platform stamps; a
/// peer name outside it resolves to the shared stamp-less wording rather than
/// printing another platform's stamp verbatim.
@_cdecl("tessera_tmux_peer_label")
public func tesseraTmuxPeerLabel(
    peerDisplayNameBytes: UnsafePointer<UInt8>?,
    peerDisplayNameCount: Int,
    selfDisplayNameBytes: UnsafePointer<UInt8>?,
    selfDisplayNameCount: Int,
    knownDeviceNamesBytes: UnsafePointer<UInt8>?,
    knownDeviceNamesCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let selfDisplayName = optionalString(selfDisplayNameBytes, selfDisplayNameCount)
    else { return -1 }
    let known = optionalString(knownDeviceNamesBytes, knownDeviceNamesCount)
        .map { Set($0.split(separator: "\t").map(String.init)) } ?? []
    return copyOut(
        TmuxPeerLabel.display(
            peerDisplayName: optionalString(peerDisplayNameBytes, peerDisplayNameCount),
            selfDisplayName: selfDisplayName,
            knownDeviceNames: known
        ),
        outputBytes,
        outputCapacity
    )
}

/// Classify a tmux launch that ended without ever engaging control mode.
///
/// Returns the `TmuxLaunchFailure` raw value, or 0 when nothing indicates the
/// launch itself failed. The caller must have established non-engagement — see
/// `TmuxLaunchFailure.classify`. `hasExitStatus` distinguishes "the remote
/// reported 0" from "no status was reported at all", which a single integer
/// cannot.
@_cdecl("tessera_tmux_classify_launch_failure")
public func tesseraTmuxClassifyLaunchFailure(
    exitStatus: Int32,
    hasExitStatus: Int32,
    outputBytes: UnsafePointer<UInt8>?,
    outputCount: Int
) -> Int32 {
    let failure = TmuxLaunchFailure.classify(
        exitStatus: hasExitStatus == 0 ? nil : exitStatus,
        output: optionalString(outputBytes, outputCount) ?? ""
    )
    return failure?.rawValue ?? 0
}

/// The fixed hydration commands, newline-separated in the order they must be
/// sent. The runtime parses the tagged query replies itself; the trailing
/// pause-after policy is shared here too so Android cannot drift from the
/// command used by the Apple adapter.
@_cdecl("tessera_tmux_hydration_commands")
public func tesseraTmuxHydrationCommands(
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    copyOut(
        (TmuxRuntimeHydrationQuery.commands + [RenderCommands.pauseAfter()])
            .joined(separator: "\n"),
        outputBytes,
        outputCapacity
    )
}

/// The fixed, tagged active-pane query for a known tmux window. Selection
/// adapters use its correlated reply as the causal proof before moving a
/// separately attached visible client.
@_cdecl("tessera_tmux_active_pane_command")
public func tesseraTmuxActivePaneCommand(
    windowID: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard windowID >= 0 else { return -1 }
    return copyOut(
        TmuxRuntimeHydrationQuery.activePaneCommand(
            windowID: WindowId(Int(windowID))
        ),
        outputBytes,
        outputCapacity
    )
}

/// The session-qualified window target (`TmuxWindowCommands.sessionQualifiedTarget`):
/// `'$S:@W'`, or `'$S:@W.%P'` when `paneID` is non-negative. A negative
/// `paneID` means no pane; a negative session or window id is rejected.
@_cdecl("tessera_tmux_session_window_target")
public func tesseraTmuxSessionWindowTarget(
    sessionID: Int32,
    windowID: Int32,
    paneID: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard sessionID >= 0, windowID >= 0 else { return -1 }
    return copyOut(
        TmuxWindowCommands.sessionQualifiedTarget(
            WindowId(Int(windowID)),
            sessionID: SessionId(Int(sessionID)),
            paneID: paneID >= 0 ? PaneId(Int(paneID)) : nil
        ),
        outputBytes,
        outputCapacity
    )
}

/// See `tessera_tmux_client_size_replay_commands` in the header.
@_cdecl("tessera_tmux_client_size_replay_commands")
public func tesseraTmuxClientSizeReplayCommands(
    columns: Int32,
    rows: Int32,
    sideChannel: Int32,
    belongsToClaim: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    let commands = TmuxClientSizeReplay.commands(
        columns: Int(columns),
        rows: Int(rows),
        path: sideChannel != 0 ? .sideChannel : .inline,
        belongsToClaim: belongsToClaim != 0
    )
    guard !commands.isEmpty else { return -1 }
    return copyOut(commands.joined(separator: "\n"), outputBytes, outputCapacity)
}

/// The inline replay's `latest` fence alone (`TmuxClientSizeReplay
/// .latestFenceCommand`), for the writes an adapter makes itself: a
/// take-back's own fence and the fence it reissues for a grid it already
/// advertised. Shared so neither platform keeps its own copy of the literal.
@_cdecl("tessera_tmux_client_size_latest_fence_command")
public func tesseraTmuxClientSizeLatestFenceCommand(
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    copyOut(TmuxClientSizeReplay.latestFenceCommand, outputBytes, outputCapacity)
}

private struct TmuxABIAuthorityCommandRequest: Codable {
    let op: String
    let ownerSessionID: String?
    let stamp: String?
    let name: String?
}

/// Canonical JSON request; response is a JSON array of separate commands.
@_cdecl("tessera_tmux_authority_commands")
public func tesseraTmuxAuthorityCommands(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(TmuxABIAuthorityCommandRequest.self, requestBytes, requestCount)
    else { return -1 }
    let scope: TmuxGridAuthorityScope
    if let raw = request.ownerSessionID {
        guard let id = SessionId(wireValue: raw) else { return -1 }
        scope = .owner(id)
    } else { scope = .ownSession }
    let commands: [String]
    switch request.op {
    case "query":
        guard request.stamp == nil, request.name == nil else { return -1 }
        commands = [TmuxGridAuthority.queryCommand(scope)]
    case "write":
        guard request.name == nil, let raw = request.stamp,
              let stamp = TmuxGridAuthorityStamp.parse(raw), stamp.wireValue == raw else { return -1 }
        commands = TmuxGridAuthority.writeCommands(stamp, scope: scope)
    case "ownerResolution":
        guard request.ownerSessionID == nil, request.stamp == nil,
              let name = request.name, isSafeTmuxCommandArgument(name) else { return -1 }
        commands = TmuxGridAuthority.ownerResolutionCommands(ownerSessionName: name)
    default: return -1
    }
    return SharedABI.copyOutJSON(commands, outputBytes, outputCapacity)
}

private struct TmuxABIAuthorityOwnerReplies: Codable {
    let ownerReply: [String]?
    let ownReply: [String]?
}

private struct TmuxABIAuthorityQueryReply: Codable {
    let ownerSessionID: String?
    let reply: [String]
}

/// Canonical JSON request; response is the reply's stamp lines (a JSON
/// array), or JSON `null` when an owner read found no owner.
@_cdecl("tessera_tmux_authority_query_reply")
public func tesseraTmuxAuthorityQueryReply(
    requestBytes: UnsafePointer<UInt8>?, requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?, outputCapacity: Int
) -> Int32 {
    guard let request = decodeCanonicalTmuxJSON(TmuxABIAuthorityQueryReply.self, requestBytes, requestCount)
    else { return -1 }
    let scope: TmuxGridAuthorityScope
    if let raw = request.ownerSessionID {
        guard let id = SessionId(wireValue: raw) else { return -1 }
        scope = .owner(id)
    } else { scope = .ownSession }
    return SharedABI.copyOutJSON(TmuxGridAuthority.queryReplyLines(request.reply, scope: scope), outputBytes, outputCapacity)
}

/// Returns the stable owner id, or -1 for every legacy fallback (including errors).
@_cdecl("tessera_tmux_authority_resolve_owner")
public func tesseraTmuxAuthorityResolveOwner(requestBytes: UnsafePointer<UInt8>?, requestCount: Int) -> Int64 {
    guard let request = decodeCanonicalTmuxJSON(TmuxABIAuthorityOwnerReplies.self, requestBytes, requestCount),
          let owner = TmuxGridAuthority.resolveOwner(ownerReply: request.ownerReply, ownReply: request.ownReply)
    else { return -1 }
    return Int64(owner.rawValue)
}
