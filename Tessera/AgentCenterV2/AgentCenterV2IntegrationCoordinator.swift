import Foundation
import TesseraCore

/// Session-scoped lifecycle-integration orchestration for the Apple Agent
/// Center surface. All remote operations remain on the already-owned carrier
/// supplied by `AgentSessionSource`; this code never opens a connection.
@MainActor
extension AgentCenterV2Coordinator {
    /// Session chrome reads only the state for its own generation-bound live
    /// route. Agent Center presentation deliberately does not aggregate or
    /// display host integration warnings.
    func integrationState(sessionID: UUID) -> AgentIntegrationWarningState? {
        guard sessionRoutes[sessionID] != nil else { return nil }
        return integrationStates[sessionID]
    }

    func scheduleIntegrationRefresh(
        sessionID: UUID,
        forceHostProbe: Bool = false,
        manual: Bool = false
    ) {
        guard isEnabled,
              let route = sessionRoutes[sessionID],
              route.source.probeLifecycleIntegration != nil,
              route.source.inspectCurrentIntegration != nil
        else {
            clearIntegrationState(sessionID: sessionID)
            publishIntegrationNotice()
            return
        }

        guard manual || applicationActive else { return }
        let canAutomaticallyProbe = route.source.automaticallyProbeLifecycleIntegration
            || route.source.probeLifecycleIntegrationOnCurrentCarrier != nil
        if !manual && !canAutomaticallyProbe
            && cachedIntegrationInstallation(for: route.source.lifecycleIntegrationCacheKey) == nil {
            setIntegrationState(.manualCheckRequired, sessionID: sessionID)
            return
        }
        if !manual && !route.source.automaticallyInspectCurrentIntegration() {
            if !route.source.automaticallyProbeLifecycleIntegration && integrationStates[sessionID] == nil {
                setIntegrationState(.manualCheckRequired, sessionID: sessionID)
            } else if integrationStates[sessionID]?.kind != .manualCheckRequired {
                setIntegrationState(.unavailable(), sessionID: sessionID)
            }
            schedulePeriodicIntegrationRefresh(sessionID: sessionID)
            return
        }

        // Output and lifecycle observations coalesce behind an in-flight check;
        // cancelling it repeatedly can starve detection on a busy terminal.
        if !manual, integrationTasks[sessionID] != nil {
            pendingIntegrationActivityRegistrations[sessionID] = route.source.registrationID
            return
        }
        integrationRetryTasks.removeValue(forKey: sessionID)?.cancel()
        integrationTasks.removeValue(forKey: sessionID)?.cancel()
        integrationRefreshNotBefore[sessionID] = Date().addingTimeInterval(Double(AgentIntegrationCheckPolicy.activityThrottleMilliseconds) / 1_000)
        let generation = (integrationGenerations[sessionID] ?? 0) &+ 1
        integrationGenerations[sessionID] = generation
        // Background observation must not blink the warning off on every
        // output-triggered recheck. Keep the last result until a new result
        // arrives; mutations still revalidate the current terminal below.
        if manual || integrationStates[sessionID] == nil {
            setIntegrationState(manual ? .checkingOnDemand : .checking, sessionID: sessionID)
        }
        integrationTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.integrationGenerations[sessionID] == generation {
                    self.integrationTasks.removeValue(forKey: sessionID)
                    self.schedulePeriodicIntegrationRefresh(sessionID: sessionID)
                    self.resumePendingIntegrationActivityRefresh(sessionID: sessionID)
                }
            }
            let started = Date()
            var stage = "hostProbe"
            defer { self.performanceDiagnostics.record("integrationCheck", since: started) }
            do {
                let source = route.source
                let installation: AgentLifecycleHostInstallation
                if !forceHostProbe, let cached = self.cachedIntegrationInstallation(for: source.lifecycleIntegrationCacheKey) {
                    installation = cached
                } else if let probe = source.probeLifecycleIntegration {
                    if !manual, let connectedProbe = source.probeLifecycleIntegrationOnCurrentCarrier {
                        guard let result = try await connectedProbe() else {
                            if self.integrationRequestIsCurrent(sessionID: sessionID, registrationID: source.registrationID, generation: generation) {
                                self.setIntegrationState(.manualCheckRequired, sessionID: sessionID)
                            }
                            return
                        }
                        installation = result
                    } else {
                        guard manual || source.automaticallyProbeLifecycleIntegration else {
                            self.setIntegrationState(.manualCheckRequired, sessionID: sessionID)
                            return
                        }
                        installation = try await probe()
                    }
                    guard self.integrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: source.registrationID,
                        generation: generation
                    ) else { return }
                    self.integrationInstallations[source.lifecycleIntegrationCacheKey] = installation
                    self.integrationInstallationDates[source.lifecycleIntegrationCacheKey] = Date()
                } else {
                    throw AgentCenterV2IntegrationError.unavailable
                }

                stage = "currentTarget"
                guard let inspect = source.inspectCurrentIntegration,
                      let target = await inspect().map({ self.provenByDiscovery($0, registrationID: source.registrationID) }),
                      self.integrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: source.registrationID,
                        generation: generation
                      )
                else {
                    DiagnosticLogStore.appendAgentCenter("v2-integration-check result=unavailable stage=\(stage) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000))")
                    throw AgentCenterV2IntegrationError.unavailable
                }
                self.integrationFailureCounts.removeValue(forKey: sessionID)
                self.setIntegrationState(
                    .resolved(installation: installation, target: target),
                    sessionID: sessionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.integrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: route.source.registrationID,
                    generation: generation
                ) else { return }
                DiagnosticLogStore.appendAgentCenter("v2-integration-check result=failed stage=\(stage) elapsedMs=\(Int(Date().timeIntervalSince(started) * 1_000)) failureType=\(String(describing: type(of: error)))")
                let failures = min(Int.max - 1, self.integrationFailureCounts[sessionID] ?? 0) + 1
                self.integrationFailureCounts[sessionID] = failures
                self.integrationRefreshNotBefore[sessionID] = Date().addingTimeInterval(Double(AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: failures)) / 1_000)
                self.setIntegrationState(.unavailable(), sessionID: sessionID)
            }
        }
    }

    func fixIntegration(sessionID: UUID, requestedAction: AgentIntegrationFixAction) {
        guard let route = sessionRoutes[sessionID],
              let state = integrationStates[sessionID],
              state.supports(requestedAction)
        else { return }

        if requestedAction == .check || requestedAction == .retry {
            scheduleIntegrationRefresh(
                sessionID: sessionID,
                forceHostProbe: true,
                manual: true
            )
            return
        }

        integrationTasks.removeValue(forKey: sessionID)?.cancel()
        let generation = (integrationGenerations[sessionID] ?? 0) &+ 1
        integrationGenerations[sessionID] = generation
        setIntegrationState(.repairing, sessionID: sessionID)
        integrationTasks[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.integrationGenerations[sessionID] == generation {
                    self.integrationTasks.removeValue(forKey: sessionID)
                    self.schedulePeriodicIntegrationRefresh(sessionID: sessionID)
                    self.resumePendingIntegrationActivityRefresh(sessionID: sessionID)
                }
            }
            let source = route.source
            do {
                guard let probe = source.probeLifecycleIntegration,
                      let inspect = source.inspectCurrentIntegration,
                      let initialTarget = await inspect().map({ self.provenByDiscovery($0, registrationID: source.registrationID) }),
                      self.integrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: source.registrationID,
                        generation: generation
                      )
                else { throw AgentCenterV2IntegrationError.unavailable }

                let initialInstallation = try await probe()
                guard self.integrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: source.registrationID,
                    generation: generation
                ) else { return }
                let freshState = AgentIntegrationWarningState.resolved(
                    installation: initialInstallation,
                    target: initialTarget
                )
                guard let action = freshState.effectiveAction(for: requestedAction) else {
                    self.setIntegrationState(freshState, sessionID: sessionID)
                    return
                }

                // A newer app can install between this probe and the install.
                // Its integration stands; the host probe below reports it as
                // current or as requiring an app update.
                var refusedByNewerInstallation = false
                if action == .installAndApply || action == .installOnly {
                    guard let install = source.installLifecycleIntegration else {
                        throw AgentCenterV2IntegrationError.unavailable
                    }
                    do {
                        try await install()
                    } catch AgentLifecycleIntegrationInstallError.newerInstalled {
                        refusedByNewerInstallation = true
                    }
                    guard self.integrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: source.registrationID,
                        generation: generation
                    ) else { return }
                }

                if !refusedByNewerInstallation,
                   action == .installAndApply || action == .apply || action == .persistAndApply {
                    guard let currentTarget = await inspect(),
                          currentTarget.foreground == .shell,
                          currentTarget.location == initialTarget.location,
                          self.integrationRequestIsCurrent(
                            sessionID: sessionID,
                            registrationID: source.registrationID,
                            generation: generation
                          )
                    else { throw AgentCenterV2IntegrationError.unavailable }
                    let applied: Bool
                    if action == .persistAndApply {
                        guard let persist = source.persistLifecycleIntegrationInCurrentShell else {
                            throw AgentCenterV2IntegrationError.unavailable
                        }
                        applied = await persist(currentTarget)
                    } else {
                        guard let apply = source.applyLifecycleIntegrationToCurrentShell else {
                            throw AgentCenterV2IntegrationError.unavailable
                        }
                        applied = await apply(currentTarget)
                    }
                    guard applied,
                          self.integrationRequestIsCurrent(
                            sessionID: sessionID,
                            registrationID: source.registrationID,
                            generation: generation
                          )
                    else { throw AgentCenterV2IntegrationError.unavailable }
                }

                let installation = try await probe()
                guard self.integrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: source.registrationID,
                    generation: generation
                ) else { return }
                self.integrationInstallations[source.lifecycleIntegrationCacheKey] = installation
                self.integrationInstallationDates[source.lifecycleIntegrationCacheKey] = Date()
                self.integrationFailureCounts.removeValue(forKey: sessionID)
                guard let finalTarget = await inspect(),
                      self.integrationRequestIsCurrent(
                        sessionID: sessionID,
                        registrationID: source.registrationID,
                        generation: generation
                      )
                else { throw AgentCenterV2IntegrationError.unavailable }
                self.setIntegrationState(
                    .resolved(installation: installation, target: finalTarget),
                    sessionID: sessionID
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.integrationRequestIsCurrent(
                    sessionID: sessionID,
                    registrationID: source.registrationID,
                    generation: generation
                ) else { return }
                self.setIntegrationState(
                    .unavailable("The terminal changed before integration could be verified."),
                    sessionID: sessionID
                )
            }
        }
    }

    func retireIntegration(sessionID: UUID, registrationID: UUID) {
        guard sessionRoutes[sessionID]?.source.registrationID == registrationID else { return }
        integrationGenerations[sessionID] = (integrationGenerations[sessionID] ?? 0) &+ 1
        integrationTasks.removeValue(forKey: sessionID)?.cancel()
        integrationActivityTasks.removeValue(forKey: sessionID)?.cancel()
        integrationRetryTasks.removeValue(forKey: sessionID)?.cancel()
        integrationActivityDeadlines.removeValue(forKey: sessionID)
        integrationRefreshNotBefore.removeValue(forKey: sessionID)
        integrationFailureCounts.removeValue(forKey: sessionID)
        pendingIntegrationActivityRegistrations.removeValue(forKey: sessionID)
        clearIntegrationState(sessionID: sessionID)
        publishIntegrationNotice()
    }

    func publishIntegrationNotice(
        preferredSessionID: UUID? = nil,
        allowFallback: Bool = true
    ) {
        let selectedSessionID = preferredSessionID
            ?? presentation.selectedThread.flatMap { $0.binding?.liveSessionID }
        if let selectedSessionID,
           sessionRoutes[selectedSessionID] != nil,
           let state = integrationStates[selectedSessionID] {
            presentation.integrationNotice = .init(
                sessionID: selectedSessionID,
                state: state
            )
            return
        }
        guard allowFallback else {
            presentation.integrationNotice = nil
            return
        }
        if let prior = presentation.integrationNotice?.sessionID,
           sessionRoutes[prior] != nil,
           let state = integrationStates[prior] {
            presentation.integrationNotice = .init(sessionID: prior, state: state)
            return
        }
        if let entry = integrationStates.first(where: { sessionRoutes[$0.key] != nil }) {
            presentation.integrationNotice = .init(sessionID: entry.key, state: entry.value)
        } else {
            presentation.integrationNotice = nil
        }
    }

    func scheduleIntegrationActivityRefresh(
        sessionID: UUID,
        delay: Duration = .milliseconds(500)
    ) {
        guard isEnabled, applicationActive,
              let source = sessionRoutes[sessionID]?.source,
              integrationStates[sessionID] != nil,
              source.automaticallyInspectCurrentIntegration()
        else { return }
        let registrationID = source.registrationID
        if integrationTasks[sessionID] != nil {
            pendingIntegrationActivityRegistrations[sessionID] = registrationID
            return
        }
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let deadline = max(Date().addingTimeInterval(seconds), integrationRefreshNotBefore[sessionID] ?? .distantPast)
        // Keep the earliest request. A trailing-edge debounce never fires while
        // an agent streams output continuously.
        if let scheduled = integrationActivityDeadlines[sessionID], scheduled <= deadline { return }
        integrationActivityTasks.removeValue(forKey: sessionID)?.cancel()
        integrationActivityDeadlines[sessionID] = deadline
        integrationActivityTasks[sessionID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard let self, self.isEnabled, self.applicationActive,
                  self.sessionRoutes[sessionID]?.source.registrationID == registrationID
            else { return }
            self.integrationActivityTasks.removeValue(forKey: sessionID)
            self.integrationActivityDeadlines.removeValue(forKey: sessionID)
            if self.integrationTasks[sessionID] != nil {
                self.pendingIntegrationActivityRegistrations[sessionID] = registrationID
                return
            }
            self.scheduleIntegrationRefresh(sessionID: sessionID)
        }
    }

    /// The check reads the pane's tmux lifecycle option, and agents an agent
    /// runs in the background (Codex started by Claude) inherit the pane and
    /// overwrite that option with PIDs outside its foreground. An agent that
    /// discovery proved from its own frame, still in the pane's foreground,
    /// keeps its lifecycle confirmed; otherwise the bar warned after every
    /// background hook and cleared at the agent's next one.
    func provenByDiscovery(
        _ target: AgentCurrentIntegrationTarget,
        registrationID: UUID
    ) -> AgentCurrentIntegrationTarget {
        guard !target.agentIntegrationActive, target.foreground == .agent,
              threadRoutes.values.contains(where: { route in
                  route.registrationID == registrationID
                      && route.location.sessionID == target.location.sessionID
                      && route.location.paneID == target.location.paneID
                      && (route.binding.agentPID.map(target.processIDs.contains) ?? false)
              })
        else { return target }
        return AgentCurrentIntegrationTarget(
            location: target.location,
            foreground: target.foreground,
            processIDs: target.processIDs,
            shellIntegrationActive: target.shellIntegrationActive,
            agentIntegrationActive: true,
            agentRequiresLifecycleHook: target.agentRequiresLifecycleHook
        )
    }

    /// Quiet shells and a recovered side channel need a retry without waiting
    /// for terminal output. These checks use only the already-owned carrier.
    private func schedulePeriodicIntegrationRefresh(sessionID: UUID) {
        guard isEnabled, applicationActive,
              let source = sessionRoutes[sessionID]?.source,
              source.automaticallyProbeLifecycleIntegration || source.probeLifecycleIntegrationOnCurrentCarrier != nil
        else { return }
        let registrationID = source.registrationID
        let failures = integrationFailureCounts[sessionID] ?? 0
        let delay = Double(AgentIntegrationCheckPolicy.nextCheckDelayMilliseconds(consecutiveFailures: failures)) / 1_000
        integrationRetryTasks.removeValue(forKey: sessionID)?.cancel()
        integrationRetryTasks[sessionID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isEnabled, self.applicationActive,
                  self.sessionRoutes[sessionID]?.source.registrationID == registrationID
            else { return }
            self.integrationRetryTasks.removeValue(forKey: sessionID)
            self.scheduleIntegrationRefresh(sessionID: sessionID)
        }
    }

    func pauseIntegrationChecks() {
        integrationGenerations = integrationGenerations.mapValues { $0 &+ 1 }
        integrationTasks.values.forEach { $0.cancel() }
        integrationActivityTasks.values.forEach { $0.cancel() }
        integrationRetryTasks.values.forEach { $0.cancel() }
        integrationTasks.removeAll()
        integrationActivityTasks.removeAll()
        integrationRetryTasks.removeAll()
        integrationActivityDeadlines.removeAll()
        integrationRefreshNotBefore.removeAll()
        pendingIntegrationActivityRegistrations.removeAll()
    }

    private func resumePendingIntegrationActivityRefresh(sessionID: UUID) {
        guard let registrationID = pendingIntegrationActivityRegistrations.removeValue(forKey: sessionID),
              isEnabled, applicationActive,
              sessionRoutes[sessionID]?.source.registrationID == registrationID
        else { return }
        scheduleIntegrationActivityRefresh(sessionID: sessionID)
    }

    private func cachedIntegrationInstallation(for key: String) -> AgentLifecycleHostInstallation? {
        guard let installation = integrationInstallations[key], let checkedAt = integrationInstallationDates[key] else { return nil }
        let kind: AgentIntegrationInstallationKind
        switch installation {
        case .current: kind = .current
        case .missing: kind = .missing
        case .outdated: kind = .outdated
        case .requiresAppUpdate: kind = .requiresAppUpdate
        }
        let age = Date().timeIntervalSince(checkedAt)
        let freshness = Double(AgentIntegrationCheckPolicy.installationFreshnessMilliseconds(kind)) / 1_000
        return age >= 0 && age < freshness ? installation : nil
    }

    private func setIntegrationState(
        _ state: AgentIntegrationWarningState,
        sessionID: UUID
    ) {
        if integrationStates[sessionID] != state {
            integrationStates[sessionID] = state
        }
        publishIntegrationNotice(preferredSessionID: sessionID)
    }

    private func clearIntegrationState(sessionID: UUID) {
        if integrationStates[sessionID] != nil {
            integrationStates.removeValue(forKey: sessionID)
        }
    }

    private func integrationRequestIsCurrent(
        sessionID: UUID,
        registrationID: UUID,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && isEnabled
            && integrationGenerations[sessionID] == generation
            && sessionRoutes[sessionID]?.source.registrationID == registrationID
    }
}

private enum AgentCenterV2IntegrationError: Error {
    case unavailable
}
