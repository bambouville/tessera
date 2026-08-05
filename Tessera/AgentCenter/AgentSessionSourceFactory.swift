import Foundation
import SwiftTerm
import TmuxControl

@MainActor
enum AgentSessionSourceFactory {
    /// nil means the remote probe failed and must not be interpreted as an
    /// authoritative “no matching process” result.
    typealias ProcessProvider = @MainActor () async -> SwipePadPlainSSHProcessProbe.Snapshot?
    typealias PaneProcessProvider = @MainActor (Int) async -> SwipePadPlainSSHProcessProbe.Snapshot?
    typealias BracketedPasteProvider = @MainActor (AgentLocation) -> Bool?
    typealias ShellIntegrationProvider = @MainActor (
        _ processIDs: Set<Int>,
        _ allowInheritedEnvironment: Bool
    ) async -> Bool?

    static func make(
        sessionID: UUID,
        hostName: String,
        baseTransportLabel: String,
        tmux: TmuxController,
        terminalBox: TerminalBox,
        tmuxSessionName: @escaping @MainActor () -> String?,
        profiles: @escaping @MainActor () -> [SwipePadProfile],
        rawProcessProvider: @escaping ProcessProvider,
        paneProcessProvider: PaneProcessProvider? = nil,
        bracketedPasteProvider: @escaping BracketedPasteProvider = { _ in nil },
        lifecycleIntegrationCacheKey: String? = nil,
        automaticallyProbeLifecycleIntegration: Bool = true,
        probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)? = nil,
        installLifecycleIntegration: (@MainActor () async throws -> Void)? = nil,
        automaticallyInspectCurrentIntegration: @escaping @MainActor () -> Bool = { true },
        probeShellIntegration: ShellIntegrationProvider? = nil,
        rawSend: @escaping @MainActor ([UInt8]) -> Void
    ) -> AgentSessionSource {
        let diagnosticSessionID = String(sessionID.uuidString.prefix(8))
        DiagnosticLogStore.appendAgentCenter(
            "source-created sid=\(diagnosticSessionID) transport=\(baseTransportLabel) protocol=\(AgentLifecycleEvent.supportedVersion) autoHostProbe=\(automaticallyProbeLifecycleIntegration)"
        )
        // A shell/shim-enabled pane keeps the same root PID while a tab switch or
        // surface refresh can request discovery several times in quick
        // succession. Reuse that expensive remote descendant `ps` result for
        // a short window; safety inspections before sends still use the fresh
        // provider below.
        var descendantProcessCache: [Int: (date: Date, snapshot: SwipePadPlainSSHProcessProbe.Snapshot)] = [:]
        let discoveryPaneProcessProvider: PaneProcessProvider? = paneProcessProvider.map { provider in
            { panePID in
                if let cached = descendantProcessCache[panePID],
                   Date.now.timeIntervalSince(cached.date) < 2 {
                    return cached.snapshot
                }
                guard let snapshot = await provider(panePID) else { return nil }
                descendantProcessCache[panePID] = (.now, snapshot)
                return snapshot
            }
        }

        let discover: @MainActor () async -> AgentDiscoveryResult = {
            if tmux.mode == .tmuxControl {
                return await discoverTmux(
                    sessionID: sessionID,
                    hostName: hostName,
                    transportLabel: "\(baseTransportLabel)+tmux",
                    tmuxSessionName: tmuxSessionName(),
                    tmux: tmux,
                    profiles: profiles(),
                    paneProcessProvider: discoveryPaneProcessProvider,
                    bracketedPasteProvider: bracketedPasteProvider,
                    terminalBox: terminalBox
                )
            }
            guard let processes = await rawProcessProvider() else { return .unavailable }
            guard matchesAgent(processes.processNames, profiles: profiles()) else { return .success([]) }
            let location = AgentLocation(
                sessionID: sessionID,
                hostName: hostName,
                transportLabel: baseTransportLabel,
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            )
            let snapshot = visibleTerminalSnapshot(terminalBox)
            return .success([AgentProbeTarget(
                location: location,
                processNames: processes.processNames,
                processIDs: processes.processIDs,
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false
            )])
        }

        let inspect: @MainActor (AgentLocation) async -> AgentProbeTarget? = { location in
            if let paneID = location.paneID, tmux.mode == .tmuxControl {
                return await inspectTmux(
                    location: location,
                    paneID: PaneId(paneID),
                    tmux: tmux,
                    paneProcessProvider: paneProcessProvider,
                    bracketedPasteProvider: bracketedPasteProvider,
                    terminalBox: terminalBox
                )
            }
            guard let processes = await rawProcessProvider() else { return nil }
            guard matchesAgent(processes.processNames, profiles: profiles()) else { return nil }
            let snapshot = visibleTerminalSnapshot(terminalBox)
            return AgentProbeTarget(
                location: location,
                processNames: processes.processNames,
                processIDs: processes.processIDs,
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false
            )
        }

        let observe: @MainActor (AgentLocation) async -> AgentProbeTarget? = { location in
            if let paneID = location.paneID, tmux.mode == .tmuxControl {
                let typedPaneID = PaneId(paneID)
                let isRendered = tmux.renderedPaneId == typedPaneID
                    || (tmux.controlPath == .sideChannel && tmux.activePaneId == typedPaneID)
                // The currently rendered pane already has a coherent local
                // terminal snapshot. Avoid two remote control round trips on
                // the output hot path; inactive panes still use tmux capture.
                let capture: PaneCapture?
                if isRendered, let local = visiblePaneCapture(terminalBox) {
                    capture = local
                } else {
                    capture = await capturePane(tmux, paneID: typedPaneID)
                }
                return AgentProbeTarget(
                    location: location,
                    processNames: [],
                    visibleText: capture?.text,
                    currentInputLine: capture?.currentInputLine,
                    bracketedPasteEnabled: isRendered
                        ? terminalBox.view?.getTerminal().bracketedPasteMode ?? false
                        : bracketedPasteProvider(location) ?? false
                )
            }
            let snapshot = visibleTerminalSnapshot(terminalBox)
            return AgentProbeTarget(
                location: location,
                processNames: [],
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false
            )
        }

        let verifySend: @MainActor (AgentLocation) async -> AgentProbeTarget? = { location in
            if let paneID = location.paneID, tmux.mode == .tmuxControl {
                let typedPaneID = PaneId(paneID)
                guard let capture = await capturePane(tmux, paneID: typedPaneID) else {
                    return nil
                }
                return AgentProbeTarget(
                    location: location,
                    processNames: [],
                    visibleText: capture.text,
                    currentInputLine: capture.currentInputLine,
                    bracketedPasteEnabled: bracketedPasteProvider(location) ?? false
                )
            }
            let snapshot = visibleTerminalSnapshot(terminalBox)
            return AgentProbeTarget(
                location: location,
                processNames: [],
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false
            )
        }

        let inspectCurrentIntegration: @MainActor () async -> AgentCurrentIntegrationTarget? = {
            if tmux.mode == .tmuxControl {
                guard await waitForTmuxQueryReadiness(
                    tmux,
                    requiresActivePane: true,
                    context: "current-target",
                    diagnosticSessionID: diagnosticSessionID
                ) else {
                    DiagnosticLogStore.appendAgentCenter(
                        "current-target-read sid=\(diagnosticSessionID) result=deferred stage=tmux-readiness"
                    )
                    return nil
                }
                guard let paneID = tmux.activePaneId else {
                    DiagnosticLogStore.appendAgentCenter(
                        "current-target-read sid=\(diagnosticSessionID) result=deferred stage=active-pane"
                    )
                    return nil
                }
                guard let record = await inspectCurrentPane(tmux, paneID: paneID) else {
                    DiagnosticLogStore.appendAgentCenter(
                        "current-target-read sid=\(diagnosticSessionID) pane=\(paneID.rawValue) result=deferred stage=pane-record"
                    )
                    return nil
                }
                guard !Task.isCancelled else { return nil }

                var names = record.command.isEmpty ? [] : [record.command]
                var processIDs = Set<Int>()
                if (record.lifecycleEvent?.agentPID != nil
                    || shouldProbeDescendants(command: record.command)
                    || matchesSupportedShell([record.command])),
                   let paneProcessProvider,
                   let panePID = record.panePID {
                    guard let descendants = await paneProcessProvider(panePID) else {
                        DiagnosticLogStore.appendAgentCenter(
                            "current-target-read sid=\(diagnosticSessionID) pane=\(paneID.rawValue) result=deferred stage=descendant-process-snapshot commandClass=\(commandClass(record.command))"
                        )
                        return nil
                    }
                    guard !Task.isCancelled else { return nil }
                    names.append(contentsOf: descendants.processNames)
                    processIDs.formUnion(descendants.processIDs)
                }
                let foreground = currentIntegrationForeground(
                    currentCommand: record.command,
                    processNames: names
                )
                let isAgent = foreground == .agent
                let location = AgentLocation(
                    sessionID: sessionID,
                    hostName: hostName,
                    transportLabel: "\(baseTransportLabel)+tmux",
                    tmuxSessionName: tmuxSessionName(),
                    windowID: record.windowID.rawValue,
                    windowName: record.windowName,
                    paneID: record.paneID.rawValue
                )
                let lifecycleActive = lifecycleRuntimeActive(
                    isAgent: isAgent,
                    lifecycleEvent: record.lifecycleEvent,
                    processIDs: processIDs
                )
                // The pane marker is written by the exact shell that sourced
                // Tessera. It remains the cheapest reliable proof while vim,
                // htop, or another child owns the foreground. Fall back to the
                // pane root when no marker exists; the status command can then
                // inspect an inherited current-version environment on platforms that expose
                // it without returning the environment contents.
                let foregroundIsShell = foreground == .shell || foreground == .unsupportedShell
                var integrationProcessIDs = foregroundIsShell ? processIDs : Set<Int>()
                if !foregroundIsShell {
                    if let shellPID = shellMarkerPID(record.shellMarker) {
                        integrationProcessIDs.insert(shellPID)
                    }
                    if let panePID = record.panePID {
                        integrationProcessIDs.insert(panePID)
                    }
                    integrationProcessIDs.formUnion(processIDs)
                }
                let shellActive: Bool?
                if !isAgent, !integrationProcessIDs.isEmpty {
                    guard !Task.isCancelled else { return nil }
                    shellActive = await probeShellIntegration?(
                        integrationProcessIDs,
                        !foregroundIsShell
                    )
                    guard !Task.isCancelled else { return nil }
                } else {
                    shellActive = false
                }
                let retainedPayload: String
                if record.rawLifecyclePayload.isEmpty {
                    retainedPayload = "empty"
                } else if record.lifecycleEvent != nil {
                    retainedPayload = "compatible"
                } else {
                    retainedPayload = "rejected"
                }
                let retainedVersion = record.lifecycleEvent?.version
                    ?? AgentLifecycleEvent.declaredVersion(json: record.rawLifecyclePayload)
                let retainedSemantics: String
                if let event = record.lifecycleEvent {
                    retainedSemantics = event.isStatusNeutral ? "status-neutral" : "authoritative"
                } else {
                    retainedSemantics = record.rawLifecyclePayload.isEmpty ? "none" : "rejected"
                }
                DiagnosticLogStore.appendAgentCenter(
                    "current-target-read sid=\(diagnosticSessionID) pane=\(paneID.rawValue) result=success commandClass=\(commandClass(record.command)) foreground=\(String(describing: foreground)) processCount=\(processIDs.count) retainedPayload=\(retainedPayload) retainedVersion=\(retainedVersion.map(String.init) ?? "none") retainedSemantics=\(retainedSemantics) retainedPID=\(record.lifecycleEvent?.agentPID == nil ? "missing" : "present") shellMarker=\(shellMarkerPID(record.shellMarker) == nil ? "absent" : "valid") shellProbe=\(optionalBool(shellActive)) agentRuntime=\(lifecycleActive)"
                )
                return AgentCurrentIntegrationTarget(
                    location: location,
                    foreground: foreground,
                    processIDs: processIDs,
                    shellIntegrationActive: shellActive,
                    agentIntegrationActive: lifecycleActive
                )
            }

            guard let snapshot = await rawProcessProvider() else {
                DiagnosticLogStore.appendAgentCenter(
                    "current-target-read sid=\(diagnosticSessionID) result=deferred stage=raw-process-snapshot"
                )
                return nil
            }
            guard !Task.isCancelled else { return nil }
            let foreground = currentIntegrationForeground(
                currentCommand: nil,
                processNames: snapshot.processNames
            )
            let location = AgentLocation(
                sessionID: sessionID,
                hostName: hostName,
                transportLabel: baseTransportLabel,
                tmuxSessionName: nil,
                windowID: nil,
                windowName: nil,
                paneID: nil
            )
            let shellActive: Bool?
            if foreground != .agent, !snapshot.processIDs.isEmpty {
                guard !Task.isCancelled else { return nil }
                shellActive = await probeShellIntegration?(
                    snapshot.processIDs,
                    foreground == .other
                )
                guard !Task.isCancelled else { return nil }
            } else {
                shellActive = false
            }
            DiagnosticLogStore.appendAgentCenter(
                "current-target-read sid=\(diagnosticSessionID) pane=raw result=success commandClass=raw foreground=\(String(describing: foreground)) processCount=\(snapshot.processIDs.count) retainedEvent=none retainedPID=missing shellMarker=unavailable shellProbe=\(optionalBool(shellActive)) agentRuntime=false"
            )
            return AgentCurrentIntegrationTarget(
                location: location,
                foreground: foreground,
                processIDs: snapshot.processIDs,
                shellIntegrationActive: shellActive,
                agentIntegrationActive: false
            )
        }

        let send: @MainActor (AgentLocation, [UInt8]) async -> Bool = { location, bytes in
            guard !bytes.isEmpty else {
                DiagnosticLogStore.appendAgentCenter(
                    "send-transport sid=\(diagnosticSessionID) result=rejected reason=empty"
                )
                return false
            }
            if let paneID = location.paneID {
                guard tmux.mode == .tmuxControl else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-transport sid=\(diagnosticSessionID) pane=\(paneID) result=rejected reason=not-in-tmux mode=\(String(describing: tmux.mode))"
                    )
                    return false
                }
                let acknowledged = await tmux.sendInputAcknowledged(
                    bytes,
                    toPane: PaneId(paneID)
                )
                if !acknowledged {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-transport sid=\(diagnosticSessionID) pane=\(paneID) result=failed byteCount=\(bytes.count) activePane=\(tmux.activePaneId?.rawValue.description ?? "missing") renderPending=\(tmux.isAuthoritativeRenderRefreshPending)"
                    )
                }
                return acknowledged
            } else {
                guard tmux.mode != .tmuxControl else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-transport sid=\(diagnosticSessionID) pane=raw result=rejected reason=tmux-location-mismatch"
                    )
                    return false
                }
                rawSend(bytes)
                return true
            }
        }

        let sendKey: @MainActor (AgentLocation, AgentInputKey) async -> Bool = { location, key in
            let bytes: [UInt8]
            switch key {
            case .enter: bytes = [0x0D]
            case .escape: bytes = [0x1B]
            }
            if let paneID = location.paneID {
                guard tmux.mode == .tmuxControl else {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-key sid=\(diagnosticSessionID) pane=\(paneID) result=rejected reason=not-in-tmux"
                    )
                    return false
                }
                let paneKey: PaneInputKey = key == .enter ? .enter : .escape
                let acknowledged = await tmux.sendKeyAcknowledged(
                    paneKey,
                    toPane: PaneId(paneID)
                )
                if !acknowledged {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-key sid=\(diagnosticSessionID) pane=\(paneID) result=failed key=\(key == .enter ? "enter" : "escape")"
                    )
                }
                return acknowledged
            }
            guard tmux.mode != .tmuxControl else {
                DiagnosticLogStore.appendAgentCenter(
                    "send-key sid=\(diagnosticSessionID) pane=raw result=rejected reason=tmux-location-mismatch"
                )
                return false
            }
            rawSend(bytes)
            return true
        }

        let sendLifecycleShellCommand: @MainActor (
            AgentCurrentIntegrationTarget,
            String,
            String
        ) async -> Bool = { expected, command, diagnosticAction in
            guard let target = await inspectCurrentIntegration(),
                  !Task.isCancelled,
                  target.foreground == .shell,
                  target.location == expected.location,
                  target.processIDs == expected.processIDs
            else {
                DiagnosticLogStore.appendAgentCenter(
                    "\(diagnosticAction) sid=\(diagnosticSessionID) result=rejected phase=fresh-target-check"
                )
                return false
            }

            // The inspection above is deliberately fresh, but a tmux pane
            // switch can still land between its control reply and this send.
            // Never apply setup text to a pane other than the one we proved
            // was a shell prompt.
            if let paneID = target.location.paneID {
                guard tmux.mode == .tmuxControl,
                      tmux.activePaneId == PaneId(paneID)
                else {
                    DiagnosticLogStore.appendAgentCenter(
                        "\(diagnosticAction) sid=\(diagnosticSessionID) pane=\(paneID) result=rejected phase=active-pane-check"
                    )
                    return false
                }
            } else {
                guard tmux.mode != .tmuxControl else {
                    DiagnosticLogStore.appendAgentCenter(
                        "\(diagnosticAction) sid=\(diagnosticSessionID) pane=raw result=rejected phase=transport-check"
                    )
                    return false
                }
            }
            guard !Task.isCancelled else { return false }
            let textAcknowledged = await send(target.location, Array(command.utf8))
            guard textAcknowledged, !Task.isCancelled else {
                DiagnosticLogStore.appendAgentCenter(
                    "\(diagnosticAction) sid=\(diagnosticSessionID) pane=\(target.location.paneID.map(String.init) ?? "raw") result=failed phase=text"
                )
                return false
            }
            // Return is a semantic terminal key, not a literal CR byte. Modern
            // TUIs and extended-keyboard tmux panes can distinguish the two.
            // Keep activation on the same path as Agent Center submissions so
            // the command cannot visibly land while its Enter disappears.
            let acknowledged = await sendKey(target.location, .enter)
            DiagnosticLogStore.appendAgentCenter(
                "\(diagnosticAction) sid=\(diagnosticSessionID) pane=\(target.location.paneID.map(String.init) ?? "raw") result=\(acknowledged ? "acknowledged" : "failed") phase=return"
            )
            return acknowledged
        }
        let applyLifecycleIntegrationToCurrentShell: @MainActor (AgentCurrentIntegrationTarget) async -> Bool = { expected in
            await sendLifecycleShellCommand(
                expected,
                RemoteAgentLifecycleIntegrationInstaller.applyToCurrentShellCommand,
                "shell-apply"
            )
        }
        let persistLifecycleIntegrationInCurrentShell: @MainActor (AgentCurrentIntegrationTarget) async -> Bool = { expected in
            await sendLifecycleShellCommand(
                expected,
                RemoteAgentLifecycleIntegrationInstaller.persistAndApplyToCurrentShellCommand,
                "shell-persist-and-apply"
            )
        }

        return AgentSessionSource(
            registrationID: UUID(),
            sessionID: sessionID,
            discover: discover,
            observe: observe,
            verifySend: verifySend,
            inspect: inspect,
            lifecycleIntegrationCacheKey: lifecycleIntegrationCacheKey,
            automaticallyProbeLifecycleIntegration: automaticallyProbeLifecycleIntegration,
            probeLifecycleIntegration: probeLifecycleIntegration,
            installLifecycleIntegration: installLifecycleIntegration,
            automaticallyInspectCurrentIntegration: automaticallyInspectCurrentIntegration,
            inspectCurrentIntegration: inspectCurrentIntegration,
            applyLifecycleIntegrationToCurrentShell: applyLifecycleIntegrationToCurrentShell,
            persistLifecycleIntegrationInCurrentShell: persistLifecycleIntegrationInCurrentShell,
            send: send,
            sendKey: sendKey,
            jump: { location in
                guard let paneID = location.paneID,
                      tmux.mode == .tmuxControl else { return }
                if let windowID = location.windowID {
                    // Use the controller's guarded user-mutation path. A raw
                    // control command would bypass continuity authority and
                    // let an Agent Center jump steal the peer's current grid
                    // from underneath the continued-elsewhere veil.
                    tmux.selectWindow(WindowId(windowID))
                }
                tmux.selectPane(PaneId(paneID))
            }
        )
    }

    private static func discoverTmux(
        sessionID: UUID,
        hostName: String,
        transportLabel: String,
        tmuxSessionName: String?,
        tmux: TmuxController,
        profiles: [SwipePadProfile],
        paneProcessProvider: PaneProcessProvider?,
        bracketedPasteProvider: BracketedPasteProvider,
        terminalBox: TerminalBox
    ) async -> AgentDiscoveryResult {
        let startedAt = Date.now
        guard await waitForTmuxQueryReadiness(
            tmux,
            requiresActivePane: true,
            context: "discovery",
            diagnosticSessionID: String(sessionID.uuidString.prefix(8))
        ) else {
            DiagnosticLogStore.appendAgentCenter(
                "discovery sid=\(sessionID.uuidString.prefix(8)) result=deferred stage=tmux-readiness"
            )
            return .unavailable
        }
        // Keep window_name last: tmux names may themselves contain tabs, while
        // the lifecycle JSON is compact and tab-free.
        let command = "list-panes -s -F '#{window_id}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{@tessera_agent_state}\t#{window_name}'"
        guard case .success(let lines) = await control(tmux, command) else {
            DiagnosticLogStore.appendAgentCenter(
                "discovery sid=\(sessionID.uuidString.prefix(8)) result=unavailable stage=list-panes"
            )
            return .unavailable
        }
        var targets: [AgentProbeTarget] = []
        var retainedCurrentCount = 0
        var retainedCompatibleCount = 0
        var retainedNeutralCount = 0
        var retainedRejectedCount = 0

        for line in lines {
            guard let record = parsePaneRecord(line) else { continue }
            if record.rawLifecyclePayload.isEmpty {
                // Empty is the ordinary state for non-agent panes.
            } else if let version = record.lifecycleEvent?.version {
                if record.lifecycleEvent?.isStatusNeutral == true {
                    retainedNeutralCount += 1
                }
                if version == AgentLifecycleEvent.supportedVersion {
                    retainedCurrentCount += 1
                } else {
                    retainedCompatibleCount += 1
                }
            } else {
                retainedRejectedCount += 1
            }
            var names = record.command.isEmpty ? [] : [record.command]
            var processIDs = Set<Int>()
            let needsIdentityProbe = record.lifecycleEvent?.agentPID != nil
            if (needsIdentityProbe || (
                !matchesAgent(names, profiles: profiles)
                    && shouldProbeDescendants(command: record.command)
            )),
               let paneProcessProvider,
               let panePID = record.panePID {
                guard let descendants = await paneProcessProvider(panePID) else {
                    DiagnosticLogStore.appendAgentCenter(
                        "discovery sid=\(sessionID.uuidString.prefix(8)) pane=\(record.paneID.rawValue) result=unavailable stage=descendant-process-snapshot commandClass=\(commandClass(record.command))"
                    )
                    return .unavailable
                }
                names.append(contentsOf: descendants.processNames)
                processIDs.formUnion(descendants.processIDs)
            }
            guard matchesAgent(names, profiles: profiles) else { continue }
            let isRendered = tmux.renderedPaneId == record.paneID
                || (tmux.controlPath == .sideChannel && tmux.activePaneId == record.paneID)
            let capture: PaneCapture?
            if isRendered, let local = visiblePaneCapture(terminalBox) {
                capture = local
            } else {
                capture = await capturePane(tmux, paneID: record.paneID)
            }
            guard let capture else {
                DiagnosticLogStore.appendAgentCenter(
                    "discovery sid=\(sessionID.uuidString.prefix(8)) pane=\(record.paneID.rawValue) result=unavailable stage=capture-pane"
                )
                return .unavailable
            }
            let location = AgentLocation(
                sessionID: sessionID,
                hostName: hostName,
                transportLabel: transportLabel,
                tmuxSessionName: tmuxSessionName,
                windowID: record.windowID.rawValue,
                windowName: record.windowName,
                paneID: record.paneID.rawValue
            )
            let bracketed = isRendered
                ? terminalBox.view?.getTerminal().bracketedPasteMode ?? false
                : bracketedPasteProvider(location) ?? false
            targets.append(AgentProbeTarget(
                location: location,
                processNames: names,
                processIDs: processIDs,
                visibleText: capture.text,
                currentInputLine: capture.currentInputLine,
                lifecycleEvent: record.lifecycleEvent,
                bracketedPasteEnabled: bracketed
            ))
        }
        let durationMs = Date.now.timeIntervalSince(startedAt) * 1_000
        if durationMs >= 250 {
            DiagnosticLogStore.appendAgentCenter(
                "discovery sid=\(sessionID.uuidString.prefix(8)) result=success panes=\(lines.count) agents=\(targets.count) retainedCurrent=\(retainedCurrentCount) retainedCompatible=\(retainedCompatibleCount) retainedNeutral=\(retainedNeutralCount) retainedRejected=\(retainedRejectedCount) durationMs=\(Int(durationMs)) slow=true"
            )
        }
        return .success(targets)
    }

    private static func inspectTmux(
        location: AgentLocation,
        paneID: PaneId,
        tmux: TmuxController,
        paneProcessProvider: PaneProcessProvider?,
        bracketedPasteProvider: BracketedPasteProvider,
        terminalBox: TerminalBox
    ) async -> AgentProbeTarget? {
        let command = "display-message -p -t \(paneID.description) '#{window_id}\t#{pane_pid}\t#{pane_current_command}\t#{@tessera_agent_state}\t#{window_name}'"
        guard case .success(let lines) = await control(tmux, command),
              let line = lines.first(where: { !$0.isEmpty }),
              let record = parseInspectionRecord(line, paneID: paneID)
        else { return nil }
        var names = record.command.isEmpty ? [] : [record.command]
        var processIDs = Set<Int>()
        if (record.lifecycleEvent?.agentPID != nil
            || shouldProbeDescendants(command: record.command)),
           let paneProcessProvider,
           let panePID = record.panePID {
            guard let descendants = await paneProcessProvider(panePID) else { return nil }
            names.append(contentsOf: descendants.processNames)
            processIDs.formUnion(descendants.processIDs)
        }
        let freshLocation = AgentLocation(
            sessionID: location.sessionID,
            hostName: location.hostName,
            transportLabel: location.transportLabel,
            tmuxSessionName: location.tmuxSessionName,
            windowID: record.windowID.rawValue,
            windowName: record.windowName,
            paneID: paneID.rawValue
        )
        let isRendered = tmux.renderedPaneId == paneID
            || (tmux.controlPath == .sideChannel && tmux.activePaneId == paneID)
        let capture: PaneCapture?
        if isRendered, let local = visiblePaneCapture(terminalBox) {
            capture = local
        } else {
            capture = await capturePane(tmux, paneID: paneID)
        }
        return AgentProbeTarget(
            location: freshLocation,
            processNames: names,
            processIDs: processIDs,
            visibleText: capture?.text,
            currentInputLine: capture?.currentInputLine,
            lifecycleEvent: record.lifecycleEvent,
            bracketedPasteEnabled: isRendered
                ? terminalBox.view?.getTerminal().bracketedPasteMode ?? false
                : bracketedPasteProvider(freshLocation) ?? false
        )
    }

    private struct PaneRecord {
        let windowID: WindowId
        let paneID: PaneId
        let panePID: Int?
        let command: String
        let windowName: String?
        let lifecycleEvent: AgentLifecycleEvent?
        let rawLifecyclePayload: String
    }

    private struct CurrentPaneRecord {
        let windowID: WindowId
        let paneID: PaneId
        let panePID: Int?
        let command: String
        let windowName: String?
        let lifecycleEvent: AgentLifecycleEvent?
        let rawLifecyclePayload: String
        let shellMarker: String
    }

    private static func inspectCurrentPane(
        _ tmux: TmuxController,
        paneID: PaneId
    ) async -> CurrentPaneRecord? {
        let command = "display-message -p -t \(paneID.description) '#{window_id}\t#{pane_id}\t#{pane_pid}\t#{pane_current_command}\t#{@tessera_agent_state}\t#{@tessera_agent_shell}\t#{window_name}'"
        guard case .success(let lines) = await control(tmux, command),
              let line = lines.first(where: { !$0.isEmpty })
        else { return nil }
        let fields = line.split(
            separator: "\t",
            maxSplits: 6,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.count == 7,
              let windowID = parseID(fields[0], prefix: "@"),
              let parsedPaneID = parseID(fields[1], prefix: "%"),
              parsedPaneID == paneID.rawValue
        else { return nil }
        return CurrentPaneRecord(
            windowID: WindowId(windowID),
            paneID: paneID,
            panePID: Int(fields[2]),
            command: fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            windowName: fields[6].isEmpty ? nil : fields[6],
            lifecycleEvent: AgentLifecycleEvent.decode(json: fields[4]),
            rawLifecyclePayload: fields[4],
            shellMarker: fields[5]
        )
    }

    private static func parsePaneRecord(_ line: String) -> PaneRecord? {
        let fields = line.split(
            separator: "\t",
            maxSplits: 5,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.count == 6,
              let windowID = parseID(fields[0], prefix: "@"),
              let paneID = parseID(fields[1], prefix: "%")
        else { return nil }
        return PaneRecord(
            windowID: WindowId(windowID),
            paneID: PaneId(paneID),
            panePID: Int(fields[2]),
            command: fields[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            windowName: fields[5].isEmpty ? nil : fields[5],
            lifecycleEvent: AgentLifecycleEvent.decode(json: fields[4]),
            rawLifecyclePayload: fields[4]
        )
    }

    private static func parseInspectionRecord(
        _ line: String,
        paneID: PaneId
    ) -> PaneRecord? {
        let fields = line.split(
            separator: "\t",
            maxSplits: 4,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard fields.count == 5,
              let windowID = parseID(fields[0], prefix: "@")
        else { return nil }
        return PaneRecord(
            windowID: WindowId(windowID),
            paneID: paneID,
            panePID: Int(fields[1]),
            command: fields[2].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            windowName: fields[4].isEmpty ? nil : fields[4],
            lifecycleEvent: AgentLifecycleEvent.decode(json: fields[3]),
            rawLifecyclePayload: fields[3]
        )
    }

    private static func parseID(_ value: String, prefix: Character) -> Int? {
        guard value.first == prefix else { return nil }
        return Int(value.dropFirst())
    }

    static func shouldProbeDescendants(command: String) -> Bool {
        let normalized = command.lowercased()
        if ["node", "bun", "bunx", "deno", "npm", "npx", "pnpm", "pnpx", "yarn"]
            .contains(normalized) {
            return true
        }
        // Claude Code's native installer currently exposes its release number
        // (for example `2.1.209`) as `pane_current_command` on macOS. The real
        // binary remains visible in the scoped process snapshot, so treat only
        // a strict dotted-numeric command as a launcher that needs that probe.
        return normalized.range(
            of: #"^[0-9]+(?:\.[0-9]+){2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func commandClass(_ command: String) -> String {
        if command.isEmpty { return "empty" }
        if matchesLifecycleAgent([command]) { return "agent" }
        if matchesSupportedShell([command]) { return "supported-shell" }
        if matchesUnsupportedShell([command]) { return "unsupported-shell" }
        if shouldProbeDescendants(command: command) {
            return command.range(
                of: #"^[0-9]+(?:\.[0-9]+){2,}$"#,
                options: .regularExpression
            ) == nil ? "launcher" : "semantic-version"
        }
        return "other"
    }

    private static func optionalBool(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    static func matchesSupportedShell(_ names: [String]) -> Bool {
        let supported = Set(["bash", "zsh"])
        return names.contains { name in
            let normalized = name
                .split(separator: "/")
                .last
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased() ?? ""
            return supported.contains(normalized)
        }
    }

    static func matchesUnsupportedShell(_ names: [String]) -> Bool {
        let unsupported = Set([
            "ash", "csh", "dash", "fish", "ksh", "mksh", "nu", "pwsh", "sh", "tcsh",
        ])
        return names.contains { name in
            let normalized = name
                .split(separator: "/")
                .last
                .map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                .lowercased() ?? ""
            return unsupported.contains(normalized)
        }
    }

    /// Top-bar lifecycle readiness is intentionally limited to the two
    /// providers whose hook contracts Tessera installs. Custom SwipePad
    /// process matchers must not turn vim or another program into an "agent"
    /// and trigger unsafe repair guidance.
    static func matchesLifecycleAgent(_ names: [String]) -> Bool {
        [SwipePadProfile.builtInClaudeCode, SwipePadProfile.builtInCodexCLI]
            .contains { profile in
                names.contains {
                    SwipePadActiveProfileResolver.matches(
                        profile: profile,
                        processName: $0
                    )
                }
            }
    }

    static func shellMarkerPID(_ marker: String) -> Int? {
        let fields = marker.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              Int(fields[0]) == RemoteAgentLifecycleIntegrationInstaller.integrationVersion,
              let pid = Int(fields[1]),
              pid > 1,
              Int(fields[2]) == RemoteAgentLifecycleIntegrationInstaller.integrationVersion
        else { return nil }
        return pid
    }

    static func lifecycleRuntimeActive(
        isAgent: Bool,
        lifecycleEvent: AgentLifecycleEvent?,
        processIDs: Set<Int>
    ) -> Bool {
        isAgent
            && lifecycleEvent?.provesRunningAgentIntegration == true
            && lifecycleEvent?.agentPID.map(processIDs.contains) == true
    }

    /// Provider descendants may sit behind node/bun/versioned launchers, so
    /// an agent match can use the whole foreground snapshot. Shell safety is
    /// stricter: tmux's current command (or the first scored raw-process
    /// candidate) must itself be the shell. A dormant shell ancestor behind
    /// vim must never authorize Tessera to type a source command into vim.
    static func currentIntegrationForeground(
        currentCommand: String?,
        processNames: [String]
    ) -> AgentIntegrationForeground {
        if matchesLifecycleAgent(processNames) { return .agent }
        let primaryNames: [String]
        if let currentCommand, !currentCommand.isEmpty {
            primaryNames = [currentCommand]
        } else {
            primaryNames = Array(processNames.prefix(1))
        }
        if matchesSupportedShell(primaryNames) { return .shell }
        if matchesUnsupportedShell(primaryNames) { return .unsupportedShell }
        return .other
    }

    private static func matchesAgent(
        _ names: [String],
        profiles: [SwipePadProfile]
    ) -> Bool {
        profiles.contains { profile in
            !profile.matchProcess.isEmpty && names.contains {
                SwipePadActiveProfileResolver.matches(
                    profile: profile,
                    processName: $0
                )
            }
        }
    }

    struct PaneCapture: Equatable {
        let text: String
        let currentInputLine: String?
    }

    private static func capturePane(
        _ tmux: TmuxController,
        paneID: PaneId
    ) async -> PaneCapture? {
        await capturePane(paneID: paneID) { command in
            await control(tmux, command)
        }
    }

    /// tmux control mode frames semicolon-separated commands as independent
    /// replies. Keep cursor metadata and pane capture as two queued commands;
    /// combining them gives one Tessera completion two tmux replies and loses
    /// the capture body on a real `-CC` channel.
    static func capturePane(
        paneID: PaneId,
        control: @MainActor (String) async -> Result<[String], TmuxController.CommandError>
    ) async -> PaneCapture? {
        let cursorCommand = "display-message -p -t \(paneID.description) '#{cursor_y}'"
        guard case .success(let cursorLines) = await control(cursorCommand),
              let cursorText = cursorLines.first(where: { !$0.isEmpty }),
              let cursorRow = Int(cursorText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        let captureCommand = "capture-pane -p -e -N -t \(paneID.description)"
        guard case .success(let capturedLines) = await control(captureCommand) else {
            return nil
        }
        let currentLine = capturedLines.indices.contains(cursorRow)
            ? AgentTerminalText.normalized(capturedLines[cursorRow])
            : nil
        return PaneCapture(
            text: capturedLines.joined(separator: "\n"),
            currentInputLine: currentLine
        )
    }

    private static func visiblePaneCapture(_ box: TerminalBox) -> PaneCapture? {
        let snapshot = visibleTerminalSnapshot(box)
        guard let text = snapshot.text else { return nil }
        return PaneCapture(text: text, currentInputLine: snapshot.currentInputLine)
    }

    private static func control(
        _ tmux: TmuxController,
        _ command: String
    ) async -> Result<[String], TmuxController.CommandError> {
        // Observer queries are intentionally rejected while an authoritative
        // repaint owns tmux's FIFO. That rejection is a scheduling signal, not
        // a failed host read. Wait off-wire until the repaint lands, then
        // retry the tiny check/send race instead of converting `.cancelled`
        // into a false "unavailable" state.
        let queryKind = controlQueryKind(command)
        for attempt in 0..<4 {
            guard await waitForTmuxQueryReadiness(
                tmux,
                requiresActivePane: false,
                context: "query-\(queryKind)"
            ) else {
                DiagnosticLogStore.appendAgentCenter(
                    "tmux-query kind=\(queryKind) result=cancelled stage=readiness attempt=\(attempt + 1)"
                )
                return .failure(.cancelled)
            }
            guard !Task.isCancelled else { return .failure(.cancelled) }

            let result: Result<[String], TmuxController.CommandError> =
                await withCheckedContinuation { continuation in
                    tmux.sendBackgroundControlQuery(command) { result in
                        continuation.resume(returning: result)
                    }
                }
            guard case .failure(.cancelled) = result,
                  tmux.mode == .tmuxControl,
                  attempt < 3
            else {
                switch result {
                case .success(let lines) where attempt > 0:
                    DiagnosticLogStore.appendAgentCenter(
                        "tmux-query kind=\(queryKind) result=recovered attempt=\(attempt + 1) lineCount=\(lines.count)"
                    )
                case .failure(let failure):
                    DiagnosticLogStore.appendAgentCenter(
                        "tmux-query kind=\(queryKind) result=failed attempt=\(attempt + 1) outcome=\(controlFailureKind(failure)) renderPending=\(tmux.isAuthoritativeRenderRefreshPending) activePane=\(tmux.activePaneId == nil ? "missing" : "present")"
                    )
                default:
                    break
                }
                return result
            }
            DiagnosticLogStore.appendAgentCenter(
                "tmux-query kind=\(queryKind) result=retry attempt=\(attempt + 1) reason=render-race"
            )
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return .failure(.cancelled) }
        }
        return .failure(.cancelled)
    }

    /// Attach hydration and foreground repaint normally settle well below a
    /// second, but a busy remote tmux can take several seconds. Poll only local
    /// controller state (no remote traffic), with cancellation and a bounded
    /// ten-second ceiling so a dead render owner cannot retain a task forever.
    private static func waitForTmuxQueryReadiness(
        _ tmux: TmuxController,
        requiresActivePane: Bool,
        context: String = "observer-query",
        diagnosticSessionID: String = "unscoped"
    ) async -> Bool {
        let startedAt = Date.now
        for attempt in 0..<101 {
            guard !Task.isCancelled, tmux.mode == .tmuxControl else {
                DiagnosticLogStore.appendAgentCenter(
                    "tmux-readiness sid=\(diagnosticSessionID) context=\(context) result=cancelled waitMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000)) mode=\(String(describing: tmux.mode))"
                )
                return false
            }
            if !tmux.isAuthoritativeRenderRefreshPending,
               (!requiresActivePane || tmux.activePaneId != nil) {
                if attempt > 0 {
                    DiagnosticLogStore.appendAgentCenter(
                        "tmux-readiness sid=\(diagnosticSessionID) context=\(context) result=ready waitMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000)) activePane=\(tmux.activePaneId == nil ? "missing" : "present") renderPending=false"
                    )
                }
                return true
            }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch {
                DiagnosticLogStore.appendAgentCenter(
                    "tmux-readiness sid=\(diagnosticSessionID) context=\(context) result=cancelled waitMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000)) stage=sleep"
                )
                return false
            }
        }
        DiagnosticLogStore.appendAgentCenter(
            "tmux-readiness sid=\(diagnosticSessionID) context=\(context) result=timeout waitMs=\(Int(Date.now.timeIntervalSince(startedAt) * 1_000)) activePane=\(tmux.activePaneId == nil ? "missing" : "present") renderPending=\(tmux.isAuthoritativeRenderRefreshPending)"
        )
        return false
    }

    private static func controlQueryKind(_ command: String) -> String {
        if command.hasPrefix("display-message ") { return "display-message" }
        if command.hasPrefix("capture-pane ") { return "capture-pane" }
        if command.hasPrefix("list-panes ") { return "list-panes" }
        return "other"
    }

    private static func controlFailureKind(
        _ failure: TmuxController.CommandError
    ) -> String {
        switch failure {
        case .notInTmuxMode: return "not-in-tmux"
        case .tmuxError: return "tmux-error"
        case .cancelled: return "cancelled"
        }
    }

    private static func visibleTerminalSnapshot(
        _ box: TerminalBox
    ) -> (text: String?, currentInputLine: String?) {
        guard let terminal = box.view?.getTerminal() else { return (nil, nil) }
        let data = terminal.getBufferAsData(kind: .active)
        guard let full = String(data: data, encoding: .utf8) else { return (nil, nil) }
        let rows = max(terminal.rows, 1)
        let visibleLines = Array(full.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).suffix(rows))
        let cursorRow = terminal.getCursorLocation().y
        let currentLine = visibleLines.indices.contains(cursorRow)
            ? AgentTerminalText.normalized(String(visibleLines[cursorRow]))
            : nil
        return (
            visibleLines.joined(separator: "\n"),
            currentLine
        )
    }
}
