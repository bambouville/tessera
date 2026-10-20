import Foundation
import SwiftTerm
import TesseraCore
import TmuxControl

@MainActor
enum AgentSessionSourceFactory {
    /// nil means the remote probe failed and must not be interpreted as an
    /// authoritative “no matching process” result.
    typealias ProcessProvider = @MainActor () async -> SwipePadPlainSSHProcessProbe.Snapshot?
    typealias PaneProcessProvider = @MainActor (Int, Int?) async -> SwipePadPlainSSHProcessProbe.Snapshot?
    /// Discovery's pane read, which it may reuse briefly: the snapshot and
    /// when its read began. `expectedPID` is the agent the pane's lifecycle
    /// names; a reused read must have seen it or have been taken for it.
    typealias DiscoveryPaneProcessProvider = @MainActor (
        _ panePID: Int,
        _ expectedPID: Int?
    ) async -> (snapshot: SwipePadPlainSSHProcessProbe.Snapshot, takenAt: Date)?

    /// Remote descendant `ps` reads discovery reuses for a short window.
    struct DiscoveryProcessReads {
        struct Read {
            let snapshot: SwipePadPlainSSHProcessProbe.Snapshot
            let requestedAt: Date
            let completedAt: Date
            /// The lifecycle PID the read was taken to look for. The frame
            /// naming it was already on the pane, so the read began after that
            /// agent had started; its absence from the read is an answer.
            let lookedFor: Int?
        }

        static let reuseInterval: TimeInterval = 2
        private var reads: [Int: Read] = [:]

        /// A read that predates the agent `expectedPID` names would hide it,
        /// or leave its pane out of discovery altogether.
        func reusable(panePID: Int, expectedPID: Int?, now: Date = .now) -> Read? {
            guard let read = reads[panePID],
                  now.timeIntervalSince(read.completedAt) < Self.reuseInterval
            else { return nil }
            guard let expectedPID,
                  !read.snapshot.processIDs.contains(expectedPID),
                  read.lookedFor != expectedPID
            else { return read }
            return nil
        }

        mutating func store(_ read: Read, panePID: Int) { reads[panePID] = read }
        mutating func removeAll() { reads.removeAll() }
    }
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
        rawProcessProofProvider: (@MainActor (Int?) async -> SwipePadPlainSSHProcessProbe.Snapshot?)? = nil,
        paneProcessProvider: PaneProcessProvider? = nil,
        bracketedPasteProvider: @escaping BracketedPasteProvider = { _ in nil },
        lifecycleIntegrationCacheKey: String? = nil,
        automaticallyProbeLifecycleIntegration: Bool = false,
        probeLifecycleIntegrationOnCurrentCarrier: (@MainActor () async throws -> AgentLifecycleHostInstallation?)? = nil,
        probeLifecycleIntegration: (@MainActor () async throws -> AgentLifecycleHostInstallation)? = nil,
        installLifecycleIntegration: (@MainActor () async throws -> Void)? = nil,
        automaticallyInspectCurrentIntegration: @escaping @MainActor () -> Bool = { true },
        probeShellIntegration: ShellIntegrationProvider? = nil,
        sessionCommands: AppleSessionCommandFacade,
        rawSend _: @escaping @MainActor ([UInt8]) -> Void,
        projectorExecAvailability: @escaping @MainActor (
            AgentTerminalBinding,
            @escaping @MainActor @Sendable (AgentTerminalBinding) -> Bool
        ) -> AppleAgentExecAvailability = { _, _ in .unavailable(.staleCarrier) }
    ) -> AgentSessionSource {
        let registrationID = UUID()
        let diagnosticSessionID = String(sessionID.uuidString.prefix(8))
        // Keep the existing factory argument compatible with session views;
        // agent writes consume the facade's ordered backend admission instead.
        let rawSend: @MainActor ([UInt8]) async -> Bool = { bytes in
            await withCheckedContinuation { continuation in
                sessionCommands.sendInputAcknowledged(bytes) { delivery in
                    continuation.resume(returning: delivery == .sent)
                }
            }
        }
        DiagnosticLogStore.appendAgentCenter(
            "source-created sid=\(diagnosticSessionID) transport=\(baseTransportLabel) protocol=\(AgentLifecycleEvent.supportedVersion) autoHostProbe=\(automaticallyProbeLifecycleIntegration)"
        )
        // A shell/shim-enabled pane keeps the same root PID while a tab switch or
        // surface refresh can request discovery several times in quick
        // succession. Reuse that expensive remote descendant `ps` result for
        // a short window; safety inspections before sends still use the fresh
        // provider below.
        var descendantProcessCache = DiscoveryProcessReads()
        let discoveryPaneProcessProvider: DiscoveryPaneProcessProvider? = paneProcessProvider.map { provider in
            { panePID, expectedPID in
                if let cached = descendantProcessCache.reusable(panePID: panePID, expectedPID: expectedPID) {
                    return (cached.snapshot, cached.requestedAt)
                }
                let requestedAt = Date.now
                guard let snapshot = await provider(panePID, expectedPID) else { return nil }
                descendantProcessCache.store(
                    .init(snapshot: snapshot, requestedAt: requestedAt, completedAt: .now, lookedFor: expectedPID),
                    panePID: panePID
                )
                return (snapshot, requestedAt)
            }
        }

        let inspectRawProcess = rawProcessProofProvider ?? { _ in await rawProcessProvider() }
        // Each reason is logged once per change: the sweep repeats every few
        // seconds, and an observation it cannot make retires nothing.
        let readOccupancy: @MainActor ([AgentTerminalBinding]) async -> (AgentSessionOccupancySnapshot?, String) = { bindings in
            guard let context = bindings.first, bindings.count <= occupancyPaneLimit else { return (nil, "bindings") }
            guard bindings.allSatisfy({
                      $0.liveSessionID == sessionID && $0.transport == context.transport
                          && $0.tmuxSession == context.tmuxSession && $0.agentPID != nil
                  }) else { return (nil, "mixed-context") }
            let current = {
                !Task.isCancelled
                    && readCarrierTransport(baseTransportLabel: baseTransportLabel, usesTmux: tmux.mode == .tmuxControl) == context.transport
                    && (tmux.mode != .tmuxControl || tmuxSessionName() == context.tmuxSession)
            }
            guard current() else { return (nil, "carrier-changed") }
            if tmux.mode != .tmuxControl {
                guard bindings.allSatisfy({ $0.paneID == nil }) else { return (nil, "pane-binding") }
                guard let snapshot = await inspectRawProcess(context.agentPID), current(),
                      snapshot.complete || snapshot.truncated else { return (nil, "process-read") }
                return (.init(panes: [occupancyPane(paneID: nil, snapshot: snapshot)]), "ok")
            }
            guard case .success(let lines) = await control(tmux, "list-panes -a -F '#{pane_id} #{pane_pid}'"),
                  current() else { return (nil, "list-panes") }
            guard let listed = parseOccupancyPanes(lines) else { return (nil, "list-parse") }
            var panes: [AgentOccupancyObservation.Pane] = []
            var seen = Set<Int>()
            var missing = 0
            var unread = 0
            for binding in bindings {
                guard let paneID = binding.paneID.flatMap(Int.init), paneID >= 0 else { return (nil, "pane-id") }
                guard seen.insert(paneID).inserted else { continue }
                guard let rootPID = listed.roots[paneID] else {
                    if listed.complete {
                        missing += 1
                        panes.append(.init(paneID: String(paneID), exists: false, complete: true, processes: []))
                    }
                    continue
                }
                guard let paneProcessProvider,
                      let snapshot = await paneProcessProvider(rootPID, binding.agentPID),
                      snapshot.complete || snapshot.truncated else { unread += 1; continue }
                guard current() else { return (nil, "carrier-changed") }
                panes.append(occupancyPane(paneID: String(paneID), snapshot: snapshot))
            }
            guard current() else { return (nil, "carrier-changed") }
            let outcome = "ok missing=\(missing) unread=\(unread) listed=\(listed.complete ? "complete" : "partial")"
            return (.init(panes: panes, allPaneIDs: listed.complete ? listed.roots.keys.sorted().map(String.init) : nil), outcome)
        }
        var lastOccupancyOutcome: String?
        let observeOccupancy: @MainActor ([AgentTerminalBinding]) async -> AgentSessionOccupancySnapshot? = { bindings in
            let (snapshot, outcome) = await readOccupancy(bindings)
            if outcome != lastOccupancyOutcome {
                lastOccupancyOutcome = outcome
                DiagnosticLogStore.appendAgentCenter(
                    "occupancy-read sid=\(diagnosticSessionID) bindings=\(bindings.count) result=\(outcome)"
                )
            }
            return snapshot
        }
        var lastRawLifecyclePID: Int?
        let discoverForLifecycle: @MainActor (Int?) async -> AgentDiscoveryResult = { expectedPID in
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
            if let expectedPID { lastRawLifecyclePID = expectedPID }
            let requestedAt = Date.now
            guard let processes = await inspectRawProcess(expectedPID ?? lastRawLifecyclePID) else { return .unavailable }
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
                cursorRow: snapshot.cursorRow,
                cursorColumn: snapshot.cursorColumn,
                cursorVisible: snapshot.cursorVisible,
                screenEvidence: snapshot.screenEvidence,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false,
                processSnapshotTakenAt: requestedAt
            )])
        }

        let discover: @MainActor () async -> AgentDiscoveryResult = { await discoverForLifecycle(nil) }
        let inspectInputTarget: @MainActor (AgentLocation, Int?) async -> AgentProbeTarget? = { location, expectedPID in
            if let paneID = location.paneID, tmux.mode == .tmuxControl {
                return await inspectTmux(
                    location: location,
                    paneID: PaneId(paneID),
                    expectedPID: expectedPID,
                    tmux: tmux,
                    paneProcessProvider: paneProcessProvider,
                    bracketedPasteProvider: bracketedPasteProvider,
                    terminalBox: terminalBox
                )
            }
            guard var processes = await inspectRawProcess(expectedPID) else { return nil }
            guard matchesAgent(processes.processNames, profiles: profiles()) else { return nil }
            let ready = await readyTerminalSnapshot(terminalBox)
            guard !Task.isCancelled, ready.snapshot.text != nil else { return nil }
            if ready.waited {
                // Waiting can outlive the previous PID proof. Re-prove, then
                // capture immediately; a new partial frame fails this attempt.
                guard let fresh = await inspectRawProcess(expectedPID),
                      matchesAgent(fresh.processNames, profiles: profiles()) else { return nil }
                processes = fresh
            }
            let snapshot = ready.waited ? visibleTerminalSnapshot(terminalBox) : ready.snapshot
            return AgentProbeTarget(
                location: location,
                processNames: processes.processNames,
                processIDs: processes.processIDs,
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                cursorRow: snapshot.cursorRow,
                cursorColumn: snapshot.cursorColumn,
                cursorVisible: snapshot.cursorVisible,
                screenEvidence: snapshot.screenEvidence,
                bracketedPasteEnabled: terminalBox.view?.getTerminal().bracketedPasteMode ?? false
            )
        }

        let inspect: @MainActor (AgentLocation) async -> AgentProbeTarget? = { location in
            await inspectInputTarget(location, nil)
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
                    cursorRow: capture?.cursorRow,
                    cursorColumn: capture?.cursorColumn,
                    cursorVisible: capture?.cursorVisible,
                    screenEvidence: capture?.screenEvidence,
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
                cursorRow: snapshot.cursorRow,
                cursorColumn: snapshot.cursorColumn,
                cursorVisible: snapshot.cursorVisible,
                screenEvidence: snapshot.screenEvidence,
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
                    cursorRow: capture.cursorRow,
                    cursorColumn: capture.cursorColumn,
                    cursorVisible: capture.cursorVisible,
                    screenEvidence: capture.screenEvidence,
                    bracketedPasteEnabled: bracketedPasteProvider(location) ?? false
                )
            }
            let snapshot = visibleTerminalSnapshot(terminalBox)
            return AgentProbeTarget(
                location: location,
                processNames: [],
                visibleText: snapshot.text,
                currentInputLine: snapshot.currentInputLine,
                cursorRow: snapshot.cursorRow,
                cursorColumn: snapshot.cursorColumn,
                cursorVisible: snapshot.cursorVisible,
                screenEvidence: snapshot.screenEvidence,
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
                    guard let descendants = await paneProcessProvider(panePID, record.lifecycleEvent?.agentPID) else {
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
                let providerClassification = AgentIntegrationForegroundClassifier.classify(
                    executables: names
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
                    agentIntegrationActive: lifecycleActive,
                    agentRequiresLifecycleHook: foreground == .agent
                        ? providerClassification.requiresLifecycleHook
                        : nil
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
            let providerClassification = AgentIntegrationForegroundClassifier.classify(
                executables: snapshot.processNames
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
                agentIntegrationActive: false,
                agentRequiresLifecycleHook: foreground == .agent
                    ? providerClassification.requiresLifecycleHook
                    : nil
            )
        }

        // Refusals before the first byte. A failed pane ACK stays ambiguous;
        // raw sends below return the ordered transport's admission result.
        let sendRefusal: @MainActor (AgentLocation, [UInt8]) -> String? = { location, bytes in
            if bytes.isEmpty { return "empty" }
            if location.paneID != nil {
                guard tmux.mode == .tmuxControl else { return "not-in-tmux" }
                return nil
            }
            return tmux.mode == .tmuxControl ? "tmux-location-mismatch" : nil
        }
        // `send` applies the same refusals, so the pre-write check and the
        // write can never disagree about which sends are refused.
        let send: @MainActor (AgentLocation, [UInt8]) async -> Bool = { location, bytes in
            if let refusal = sendRefusal(location, bytes) {
                DiagnosticLogStore.appendAgentCenter(
                    "send-transport sid=\(diagnosticSessionID) pane=\(location.paneID.map(String.init) ?? "raw") result=rejected reason=\(refusal) mode=\(String(describing: tmux.mode))"
                )
                return false
            }
            if let paneID = location.paneID {
                // The planner keeps bytes for raw/older consumers. Fixed key
                // encodings must remain named keys on tmux's pane protocol.
                if let key = AgentPromptAnswerKey(bytes: String(decoding: bytes, as: UTF8.self)),
                   let paneKey = SessionTmuxPaneKey(tmuxKeyName: key.rawValue) {
                    return await sessionCommands.sendTmuxPaneKeyAcknowledged(paneKey, paneID: PaneId(paneID))
                }
                let acknowledged = await sessionCommands
                    .sendTmuxPaneInputAcknowledged(bytes, paneID: PaneId(paneID))
                if !acknowledged {
                    DiagnosticLogStore.appendAgentCenter(
                        "send-transport sid=\(diagnosticSessionID) pane=\(paneID) result=failed byteCount=\(bytes.count) activePane=\(tmux.activePaneId?.rawValue.description ?? "missing") renderPending=\(tmux.isAuthoritativeRenderRefreshPending)"
                    )
                }
                return acknowledged
            }
            return await rawSend(bytes)
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
                let paneKey: SessionTmuxPaneKey = key == .enter ? .enter : .escape
                let acknowledged = await sessionCommands
                    .sendTmuxPaneKeyAcknowledged(paneKey, paneID: PaneId(paneID))
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
            return await rawSend(bytes)
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
        let launchAgent: @MainActor (AgentLaunchPlan) async throws -> AgentLaunchReceipt = { plan in
            guard plan.intent.liveSessionID == sessionID,
                  tmux.mode == .tmuxControl else { throw AgentActionError.staleBinding }

            guard let correlatedRequestID = plan.requestID else {
                throw AgentActionError.invalidLaunch
            }
            let requestID = correlatedRequestID.uuidString.lowercased()
            var request: [String: Any] = [
                "v": 1,
                "requestID": requestID,
                "provider": plan.intent.providerID.rawValue,
                "task": plan.intent.task,
                "directory": plan.intent.workingDirectory.value,
            ]
            switch plan.intent.kind {
            case .spawn:
                request["kind"] = "spawn"
            case .fork(let source, _):
                request["kind"] = "fork"
                request["source"] = ["providerSessionID": source.threadID.providerSessionID]
            }
            switch plan.intent.isolation {
            case .currentWorktree:
                request["isolation"] = ["kind": "current"]
            case .newWorktree(let branch):
                request["isolation"] = ["kind": "worktree", "branch": branch]
            }
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            guard data.count <= 65_536 else { throw AgentActionError.invalidLaunch }
            let bufferName = "tessera-agent-launch-\(requestID)"
            let encoded = data.base64EncodedString()
            guard case .success = await control(
                tmux,
                "set-buffer -b \(tmuxQuoted(bufferName)) \(tmuxQuoted(encoded))"
            ) else { throw AgentActionError.unavailable }

            // All variable content is first transferred as a base64 tmux
            // buffer. The new pane receives one fixed shell program plus the
            // UUID-shaped buffer name; task/path/provider text never enters a
            // shell command.
            let helper = "{ tmux show-buffer -b \(bufferName); tmux delete-buffer -b \(bufferName); } | \"$HOME/.config/tessera/tessera-agent-launch\" --request-base64-stdin"
            let placementCommand: String
            switch plan.intent.placement {
            case .newWindow(let name):
                placementCommand = TmuxWindowCommands.newWindowAtEnd(
                    target: tmux.snapshot.sessionID?.description,
                    detached: true,
                    name: name.map { String($0.prefix(128)) },
                    printFormat: "#{pane_id}",
                    command: helper
                )
            case .split(let windowID, let paneID, let axis):
                let target = paneID.map { "%\($0)" } ?? "@\(windowID)"
                let flag = axis == .right ? "-h" : "-v"
                placementCommand = "split-window -d -P -F '#{pane_id}' \(flag) -t \(tmuxQuoted(target)) \(tmuxQuoted(helper))"
            }
            guard case .success(let placementLines) = await control(tmux, placementCommand),
                  let paneID = placementLines.first,
                  paneID.hasPrefix("%") else {
                _ = await control(tmux, "delete-buffer -b \(tmuxQuoted(bufferName))")
                throw AgentActionError.unavailable
            }
            // A pane ID alone can be recycled or moved between windows. Bind
            // the receipt to the control client's current window identity
            // before accepting the helper's lifecycle follow-up.
            guard case .success(let windowLines) = await control(
                tmux,
                "display-message -p -t \(tmuxQuoted(paneID)) '#{window_id}'"
            ), let rawWindowID = windowLines.first,
              rawWindowID.hasPrefix("@"), rawWindowID.count > 1
            else {
                throw AgentActionError.verificationFailed
            }
            let windowID = String(rawWindowID.dropFirst())

            for _ in 0..<50 {
                if case .success(let lines) = await control(
                    tmux,
                    "show-options -p -v -t \(tmuxQuoted(paneID)) @tessera_agent_launch_receipt"
                ), let line = lines.first,
                   let receiptData = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
                   object["kind"] as? String == "launchReceipt",
                   object["requestID"] as? String == requestID,
                   object["provider"] as? String == plan.intent.providerID.rawValue,
                   let receipt = AgentLaunchReceipt(
                       value: "\(requestID):\(paneID)",
                       requestID: correlatedRequestID,
                       providerSessionID: nil,
                       windowID: windowID,
                       paneID: paneID,
                       createdWorktree: object["worktreeCreated"] as? Bool
                   ) {
                    return receipt
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AgentActionError.verificationFailed
        }

        // Launch directories are not guessed from a shell prompt or a host
        // home directory. This asks the existing, already-owned tmux control
        // client for the exact pane's `pane_current_path`, then verifies that
        // tmux still names the binding's pane/window in the same response.
        // Raw SSH/Mosh returns no directory from this closure: launch/fork is
        // live tmux only and remains unavailable outside that route.
        let validatedRemoteDirectories: @MainActor (AgentTerminalBinding) async -> [String] = { binding in
            guard binding.liveSessionID == sessionID,
                  binding.hasCurrentTmuxTarget,
                  tmux.mode == .tmuxControl,
                  let paneText = binding.paneID.map({ normalizedTmuxID($0, prefix: "%") }),
                  let paneRaw = Int(paneText)
            else { return [] }
            let paneID = PaneId(paneRaw)
            let command = "display-message -p -t \(paneID.description) '#{window_id}\\t#{pane_id}\\t#{pane_current_path}'"
            guard case .success(let lines) = await control(tmux, command),
                  let line = lines.first(where: { !$0.isEmpty }),
                  let directory = validatedTmuxCurrentDirectory(
                      line,
                      expectedWindowID: binding.windowID,
                      expectedPaneID: binding.paneID
                  )
            else { return [] }
            return [directory]
        }

        // Inventory/search may legitimately begin before a currently rendered
        // pane contains an agent.  Keep that read carrier separate from every
        // action binding: it identifies only the already-owned session and is
        // accepted solely by the projector-exec seam.
        let readCarrier: @MainActor () -> AgentTerminalBinding? = {
            let usesTmux = tmux.mode == .tmuxControl
            let transport = readCarrierTransport(
                baseTransportLabel: baseTransportLabel,
                usesTmux: usesTmux
            )
            return AgentTerminalBinding(
                liveSessionID: sessionID,
                carrierGeneration: 0,
                incarnation: AgentIncarnationToken("read-carrier-\(registrationID.uuidString)")!,
                transport: transport,
                tmuxSession: usesTmux ? tmuxSessionName() : nil,
                windowID: nil,
                paneID: nil,
                agentPID: nil,
                capabilities: [.observe]
            )
        }

        return AgentSessionSource(
            registrationID: registrationID,
            sessionID: sessionID,
            discover: discover,
            discoverForLifecycle: discoverForLifecycle,
            observeOccupancy: observeOccupancy,
            observe: observe,
            verifySend: verifySend,
            inspect: inspect,
            inspectInputTarget: inspectInputTarget,
            lifecycleIntegrationCacheKey: lifecycleIntegrationCacheKey,
            automaticallyProbeLifecycleIntegration: automaticallyProbeLifecycleIntegration,
            probeLifecycleIntegrationOnCurrentCarrier: probeLifecycleIntegrationOnCurrentCarrier,
            probeLifecycleIntegration: probeLifecycleIntegration,
            installLifecycleIntegration: installLifecycleIntegration,
            automaticallyInspectCurrentIntegration: automaticallyInspectCurrentIntegration,
            inspectCurrentIntegration: inspectCurrentIntegration,
            applyLifecycleIntegrationToCurrentShell: applyLifecycleIntegrationToCurrentShell,
            persistLifecycleIntegrationInCurrentShell: persistLifecycleIntegrationInCurrentShell,
            send: send,
            sendRefusal: sendRefusal,
            sendKey: sendKey,
            jump: { location in
                guard let paneID = location.paneID,
                      tmux.mode == .tmuxControl else { return }
                // ContentView reveals and explicitly shows this carrier, then
                // routes the exact target through SessionRegistry's bounded
                // focus request. Selecting here would precede that show.
                DiagnosticLogStore.appendAgentCenter(
                    "terminal-focus sid=\(diagnosticSessionID) pane=\(paneID) result=deferred-to-reveal"
                )
            },
            projectorExecAvailability: projectorExecAvailability,
            readCarrier: readCarrier,
            validatedRemoteDirectories: validatedRemoteDirectories,
            supportsTmuxLaunch: { tmux.mode == .tmuxControl },
            launchAgent: launchAgent,
            invalidateProcessSnapshots: { descendantProcessCache.removeAll() }
        )
    }

    static let occupancyPaneLimit = 256

    struct OccupancyPaneList {
        let roots: [Int: Int]
        let complete: Bool
    }

    static func parseOccupancyPanes(_ lines: [String]) -> OccupancyPaneList? {
        // An attached control client always has at least one pane; an empty
        // reply is not evidence that every bound pane closed.
        guard !lines.isEmpty else { return nil }
        var roots: [Int: Int] = [:]
        for line in lines.prefix(occupancyPaneLimit) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0].hasPrefix("%"),
                  let paneID = Int(fields[0].dropFirst()), paneID >= 0,
                  let pid = Int(fields[1]), pid > 1,
                  roots.updateValue(pid, forKey: paneID) == nil else { return nil }
        }
        return .init(roots: roots, complete: lines.count < occupancyPaneLimit)
    }

    static func occupancyPane(paneID: String?, snapshot: SwipePadPlainSSHProcessProbe.Snapshot) -> AgentOccupancyObservation.Pane {
        // Every provider a process's executable names: when two match, both
        // pairs are reported, so neither route is retired on a guess. A
        // process naming none (a versioned native binary) is still present.
        let classified = snapshot.attachedProcesses.map { process -> (pid: Int, providers: [AgentProviderID]) in
            (process.pid, AgentProviderRegistry.builtIn.allManifests.filter { manifest in
                manifest.id != .custom && manifest.processMatchers.contains { matcher in
                    process.processNames.contains { name in
                        matcher.executableNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    }
                }
            }.map(\.id))
        }
        return .init(paneID: paneID, exists: true, complete: snapshot.complete && !snapshot.truncated,
                     processes: classified.flatMap { entry in entry.providers.map { .init(pid: entry.pid, providerID: $0) } },
                     unclassifiedPIDs: classified.filter { $0.providers.isEmpty }.map(\.pid).sorted())
    }

    static func readCarrierTransport(
        baseTransportLabel: String,
        usesTmux: Bool
    ) -> AgentTransportKind {
        let usesMosh = baseTransportLabel.localizedCaseInsensitiveContains("mosh")
        switch (usesMosh, usesTmux) {
        case (false, false): return .ssh
        case (false, true): return .sshTmux
        case (true, false): return .mosh
        case (true, true): return .moshTmux
        }
    }

    /// Parses a bounded `display-message` record and rejects anything that
    /// cannot be represented by the shared remote-path policy. Kept pure so
    /// malformed tmux output cannot become a launch target unnoticed.
    static func validatedTmuxCurrentDirectory(
        _ line: String,
        expectedWindowID: String?,
        expectedPaneID: String?
    ) -> String? {
        let fields = line.split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let expectedWindowID,
              let expectedPaneID,
              fields.count == 3,
              let windowID = WindowId(wireValue: fields[0]),
              let paneID = PaneId(wireValue: fields[1]),
              normalizedTmuxID(expectedWindowID, prefix: "@") == String(windowID.rawValue),
              normalizedTmuxID(expectedPaneID, prefix: "%") == String(paneID.rawValue),
              !fields[2].unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              let path = AgentRemotePath(fields[2])
        else { return nil }
        return path.value
    }

    private static func normalizedTmuxID(_ value: String, prefix: Character) -> String {
        value.first == prefix ? String(value.dropFirst()) : value
    }

    private static func tmuxQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func discoverTmux(
        sessionID: UUID,
        hostName: String,
        transportLabel: String,
        tmuxSessionName: String?,
        tmux: TmuxController,
        profiles: [SwipePadProfile],
        paneProcessProvider: DiscoveryPaneProcessProvider?,
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
        // A live tmux session necessarily has at least one pane. An empty or
        // partially malformed reply is not authoritative evidence of absence
        // (for example, a displaced command reply after framing corruption).
        guard !Task.isCancelled, hasCompleteDiscoveryPaneReply(lines) else {
            DiagnosticLogStore.appendAgentCenter(
                "discovery sid=\(sessionID.uuidString.prefix(8)) result=unavailable stage=list-panes-validation rows=\(lines.count)"
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
            // No read at all proves nothing about any PID.
            var processSnapshotTakenAt = Date.distantPast
            let needsIdentityProbe = record.lifecycleEvent?.agentPID != nil
            if (needsIdentityProbe || (
                !matchesAgent(names, profiles: profiles)
                    && shouldProbeDescendants(command: record.command)
            )),
               let paneProcessProvider,
               let panePID = record.panePID {
                guard let descendants = await paneProcessProvider(panePID, record.lifecycleEvent?.agentPID) else {
                    DiagnosticLogStore.appendAgentCenter(
                        "discovery sid=\(sessionID.uuidString.prefix(8)) pane=\(record.paneID.rawValue) result=unavailable stage=descendant-process-snapshot commandClass=\(commandClass(record.command))"
                    )
                    return .unavailable
                }
                names.append(contentsOf: descendants.snapshot.processNames)
                processIDs.formUnion(descendants.snapshot.processIDs)
                processSnapshotTakenAt = descendants.takenAt
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
                cursorRow: capture.cursorRow,
                cursorColumn: capture.cursorColumn,
                cursorVisible: capture.cursorVisible,
                screenEvidence: capture.screenEvidence,
                lifecycleEvent: record.lifecycleEvent,
                bracketedPasteEnabled: bracketed,
                processSnapshotTakenAt: processSnapshotTakenAt
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
        expectedPID: Int?,
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
        let processToProve = expectedPID ?? record.lifecycleEvent?.agentPID
        if (processToProve != nil
            || shouldProbeDescendants(command: record.command)),
           let paneProcessProvider,
           let panePID = record.panePID {
            guard let descendants = await paneProcessProvider(panePID, processToProve) else { return nil }
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
        if actionInspectionUsesLocalGrid(controlPath: tmux.controlPath, renderedPaneID: tmux.renderedPaneId, paneID: paneID),
           let local = visiblePaneCapture(terminalBox) {
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
            cursorRow: capture?.cursorRow,
            cursorColumn: capture?.cursorColumn,
            cursorVisible: capture?.cursorVisible,
            screenEvidence: capture?.screenEvidence,
            lifecycleEvent: record.lifecycleEvent,
            bracketedPasteEnabled: isRendered
                ? terminalBox.view?.getTerminal().bracketedPasteMode ?? false
                : bracketedPasteProvider(freshLocation) ?? false
        )
    }

    /// Actions gate on this capture. Only inline `%output` renders the pane's
    /// own bytes. A mosh screen replicates the whole tmux window (every
    /// split, mosh's frame timing), and mosh-server drops SGR 2, so Claude's
    /// DIM suggestion reads as a typed draft there. The side channel always
    /// asks tmux for the exact pane, whose `capture-pane -e` keeps DIM, even
    /// when the ledger records that pane as rendered. A capture that did not
    /// settle reports no text, and callers re-inspect.
    static func actionInspectionUsesLocalGrid(controlPath: TmuxController.ControlPath, renderedPaneID: PaneId?, paneID: PaneId) -> Bool {
        controlPath == .inline && renderedPaneID == paneID
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

    static func hasCompleteDiscoveryPaneReply(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        var paneIDs = Set<PaneId>()
        return lines.allSatisfy { line in
            guard let record = parsePaneRecord(line) else { return false }
            return paneIDs.insert(record.paneID).inserted
        }
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
        AgentIntegrationForegroundClassifier.classify(executables: names).foreground == .shell
    }

    static func matchesUnsupportedShell(_ names: [String]) -> Bool {
        AgentIntegrationForegroundClassifier.classify(executables: names).foreground == .unsupportedShell
    }

    /// Top-bar lifecycle readiness is limited to providers whose hook contract
    /// is compiled into Core. Inventory/RPC-only providers remain Agent Center
    /// sources without producing hook-repair guidance.
    static func matchesLifecycleAgent(_ names: [String]) -> Bool {
        let classification = AgentIntegrationForegroundClassifier.classify(executables: names)
        return classification.foreground == .agent && classification.requiresLifecycleHook
    }

    /// A pane marker from any release since the shell floor, which left the
    /// same shell state as this one, or from a newer one: a newer app's shell
    /// integration keeps serving this app while the installed floor admits it.
    static func shellMarkerPID(_ marker: String) -> Int? {
        let fields = marker.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3,
              (1...5).contains(fields[0].count),
              fields[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(fields[0]),
              version >= RemoteAgentLifecycleIntegrationInstaller.shellIntegrationCompatibleFrom,
              fields[2] == fields[0],
              let pid = Int(fields[1]),
              pid > 1
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
        let providerClassification = AgentIntegrationForegroundClassifier.classify(
            executables: processNames
        )
        if !providerClassification.providerIDs.isEmpty { return .agent }
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
        let cursorRow: Int?
        let cursorColumn: Int?
        let cursorVisible: Bool?
        let screenEvidence: TerminalScreenEvidence?
        init(text: String, currentInputLine: String?, cursorRow: Int? = nil, cursorColumn: Int? = nil, cursorVisible: Bool? = nil, screenEvidence: TerminalScreenEvidence? = nil) {
            self.text = text
            self.currentInputLine = currentInputLine
            self.cursorRow = cursorRow
            self.cursorColumn = cursorColumn
            self.cursorVisible = cursorVisible
            self.screenEvidence = screenEvidence
        }
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
    /// replies. Keep cursor/capture/cursor checks as three queued commands;
    /// combining them gives one Tessera completion two tmux replies and loses
    /// the capture body on a real `-CC` channel.
    static func capturePane(
        paneID: PaneId,
        control: @MainActor (String) async -> Result<[String], TmuxController.CommandError>
    ) async -> PaneCapture? {
        let cursorCommand = "display-message -p -t \(paneID.description) '#{cursor_y}:#{cursor_x}:#{cursor_flag}'"
        guard case .success(let cursorLines) = await control(cursorCommand),
              let cursorText = cursorLines.first(where: { !$0.isEmpty }),
              let cursorRow = cursorText.split(separator: ":").first.flatMap({ Int($0) }),
              cursorText.split(separator: ":").count == 3,
              let cursorColumn = Int(cursorText.split(separator: ":")[1]),
              cursorRow >= 0, cursorColumn >= 0
        else { return nil }
        let captureCommand = "capture-pane -p -e -N -t \(paneID.description)"
        guard case .success(let capturedLines) = await control(captureCommand) else {
            return nil
        }
        guard case .success(let finalCursorLines) = await control(cursorCommand),
              finalCursorLines.first == cursorText
        else { return nil }
        let currentLine = capturedLines.indices.contains(cursorRow)
            ? AgentTerminalText.normalized(capturedLines[cursorRow])
            : nil
        return PaneCapture(
            text: capturedLines.joined(separator: "\n"),
            currentInputLine: currentLine,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn,
            cursorVisible: cursorText.split(separator: ":").last.flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }
        )
    }

    private static func visiblePaneCapture(_ box: TerminalBox) -> PaneCapture? {
        let snapshot = visibleTerminalSnapshot(box)
        guard let text = snapshot.text else { return nil }
        return PaneCapture(text: text, currentInputLine: snapshot.currentInputLine, cursorRow: snapshot.cursorRow, cursorColumn: snapshot.cursorColumn, cursorVisible: snapshot.cursorVisible, screenEvidence: snapshot.screenEvidence)
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
        case .timedOut: return "timed-out"
        case .refusedByAuthority: return "controlled-elsewhere"
        }
    }

    private typealias LiveTerminalSnapshot = (text: String?, currentInputLine: String?, cursorRow: Int?, cursorColumn: Int?, cursorVisible: Bool?, screenEvidence: TerminalScreenEvidence?)
    private static let unavailableTerminalSnapshot: LiveTerminalSnapshot = (nil, nil, nil, nil, nil, nil)

    private static func readyTerminalSnapshot(_ box: TerminalBox) async -> (snapshot: LiveTerminalSnapshot, waited: Bool) {
        guard let initial = box.view?.getTerminal() else { return (unavailableTerminalSnapshot, false) }
        var waited = false
        // Wait only for an in-progress synchronized frame. The caller re-proves
        // its process and recaptures synchronously after any suspension here.
        for _ in 0..<20 {
            guard !Task.isCancelled, box.view?.getTerminal() === initial else { return (unavailableTerminalSnapshot, waited) }
            switch initial.liveScreenSnapshot() {
            case .failure(.incompleteFrame):
                waited = true
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { return (unavailableTerminalSnapshot, waited) }
            case .success(let live):
                guard let capture = terminalCapture(live) else { return (unavailableTerminalSnapshot, waited) }
                return ((capture.text, capture.currentInputLine, capture.cursorRow, capture.cursorColumn, capture.cursorVisible, capture.screenEvidence), waited)
            case .failure: return (unavailableTerminalSnapshot, waited)
            }
        }
        guard !Task.isCancelled, box.view?.getTerminal() === initial else { return (unavailableTerminalSnapshot, waited) }
        return (visibleTerminalSnapshot(box), waited)
    }

    private static func visibleTerminalSnapshot(_ box: TerminalBox) -> LiveTerminalSnapshot {
        guard let terminal = box.view?.getTerminal(), let capture = terminalCapture(terminal)
        else { return unavailableTerminalSnapshot }
        return (capture.text, capture.currentInputLine, capture.cursorRow, capture.cursorColumn, capture.cursorVisible, capture.screenEvidence)
    }

    /// SwiftTerm copies only the live grid on this terminal's MainActor owner.
    /// Typed immutable cells preserve physical positions and DIM without an
    /// ANSI round trip. Incomplete synchronized frames fail closed for retry.
    static func terminalCapture(_ terminal: Terminal) -> PaneCapture? {
        guard case .success(let live) = terminal.liveScreenSnapshot() else { return nil }
        return terminalCapture(live)
    }

    private static func terminalCapture(_ live: Terminal.LiveScreenSnapshot) -> PaneCapture? {
        var rows: [[TerminalScreenEvidence.Cell]] = []
        rows.reserveCapacity(live.rows)
        for row in 0..<live.rows {
            rows.append(live.cells[(row * live.columns)..<((row + 1) * live.columns)].map {
                .init(text: $0.text, width: $0.width, style: $0.attribute.style.rawValue)
            })
        }
        let screen = TerminalScreenEvidence(columns: live.columns, cells: rows,
            wrappedRows: live.wrappedRows, cursorRow: live.cursorRow,
            cursorColumn: live.cursorColumn, cursorVisible: live.cursorVisible,
            isAlternate: live.isAlternate)
        guard let text = screen.plainText else { return nil }
        let lines = text.components(separatedBy: "\n")
        let current = AgentTerminalText.normalized(lines[live.cursorRow])
        return PaneCapture(text: text, currentInputLine: current, cursorRow: live.cursorRow,
            cursorColumn: live.cursorColumn, cursorVisible: live.cursorVisible, screenEvidence: screen)
    }
}
