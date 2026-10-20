import Foundation
import TesseraCore

enum AgentCenterV2TaskOwnership {
    static func owns(currentTaskID: UUID?, taskID: UUID) -> Bool {
        currentTaskID == taskID
    }
}

enum AppleAgentPromptCapture {
    /// A tmux capture keeps its SGR (`capture-pane -e`); the grammar reads the
    /// cells, so escapes go before the rows are bounded.
    static func bottomWholeRows(_ text: String, limit: Int = 16_384) -> String {
        AgentPromptGrammar.promptText(fromCapture: text, limit: limit)
    }

    static func utf8Prefix(_ text: String, limit: Int) -> String {
        var bytes = 0
        return String(text.prefix { character in
            let next = character.utf8.count
            guard bytes + next <= limit else { return false }
            bytes += next
            return true
        })
    }
}

enum AgentCenterV2ReadPolicy {
    static func allows(isEnabled: Bool, applicationActive: Bool, hasSurfaceDemand: Bool) -> Bool {
        isEnabled && applicationActive && hasSurfaceDemand
    }
}

/// How often a session's terminal output may be turned into a full remote
/// all-pane inspection.
///
/// Discovery deliberately keeps running with no surface open: that is how a
/// background agent's waiting/finished transition is noticed at all, and it is
/// the whole reason the mosh side channel is held for a connected tmux session.
/// What must not keep running at surface rates is the *cost* — a discovery pass
/// is four remote commands and, on the reporter's device, 813 ms.
///
/// V1 said this with a `minimumInterval` of 2 s while a central surface was
/// visible and 60 s while it was not (`AgentCenter.noteOutput`, `b0da44df^`).
/// The V2 rewrite kept the unconditional discovery and dropped the rate half,
/// flattening both to one second — so a closed surface paid sixty times V1's
/// bill, and the `surfaceDemand=` it logged next to every pass decided nothing.
///
/// Hook-driven passes are not rate-limited here at all. A lifecycle event is a
/// prompt or a completion, it is already proof of what happened, and nothing
/// waits behind a quiet terminal's cooldown for it.
enum AgentCenterV2DiscoveryPolicy {
    /// Surface open: fast enough that a visible list is not stale.
    static let attendedInterval: TimeInterval = 2
    /// Surface closed: slow enough that a busy TUI is not a poller, frequent
    /// enough that a background transition is still noticed.
    static let unattendedInterval: TimeInterval = 60

    /// How long a fresh process read's verdict that a lifecycle PID runs
    /// outside its pane keeps that PID's hooks from starting passes while a
    /// proven agent holds the pane. On tmux a generic pass still reads the
    /// pane's retained frame meanwhile; raw SSH and mosh have none, so a
    /// frame dropped there is gone.
    static let foreignLifecycleInterval: TimeInterval = 30
    /// A repeated frame starts another pass only this long after the last:
    /// often enough to notice a prompt drawn after its hook, rarely enough
    /// that a title spinner is not a poller.
    static let lifecycleRepeatInterval: TimeInterval = 5
    static let livenessInterval: TimeInterval = 5

    static func genericDiscoveryInterval(hasSurfaceDemand: Bool) -> TimeInterval {
        hasSurfaceDemand ? attendedInterval : unattendedInterval
    }
}

enum AgentCenterV2CandidateActionPolicy {
    static func canAnswer(_ binding: AgentTerminalBinding) -> Bool {
        binding.capabilities.contains(.promptAnswer) && binding.agentPID != nil
    }
}

/// The exact discovery slice an authoritative source just returned. A pane
/// refresh may only retire entries in that pane; a full refresh owns every
/// live location for its session. Keeping this pure makes the absence fence
/// deterministic and prevents one tmux pane from evicting another.
struct AgentCenterV2DiscoveryScope: Equatable {
    let sessionID: UUID
    let paneID: Int?

    func contains(_ location: AgentLocation) -> Bool {
        guard location.sessionID == sessionID else { return false }
        guard let paneID else { return true }
        return location.paneID == paneID
    }

    func absentRouteIDs<ID: Hashable>(
        locations: [ID: AgentLocation],
        seenIDs: Set<ID>
    ) -> Set<ID> {
        Set(locations.compactMap { id, location in
            contains(location) && !seenIDs.contains(id) ? id : nil
        })
    }
}

@MainActor
struct AppleAgentSessionRoute {
    let hostID: UUID
    let hostDisplayLabel: String
    let source: AgentSessionSource
    let profiles: @MainActor () -> [SwipePadProfile]
    let carrierGeneration: UInt64
}

@MainActor
struct AppleAgentThreadRoute {
    let registrationID: UUID
    let location: AgentLocation
    let profile: SwipePadProfile
    let binding: AgentTerminalBinding
    let sourceIdentity: String
    var lifecycleEvent: AgentLifecycleEvent? = nil
    /// Recovered from a retired connection's holder: a fresh read proved the
    /// process, not that it still runs this conversation (`/clear` or
    /// `/resume` while suspended). Observe-only until the agent's own frame.
    var restoredFromRetiredConnection = false
}

/// A proven pane holder a retired connection left behind: identity
/// evidence only, never a binding or carrier. A replacement must find the PID
/// in the pane's foreground with its own fresh read before it uses the event.
struct AppleAgentRetiredPaneHolder {
    struct Key: Hashable {
        let hostID: UUID
        let paneID: Int
        let provider: String
        let providerSessionID: String
    }

    static let limit = 64
    let lifecycleEvent: AgentLifecycleEvent
    let agentPID: Int
    let retiredAt: Date
}

@MainActor
struct AppleAgentProjectionRoute {
    let transcriptRef: String
    let providerID: AgentProviderID
    let binding: AgentTerminalBinding
    let source: AgentSessionSource

    func matchesInventorySource(transcriptRef: String, binding: AgentTerminalBinding, registrationID: UUID) -> Bool {
        self.transcriptRef == transcriptRef && self.binding == binding && source.registrationID == registrationID
    }
}

@MainActor
extension AgentCenterV2Coordinator {
    private func uniqueIngestionHosts(sessionID: UUID? = nil) -> [AppleAgentIngestionHost] {
        var seen = Set<ObjectIdentifier>()
        return ingestionHosts.compactMap { key, host in
            guard (sessionID == nil || key.sessionID == sessionID), seen.insert(ObjectIdentifier(host)).inserted else { return nil }
            return host
        }
    }

    private func isNativeHostCurrent(_ host: AppleAgentIngestionHost, sessionID: UUID) -> Bool {
        ingestionHosts.contains { $0.key.sessionID == sessionID && $0.value === host }
    }

    private func discardNativeHost(_ host: AppleAgentIngestionHost) {
        for thread in host.threads.keys { cancelInitialPrefetch(thread) }
        ingestionHosts = ingestionHosts.filter { $0.value !== host }
        host.close()
        let retained = Set(uniqueIngestionHosts().filter { $0.connection?.isClosed == false }.flatMap { $0.threads.keys })
        let retired = Set(host.threads.keys).subtracting(retained)
        presentation.ingestionReadStatuses = presentation.ingestionReadStatuses.filter {
            !retired.contains($0.key) || $0.value.survivesReaderClosure
        }
    }

    private func releaseNativeBorrow(_ host: AppleAgentIngestionHost, waiter: UUID, sessionID: UUID) {
        guard host.openingWaiters.remove(waiter) != nil else { return }
        if host.openingWaiters.isEmpty, host.connection == nil,
           isNativeHostCurrent(host, sessionID: sessionID) { discardNativeHost(host) }
    }

    func claimNativeThread(_ thread: AgentThreadID, host: AppleAgentIngestionHost) throws {
        try validateNativeThreadClaim(thread, host: host)
        host.claimedThreads.insert(thread)
    }

    private func validateNativeThreadClaim(_ thread: AgentThreadID, host: AppleAgentIngestionHost) throws {
        guard !uniqueIngestionHosts().contains(where: {
            $0 !== host && $0.claimedThreads.contains(thread) && $0.connection?.isClosed == false &&
            $0.connection?.epoch != host.connection?.epoch
        }) else { throw AgentIngestionError.remote("contextIdentityConflict") }
    }

    private func closeIngestionHosts(sessionID: UUID) {
        for (thread, route) in projectionRoutes.merging(historicalRoutes, uniquingKeysWith: { current, _ in current })
            where route.source.sessionID == sessionID {
            cancelInitialPrefetch(thread)
            ingestionReadRetryTasks.removeValue(forKey: thread)?.task.cancel()
        }
        for host in uniqueIngestionHosts(sessionID: sessionID) { discardNativeHost(host) }
    }

    func closeIngestionHosts() {
        let hosts = uniqueIngestionHosts()
        ingestionHosts.removeAll()
        for host in hosts { host.close() }
        // Closed readers cannot finish their displayed preparation. Keep
        // terminal failures and their recovery instructions across resume.
        presentation.ingestionReadStatuses = presentation.ingestionReadStatuses.filter { $0.value.survivesReaderClosure }
    }

    /// Old process incarnations are no longer addressable once their routes
    /// retire. Reclaim only those aliases under pressure; a live/historical
    /// route or pending borrower must keep its authenticated provider scope.
    private func reclaimUnusedNativeContexts(sessionID: UUID, keeping requested: AppleAgentIngestionHostKey) {
        let keys = Set(ingestionHosts.keys).union(ingestionScopes.keys).filter { $0.sessionID == sessionID }
        guard keys.count >= 128 || uniqueIngestionHosts(sessionID: sessionID).count >= 8 else { return }
        let bindings = threadRoutes.values.map(\.binding) + projectionRoutes.values.map(\.binding)
            + historicalRoutes.values.map(\.binding)
        var retained = Set(bindings.filter { $0.liveSessionID == sessionID }.map {
            AppleAgentIngestionHostKey(sessionID: sessionID, binding: $0)
        })
        retained.insert(requested)
        // The default scope is the session's inventory carrier and is useful
        // even while no process has a live thread binding.
        retained.insert(AppleAgentIngestionHostKey(sessionID: sessionID))
        for key in keys where !retained.contains(key) {
            if let host = ingestionHosts[key] {
                guard host.openingWaiters.isEmpty else { continue }
                ingestionHosts.removeValue(forKey: key)
                if !isNativeHostCurrent(host, sessionID: sessionID) { host.close() }
            }
            ingestionScopes.removeValue(forKey: key)
        }
    }

    func nativeHost(source: AgentSessionSource, context: AgentTerminalBinding? = nil) async throws -> (AppleAgentIngestionHost, AppleAgentIngestionConnection) {
        guard let carrier = source.readCarrier?() else { throw AgentActionError.unavailable }
        let key = AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: context)
        sessionReadCarriers[source.sessionID] = carrier
        for stale in uniqueIngestionHosts().filter({ $0.connection?.isClosed == true || $0.opening.isCancelled }) {
            discardNativeHost(stale)
        }
        if let existing = ingestionHosts[key],
           existing.binding != carrier || existing.registrationID != source.registrationID {
            discardNativeHost(existing)
        }
        if ingestionHosts[key] == nil {
            reclaimUnusedNativeContexts(sessionID: source.sessionID, keeping: key)
            guard Set(ingestionHosts.keys).union(ingestionScopes.keys).contains(key) ||
                  Set(ingestionHosts.keys).union(ingestionScopes.keys).filter({ $0.sessionID == source.sessionID }).count < 128 else { throw AgentIngestionError.capacityExceeded }
            guard ingestionHosts.keys.filter({ $0.sessionID == source.sessionID }).count < 128,
                  uniqueIngestionHosts(sessionID: source.sessionID).count < 8 else { throw AgentIngestionError.capacityExceeded }
            let current: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { [weak self] candidate in
                self?.isSessionReadCarrierCurrent(candidate, registrationID: source.registrationID) == true
            }
            guard current(carrier), case .available(let factory) = source.projectorExecAvailability(carrier, current) else {
                throw AgentActionError.unavailable
            }
            ingestionHosts[key] = AppleAgentIngestionHost(binding: carrier, registrationID: source.registrationID, factory: factory,
                contextPID: context?.agentPID, contextScope: ingestionScopes[key])
        }
        guard var host = ingestionHosts[key] else { throw AgentActionError.unavailable }
        let borrowed = host
        let waiter = UUID()
        borrowed.openingWaiters.insert(waiter)
        defer { releaseNativeBorrow(borrowed, waiter: waiter, sessionID: source.sessionID) }
        do {
            var connection = try await withTaskCancellationHandler {
                try await borrowed.opening.value
            } onCancel: { [weak self, weak borrowed] in
                Task { @MainActor in
                    guard let self, let borrowed else { return }
                    self.releaseNativeBorrow(borrowed, waiter: waiter, sessionID: source.sessionID)
                }
            }
            try Task.checkCancellation()
            // Another waiter may already have merged this alias while we were
            // awaiting the same opening. Borrow its winner, not the closed relay.
            if let winner = ingestionHosts[key], winner !== host,
               winner.binding == carrier, winner.registrationID == source.registrationID,
               let shared = winner.connection, shared.epoch == connection.epoch {
                host = winner; connection = shared
            }
            guard ingestionHosts[key] === host, !connection.isClosed,
                  isSessionReadCarrierCurrent(carrier, registrationID: source.registrationID) else { throw AgentActionError.staleBinding }
            // Different panes can have identical effective provider roots.
            // Deduplicate only after the authenticated host chose its scope;
            // process IDs and app-local UUIDs never define remote cardinality.
            if host.connection == nil, let shared = uniqueIngestionHosts(sessionID: source.sessionID).first(where: {
                $0 !== host && $0.binding == carrier && $0.registrationID == source.registrationID &&
                $0.connection?.isClosed == false && $0.connection?.epoch == connection.epoch
            }), let sharedConnection = shared.connection {
                let redundant = host
                ingestionHosts[key] = shared; host = shared; connection = sharedConnection
                redundant.close()
            }
            host.connection = connection
            if context?.agentPID != nil, let scope = connection.contextScope { ingestionScopes[key] = scope }
            connection.onPage = { [weak self, weak host] handle, page in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key,
                      host.bootstrapped.contains(thread) else { return false }
                return await self.apply(page: page, to: thread).accepted
            }
            connection.onWindowPage = { [weak self, weak host] handle, page in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key,
                      host.bootstrapped.contains(thread) else { return nil }
                let result = await self.apply(page: page, to: thread)
                guard result.accepted || result == .capacityExceeded,
                      let snapshot = await self.runtime.ingestionWindowSnapshot(for: thread) else { return nil }
                return .init(snapshot: snapshot, accepted: result.accepted)
            }
            connection.onResync = { [weak self, weak host] handle in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key else { return }
                self.cancelInitialPrefetch(thread)
                host.bootstrapped.remove(thread)
                host.initialPrefetchStarted.remove(thread)
                host.interests.removeValue(forKey: thread)
                self.refreshVisibleTranscript(thread)
                self.scheduleNativeInterests()
            }
            connection.onCapacity = { [weak self, weak host] handle in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key else { return }
                self.cancelInitialPrefetch(thread)
                host.pausedThreads.insert(thread); host.interests.removeValue(forKey: thread)
                host.interestRevision &+= 1
                self.presentation.ingestionCapacityThreads.insert(thread)
            }
            connection.onReadStatus = { [weak self, weak host, weak connection] handle, status in
                guard let self, let host, let connection,
                      self.isNativeHostCurrent(host, sessionID: source.sessionID), host.connection === connection,
                      !connection.isClosed,
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key else { return }
                self.handleNativeReadStatus(status, threadID: thread, host: host)
            }
            connection.onReadComplete = { [weak self, weak host, weak connection] handle in
                guard let self, let host, let connection,
                      self.isNativeHostCurrent(host, sessionID: source.sessionID), host.connection === connection,
                      !connection.isClosed,
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key,
                      self.presentation.ingestionReadStatuses[thread]?.isProgress == true else { return }
                // An unchanged read ended successfully, but only a committed
                // page resets read-failure backoff or releases a manual error.
                self.presentation.ingestionReadStatuses.removeValue(forKey: thread)
            }
            connection.onSummary = { [weak self, weak host] handle, summary in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key else { return false }
                // A card whose native title the host could not read (for
                // example a Codex state store it refused) shows a generated
                // title with no trace in the log; name the host's code once,
                // and once more when a previously reported issue clears.
                let previous = self.presentation.summaryMetadataIssues[thread]
                let current = summary.metadataIssue.map { issue in
                    Self.diagnosticToken(["issue", Self.diagnosticCode(issue)] + (summary.metadataReason.map { [Self.diagnosticCode($0)] } ?? []))
                }
                if previous != current {
                    self.presentation.summaryMetadataIssues[thread] = current
                    if let current {
                        DiagnosticLogStore.appendAgentCenter("v2-summary provider=\(thread.providerID.rawValue) metadata=\(current)")
                    } else if previous != nil {
                        DiagnosticLogStore.appendAgentCenter("v2-summary provider=\(thread.providerID.rawValue) metadata=ok")
                    }
                }
                let applied = await self.runtime.apply(summary: summary, to: thread)
                if applied { await self.synchronizePresentation() }
                return applied
            }
            connection.onHook = { [weak self, weak host] handle, hook in
                guard let self, let host, self.isNativeHostCurrent(host, sessionID: source.sessionID),
                      self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID),
                      let thread = host.threads.first(where: { $0.value == handle })?.key else { return }
                if await self.runtime.apply(hook: hook, to: thread) { await self.synchronizePresentation() }
            }
            if connection.supportsPiSessions {
                await markProviderConforming(.pi, sessionID: source.sessionID)
                guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID),
                      isSessionReadCarrierCurrent(carrier, registrationID: source.registrationID) else { throw AgentActionError.staleBinding }
            }
            if connection.supportsOpenCodeSessions {
                await markProviderConforming(.opencode, sessionID: source.sessionID)
                guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID),
                      isSessionReadCarrierCurrent(carrier, registrationID: source.registrationID) else { throw AgentActionError.staleBinding }
            }
            if connection.supportsKimiSessions {
                await markProviderConforming(.kimi, sessionID: source.sessionID)
                guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID),
                      isSessionReadCarrierCurrent(carrier, registrationID: source.registrationID) else { throw AgentActionError.staleBinding }
            }
            return (host, connection)
        } catch {
            // This task only borrows the shared opening. Cancelling a history
            // or selection waiter must not dispose sibling subscriptions.
            if !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID) {
                discardNativeHost(host)
            }
            throw error
        }
    }

    private func projectNative(transcriptRef: String, providerID: AgentProviderID, threadID: AgentThreadID,
                               binding: AgentTerminalBinding, source: AgentSessionSource, cursor: String?, direction: String = "before",
                               requiredConnection: AppleAgentIngestionConnection? = nil) async throws {
        let host: AppleAgentIngestionHost, connection: AppleAgentIngestionConnection
        if let requiredConnection {
            guard !requiredConnection.isClosed,
                  let current = uniqueIngestionHosts(sessionID: source.sessionID).first(where: { $0.connection === requiredConnection })
            else { throw AgentActionError.staleBinding }
            host = current; connection = requiredConnection
        } else { (host, connection) = try await nativeHost(source: source, context: binding) }
        try Task.checkCancellation()
        guard providerID != .pi || connection.supportsPiSessions else { throw AgentIngestionError.remote("unsupportedPiReader") }
        guard providerID != .opencode || connection.supportsOpenCodeSessions else { throw AgentIngestionError.remote("unsupportedOpenCodeReader") }
        guard providerID != .kimi || connection.supportsKimiSessions else { throw AgentIngestionError.remote("unsupportedKimiReader") }
        if host.threads[threadID] == nil {
            let nativeLocator = [.codex, .opencode].contains(providerID) && transcriptRef.hasPrefix("native:")
            let reply = try await connection.request(["kind": .string("resolve"), "provider": .string(providerID.rawValue),
                nativeLocator ? "nativeSessionID" : "transcriptRef": .string(nativeLocator ? String(transcriptRef.dropFirst(7)) : transcriptRef)],
                onReadStatus: { [weak self] status in
                    guard let self, self.isProjectionEndpointCurrent(binding, threadID: threadID,
                        registrationID: source.registrationID),
                        (self.initialProjectionRoutes[threadID] ?? self.projectionRoutes[threadID] ?? self.historicalRoutes[threadID])?
                            .matchesInventorySource(transcriptRef: transcriptRef, binding: binding, registrationID: source.registrationID) == true
                    else { return }
                    self.presentation.ingestionReadStatuses[threadID] = status
                })
            guard let handle = reply.object["thread"]?.stringValue,
                  reply.object["provider"]?.stringValue == providerID.rawValue,
                  reply.object["sessionID"]?.stringValue == threadID.providerSessionID else { throw AgentIngestionError.remote("contextIdentityConflict") }
            try claimNativeThread(threadID, host: host)
            try host.reserveHandles([(threadID, handle)])
            host.threads[threadID] = handle
        } else { try claimNativeThread(threadID, host: host) }
        guard let handle = host.threads[threadID] else { throw AgentIngestionError.malformedFrame }
        if requiredConnection == nil, direction == "bootstrap" || cursor != nil, presentation.ingestionCapacityThreads.contains(threadID) {
            presentation.ingestionCapacityThreads.remove(threadID)
        }
        if host.bootstrapped.contains(threadID), direction != "bootstrap", cursor == nil,
           await runtime.ingestionCheckpoint(for: threadID)?.epoch == connection.epoch {
            scheduleNativeInterests(); return
        }
        host.pausedThreads.insert(threadID)
        defer { host.pausedThreads.remove(threadID); scheduleNativeInterests() }
        await host.interestTask?.value
        try Task.checkCancellation()
        _ = try await connection.request(["kind": .string("unsubscribe"), "thread": .string(handle)])
        host.interests.removeValue(forKey: threadID)
        if await runtime.ingestionCheckpoint(for: threadID)?.epoch != connection.epoch {
            host.bootstrapped.remove(threadID)
        }
        let initial = !host.bootstrapped.contains(threadID) || direction == "bootstrap"
        if initial {
            host.initialPrefetchStarted.remove(threadID)
            // A bootstrap sizes the new window from this connection's hello.
            await runtime.setIngestionHostSegments(connection.maxWindowSegments, for: threadID.hostID, thread: threadID)
        }
        if initial || cursor != nil {
            let window = await runtime.ingestionWindowSnapshot(for: threadID)
            var fields: [String: AgentJSONValue] = ["kind": .string("window.read"), "operation": .string(initial ? "bootstrap" : direction),
                "thread": .string(handle), "windowVersion": .number(Decimal(initial ? 0 : window?.version ?? 0))]
            if !initial, let cursor { fields["cursor"] = .string(cursor) }
            var limit = 100
            while true {
            fields["limit"] = .number(Decimal(limit))
            let reply = try await connection.request(fields)
            guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID),
                  isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: source.registrationID),
                  let page = reply.page else { throw AgentActionError.staleBinding }
            let applied = await apply(page: page, to: threadID)
            if !applied.accepted {
                if let transaction = page.ingestion?.requestID { try? await connection.cancelWindow(transaction, thread: handle) }
                if applied == .capacityExceeded {
                    guard limit > 1 else { throw AgentIngestionError.capacityExceeded }
                    limit = max(1, limit / 2); continue
                }
                host.bootstrapped.remove(threadID); throw AgentIngestionError.remote("resyncRequired")
            }
            // A cancellation after Core accepted this page still finalizes its
            // ACK. Explicit navigation joins only this local cleanup, never the
            // remaining optional history requests.
            guard isNativeHostCurrent(host, sessionID: source.sessionID),
                  isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: source.registrationID),
                  let committed = await runtime.ingestionWindowSnapshot(for: threadID) else { throw AgentActionError.staleBinding }
            try await connection.acknowledgeWindow(page, thread: handle, snapshot: committed)
            guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: source.sessionID),
                  isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: source.registrationID) else { throw AgentActionError.staleBinding }
            host.bootstrapped.insert(threadID)
            projectionRoutes[threadID] = AppleAgentProjectionRoute(transcriptRef: transcriptRef, providerID: providerID,
                binding: binding, source: source)
            initialProjectionRoutes.removeValue(forKey: threadID)
            if initial, providerID == .codex {
                // Provider names are out-of-band metadata. The first page is
                // already committed, and metadata failure must not erase it.
                if host.metadataTasks[threadID] == nil {
                    let taskID = UUID()
                    let task = Task(priority: .utility) { [weak host, weak connection] in
                        defer {
                            if host?.metadataTasks[threadID]?.id == taskID { host?.metadataTasks.removeValue(forKey: threadID) }
                        }
                        _ = try? await connection?.request(["kind": .string("summary"), "thread": .string(handle)])
                    }
                    host.metadataTasks[threadID] = (taskID, task)
                }
            }
            break
            }
        }
        // A new selection demotes the previous thread on the same connection;
        // it neither starts another host service nor steals another app's lease.
        scheduleNativeInterests()
    }

    @discardableResult
    func cancelInitialPrefetch(_ threadID: AgentThreadID) -> Task<Void, Never>? {
        let task = initialPrefetchTasks[threadID]
        task?.cancel()
        // Keep it addressable until its defer releases the native read pause.
        // An explicit page request may join that cleanup; Send never joins it.
        return task
    }

    func cancelInitialPrefetches(except retained: AgentThreadID? = nil) {
        for thread in initialPrefetchTasks.keys where thread != retained { cancelInitialPrefetch(thread) }
    }

    func clearNativeReadFailure(_ threadID: AgentThreadID) {
        if presentation.ingestionReadStatuses[threadID] != nil { presentation.ingestionReadStatuses.removeValue(forKey: threadID) }
        ingestionReadRetryTasks.removeValue(forKey: threadID)?.task.cancel()
        ingestionReadFailureCounts.removeValue(forKey: threadID)
        ingestionRetryPageRequests.removeValue(forKey: threadID)
        ingestionManualReadThreads.remove(threadID)
    }

    func cancelNativeReadRetries() {
        ingestionReadRetryTasks.values.forEach { $0.task.cancel() }
        ingestionReadRetryTasks.removeAll()
        ingestionRetryPageRequests.removeAll()
    }

    func handleNativeReadStatus(_ status: AgentIngestionReadStatus, threadID: AgentThreadID, host: AppleAgentIngestionHost) {
        let changed = presentation.ingestionReadStatuses[threadID] != status
        if changed { presentation.ingestionReadStatuses[threadID] = status }
        guard !status.isProgress else { return }
        // The status code is the host's allowlisted classifier token, never
        // transcript content. Without it a failed read logs only "transport".
        // One slash-joined token (see diagnosticToken for the sanitizer
        // rule). Repeats of an unchanged status (a resync churn loop) add
        // nothing and stay out of the log.
        if changed {
            DiagnosticLogStore.appendAgentCenter(
                "v2-read-status provider=\(threadID.providerID.rawValue) status=\(Self.diagnosticToken([status.state.rawValue, status.domain.rawValue, status.recovery.rawValue, Self.diagnosticCode(status.code)]))"
            )
        }
        cancelInitialPrefetch(threadID)
        switch status.recovery {
        case .continue: break
        case .manual:
            ingestionManualReadThreads.insert(threadID)
            ingestionReadRetryTasks.removeValue(forKey: threadID)?.task.cancel()
            ingestionRetryPageRequests.removeValue(forKey: threadID)
            pendingProjectionRefreshes.remove(threadID)
            pendingHistoryRequests.remove(threadID)
            pendingFillRequests.remove(threadID)
            pendingLatestRequests.remove(threadID)
            cancelInitialPrefetch(threadID)
            scheduleNativeInterests()
        case .retryRead:
            scheduleNativeReadRetry(threadID)
        case .renewConnection:
            let affected = Array(host.threads.keys)
            discardNativeHost(host)
            restartNativeInventoryAfterConnectionLoss(sessionID: host.binding.liveSessionID)
            for thread in affected { scheduleNativeReadRetry(thread) }
        case .rebootstrap:
            // The connection's onResync callback owns rebootstrap ordering.
            ingestionManualReadThreads.remove(threadID)
            ingestionReadRetryTasks.removeValue(forKey: threadID)?.task.cancel()
            ingestionRetryPageRequests.removeValue(forKey: threadID)
            cancelInitialPrefetch(threadID)
        }
    }

    private func scheduleNativeReadRetry(_ threadID: AgentThreadID) {
        guard AgentCenterV2ReadPolicy.allows(isEnabled: isEnabled, applicationActive: applicationActive, hasSurfaceDemand: hasSurfaceDemand),
              presentation.selectedThreadID == threadID || ingestionOpenDetails.contains(threadID) || ingestionVisibleCards.contains(threadID),
              !ingestionManualReadThreads.contains(threadID), ingestionReadRetryTasks[threadID] == nil,
              let route = projectionRoutes[threadID] ?? historicalRoutes[threadID] else { return }
        let failures = min(ingestionReadFailureCounts[threadID, default: 0] + 1, 32)
        ingestionReadFailureCounts[threadID] = failures
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(AgentIngestionReadRetryPolicy.delayMilliseconds(consecutiveFailures: failures))) }
            catch { return }
            guard let self, self.ingestionReadRetryTasks[threadID]?.id == id else { return }
            self.ingestionReadRetryTasks.removeValue(forKey: threadID)
            guard self.isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID),
                  !self.ingestionManualReadThreads.contains(threadID),
                  self.presentation.selectedThreadID == threadID || self.ingestionOpenDetails.contains(threadID) || self.ingestionVisibleCards.contains(threadID) else { return }
            for host in self.uniqueIngestionHosts(sessionID: route.source.sessionID) {
                if let handle = host.threads[threadID], host.connection?.isSubscribed(handle) == false {
                    host.interests.removeValue(forKey: threadID)
                }
            }
            if self.presentation.selectedThreadID == threadID || self.ingestionOpenDetails.contains(threadID) {
                let retry = self.ingestionRetryPageRequests.removeValue(forKey: threadID)
                self.project(transcriptRef: route.transcriptRef, providerID: route.providerID, threadID: threadID,
                    binding: route.binding, source: route.source, cursor: retry?.cursor, nativeDirection: retry?.direction ?? "before")
            } else {
                let closed = self.uniqueIngestionHosts(sessionID: route.source.sessionID).filter { $0.connection?.isClosed == true }
                if !closed.isEmpty {
                    for host in closed { self.discardNativeHost(host) }
                    self.restartNativeInventoryAfterConnectionLoss(sessionID: route.source.sessionID)
                }
                self.startNativeInventory(sessionID: route.source.sessionID)
            }
            self.scheduleNativeInterests()
        }
        ingestionReadRetryTasks[threadID] = (id, task)
    }

    private func scheduleInitialProjectionRetry(_ threadID: AgentThreadID, route: AppleAgentProjectionRoute) {
        guard ingestionReadRetryTasks[threadID] == nil else { return }
        let failures = ingestionReadFailureCounts[threadID, default: 0]
        guard failures < 5 else {
            ingestionManualReadThreads.insert(threadID)
            return
        }
        ingestionReadFailureCounts[threadID] = failures + 1
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500 << failures)) } catch { return }
            guard let self, self.ingestionReadRetryTasks[threadID]?.id == id else { return }
            self.ingestionReadRetryTasks.removeValue(forKey: threadID)
            guard self.initialProjectionRoutes[threadID]?.matchesInventorySource(transcriptRef: route.transcriptRef,
                      binding: route.binding, registrationID: route.source.registrationID) == true,
                  self.isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID)
            else { return }
            self.project(transcriptRef: route.transcriptRef, providerID: route.providerID, threadID: threadID,
                binding: route.binding, source: route.source, cursor: nil)
        }
        ingestionReadRetryTasks[threadID] = (id, task)
    }

    private func restartNativeInventoryAfterConnectionLoss(sessionID: UUID) {
        let key = "\(sessionID.uuidString):native"
        inventoryTasks.removeValue(forKey: key)?.cancel()
        inventoryTaskIDs.removeValue(forKey: key)
        inventoryRetryAfter.removeValue(forKey: key)
        inventoryRetryTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func scheduleInitialPrefetch(threadID: AgentThreadID, route: AppleAgentProjectionRoute,
                                         nativeConnection: AppleAgentIngestionConnection? = nil) {
        guard initialPrefetchTasks[threadID] == nil,
              presentation.selectedThreadID == threadID || ingestionOpenDetails.contains(threadID) else { return }
        if let nativeConnection {
            guard let host = uniqueIngestionHosts(sessionID: route.source.sessionID).first(where: { $0.connection === nativeConnection }),
                  host.initialPrefetchStarted.insert(threadID).inserted else { return }
        }
        let taskID = UUID()
        initialPrefetchTaskIDs[threadID] = taskID
        let foreground = projectionTasks[threadID]
        initialPrefetchTasks[threadID] = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.initialPrefetchTaskIDs[threadID] == taskID {
                    self.initialPrefetchTasks.removeValue(forKey: threadID)
                    self.initialPrefetchTaskIDs.removeValue(forKey: threadID)
                    if self.pendingFillRequests.remove(threadID) != nil { self.requestOlderPage(threadID, fill: true) }
                }
            }
            await foreground?.value
            var completedPages = 1
            var requestedCursor: String?
            do {
                while true {
                    try Task.checkCancellation()
                    let snapshot = await self.runtime.snapshot(for: threadID)
                    let current = self.initialPrefetchTaskIDs[threadID] == taskID &&
                        (self.presentation.selectedThreadID == threadID || self.ingestionOpenDetails.contains(threadID)) &&
                        self.isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID) &&
                        (nativeConnection == nil || (nativeConnection?.isClosed == false && snapshot?.ingestionWindow?.epoch == nativeConnection?.epoch))
                    let priorityDemand = self.projectionTasks[threadID] != nil || self.outgoingReceiptLeases[threadID] != nil ||
                        self.pendingHistoryRequests.contains(threadID) || self.pendingLatestRequests.contains(threadID) ||
                        self.presentation.pendingSends[threadID] != nil || self.presentation.ingestionCapacityThreads.contains(threadID) ||
                        self.ingestionManualReadThreads.contains(threadID) || self.ingestionReadRetryTasks[threadID] != nil
                    guard AgentInitialLoadPolicy.shouldPrefetch(completedPages: completedPages,
                        hasOlder: snapshot?.hasMore == true, isCurrent: current, hasPriorityDemand: priorityDemand),
                        let cursor = snapshot?.cursor else { return }
                    requestedCursor = cursor
                    if let nativeConnection {
                        try await self.projectNative(transcriptRef: route.transcriptRef, providerID: route.providerID,
                            threadID: threadID, binding: route.binding, source: route.source, cursor: cursor,
                            requiredConnection: nativeConnection)
                    } else {
                        let isCurrent: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { [weak self] binding in
                            self?.isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: route.source.registrationID) == true
                        }
                        guard case .available(let factory) = route.source.projectorExecAvailability(route.binding, isCurrent),
                              let request = AgentProjectionRequest(kind: .project, providerID: route.providerID,
                                transcriptRef: route.transcriptRef, cursor: cursor,
                                limitBytes: AgentProjectionRequest.maximumBytes, limitRecords: AgentProjectionRequest.maximumRecords)
                        else { return }
                        let exec = AppleAgentStreamingExecPort(binding: route.binding, factory: factory)
                        let channel = AppleAgentRemoteDataChannel(binding: route.binding,
                            endpoint: AppleAgentProjectionEndpoint.projector(exec: exec, searchThreadID: threadID))
                        for try await page in try await channel.project(request) {
                            try Task.checkCancellation()
                            guard self.initialPrefetchTaskIDs[threadID] == taskID, isCurrent(route.binding),
                                  await self.apply(page: page, to: threadID).accepted else { return }
                        }
                    }
                    completedPages += 1
                }
            } catch {
                if self.presentation.ingestionReadStatuses[threadID]?.recovery == .retryRead, let requestedCursor {
                    self.ingestionRetryPageRequests[threadID] = (requestedCursor, "before")
                }
                if error is CancellationError { return }
                // Optional history leaves the acknowledged newest page usable.
                DiagnosticLogStore.appendAgentCenter("v2-initial-history result=stopped provider=\(route.providerID.rawValue)")
            }
        }
    }

    func scheduleNativeInterests() {
        guard isEnabled, applicationActive, hasSurfaceDemand else { return }
        for host in uniqueIngestionHosts() {
            let sessionID = host.binding.liveSessionID
            host.interestRevision &+= 1
            guard host.interestTask == nil else { continue }
            host.interestTask = Task { @MainActor [weak self, weak host] in
                guard let self, let host else { return }
                defer { host.interestTask = nil }
                interestPass: repeat {
                    let revision = host.interestRevision
                    do {
                        let connection = try await host.opening.value
                        guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                        let candidates = host.threads.keys.filter {
                            !host.pausedThreads.contains($0) && !self.presentation.ingestionCapacityThreads.contains($0) &&
                            !self.ingestionManualReadThreads.contains($0) && self.ingestionReadRetryTasks[$0] == nil &&
                            (self.ingestionVisibleCards.contains($0) || self.ingestionOpenDetails.contains($0))
                        }
                            .sorted { left, right in
                                if self.ingestionOpenDetails.contains(left) != self.ingestionOpenDetails.contains(right) {
                                    return self.ingestionOpenDetails.contains(left)
                                }
                                return (host.threads[left] ?? "") < (host.threads[right] ?? "")
                            }
                        let desired = Set(candidates.prefix(64))
                        for thread in host.bootstrapped where !host.pausedThreads.contains(thread) {
                            guard await self.runtime.ingestionWindowSnapshot(for: thread) == nil,
                                  let handle = host.threads[thread] else { continue }
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            guard revision == host.interestRevision else { continue interestPass }
                            _ = try await connection.request(["kind": .string("unsubscribe"), "thread": .string(handle)])
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.interests.removeValue(forKey: thread)
                            guard revision == host.interestRevision else { continue interestPass }
                            _ = try await connection.request(["kind": .string("window.release"), "thread": .string(handle)])
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.bootstrapped.remove(thread); host.interests.removeValue(forKey: thread)
                            host.initialPrefetchStarted.remove(thread)
                            guard revision == host.interestRevision else { continue interestPass }
                            if self.ingestionOpenDetails.contains(thread) { self.refreshVisibleTranscript(thread) }
                        }
                        for thread in host.bootstrapped where !self.ingestionOpenDetails.contains(thread) &&
                            (!host.pausedThreads.contains(thread) || self.presentation.ingestionCapacityThreads.contains(thread)) {
                            guard let handle = host.threads[thread],
                                  await self.runtime.ingestionWindowSnapshot(for: thread)?.retainsOutgoing != true else { continue }
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            guard revision == host.interestRevision else { continue interestPass }
                            _ = try await connection.request(["kind": .string("unsubscribe"), "thread": .string(handle)])
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.interests.removeValue(forKey: thread)
                            guard revision == host.interestRevision else { continue interestPass }
                            _ = try await connection.request(["kind": .string("window.release"), "thread": .string(handle)])
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.bootstrapped.remove(thread); host.interests.removeValue(forKey: thread)
                            host.initialPrefetchStarted.remove(thread)
                            await self.runtime.releaseIngestionWindow(for: thread)
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            // The remote window is gone, but a newer capacity
                            // pause must survive this earlier release's ACK.
                            guard revision == host.interestRevision else { continue interestPass }
                            let wasPaused = host.pausedThreads.remove(thread) != nil
                            let wasCapacityPaused = self.presentation.ingestionCapacityThreads.contains(thread)
                                && self.presentation.ingestionCapacityThreads.remove(thread) != nil
                            if wasPaused || wasCapacityPaused {
                                host.interestRevision &+= 1
                                continue interestPass
                            }
                        }
                        for thread in host.interests.keys.filter({ !desired.contains($0) }) {
                            guard let handle = host.threads[thread] else { continue }
                            _ = try await connection.request(["kind": .string("unsubscribe"), "thread": .string(handle)])
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.interests.removeValue(forKey: thread)
                            guard revision == host.interestRevision else { continue interestPass }
                        }
                        for thread in desired {
                            guard let handle = host.threads[thread] else { continue }
                            let fast = self.ingestionOpenDetails.contains(thread) && host.bootstrapped.contains(thread)
                            guard host.interests[thread] != fast else { continue }
                            var request: [String: AgentJSONValue] = ["kind": .string("subscribe"), "thread": .string(handle),
                                "interest": .string(fast ? "fast" : "slow")]
                            if fast {
                                guard let checkpoint = await self.runtime.ingestionCheckpoint(for: thread), checkpoint.epoch == connection.epoch else { continue }
                                request["liveCursor"] = .string(checkpoint.cursor)
                                guard let window = await self.runtime.ingestionWindowSnapshot(for: thread) else { continue }
                                request["windowVersion"] = .number(Decimal(window.version))
                            }
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            guard revision == host.interestRevision else { continue interestPass }
                            _ = try await connection.request(request)
                            guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                            host.interests[thread] = fast
                            if revision != host.interestRevision {
                                // The remote watch exists even if demand or
                                // resync changed during its ACK. Tear it down
                                // before reconciling the latest intent.
                                _ = try await connection.request(["kind": .string("unsubscribe"), "thread": .string(handle)])
                                guard !Task.isCancelled, self.isNativeHostCurrent(host, sessionID: sessionID) else { return }
                                host.interests.removeValue(forKey: thread)
                                continue interestPass
                            }
                        }
                    } catch { return }
                    if revision == host.interestRevision { return }
                } while !Task.isCancelled
            }
        }
    }

    /// Search uses the same carrier-fenced persistent native connection as
    /// transcript projection. It never falls back to cached blocks when a
    /// connected source can answer, so cross-host results remain current.
    private func isSearchRouteCurrent(_ route: AppleAgentProjectionRoute, threadID: AgentThreadID) -> Bool {
        guard let current = projectionRoutes[threadID] ?? historicalRoutes[threadID] else { return false }
        return current.matchesInventorySource(transcriptRef: route.transcriptRef, binding: route.binding,
            registrationID: route.source.registrationID) &&
            isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID)
    }

    private func searchNativeProvider(threadID: AgentThreadID, route: AppleAgentProjectionRoute, query: String, remaining: Duration) async throws -> [AgentSearchResult] {
        try await AppleAgentIngestionConnection.withSearchDeadline(remaining) { [self] in
            try await searchNativeProviderPages(threadID: threadID, route: route, query: query)
        }
    }

    private func searchNativeProviderPages(threadID: AgentThreadID, route: AppleAgentProjectionRoute, query: String) async throws -> [AgentSearchResult] {
        let (host, connection) = try await nativeHost(source: route.source, context: route.binding)
        guard [.codex, .claude].contains(route.providerID) ||
            (route.providerID == .pi && connection.supportsPiSessions) ||
            (route.providerID == .kimi && connection.supportsKimiSessions) ||
            (route.providerID == .opencode && connection.supportsOpenCodeSessions) else {
            throw AgentIngestionError.remote("unsupportedNativeReader")
        }
        let nativeLocator = [.codex, .opencode].contains(route.providerID) && route.transcriptRef.hasPrefix("native:")
        let resolved = try await connection.request(["kind": .string("resolve"), "provider": .string(route.providerID.rawValue),
            nativeLocator ? "nativeSessionID" : "transcriptRef": .string(nativeLocator ? String(route.transcriptRef.dropFirst(7)) : route.transcriptRef)])
        guard resolved.object["provider"]?.stringValue == route.providerID.rawValue, resolved.object["sessionID"]?.stringValue == threadID.providerSessionID,
              let handle = resolved.object["thread"]?.stringValue else { throw AgentIngestionError.malformedFrame }
        try host.reserveHandles([(threadID, handle)])
        var results: [AgentSearchResult] = []
        var cursor: String?
        var identity: String?
        var previousOrder: UInt64?
        for _ in 0..<512 {
            try Task.checkCancellation()
            guard isNativeHostCurrent(host, sessionID: route.source.sessionID),
                  isSearchRouteCurrent(route, threadID: threadID) else { throw AgentActionError.staleBinding }
            var fields: [String: AgentJSONValue] = ["kind": .string(cursor == nil ? "bootstrap" : "history"), "thread": .string(handle), "limit": .number(100)]
            if let cursor { fields["cursor"] = .string(cursor) }
            let reply = try await connection.request(fields)
            guard !Task.isCancelled, isNativeHostCurrent(host, sessionID: route.source.sessionID),
                  isSearchRouteCurrent(route, threadID: threadID) else {
                throw AgentActionError.staleBinding
            }
            guard let page = reply.page, identity == nil || identity == page.sourceIdentity,
                  previousOrder == nil || page.records.first.map({ $0.sequence < previousOrder! }) == true else {
                throw AgentIngestionError.remote("sourceChanged")
            }
            identity = page.sourceIdentity; previousOrder = page.records.first?.sequence
            results.append(contentsOf: AgentNativePageSearch.matches(page: page, threadID: threadID, query: query).prefix(25 - results.count))
            if results.count == 25 || !page.hasMore { return results }
            guard let next = page.cursor, next != cursor else { throw AgentIngestionError.malformedFrame }
            cursor = next
        }
        throw AgentIngestionError.capacityExceeded
    }

    func searchConnectedSources(query: String, generation: UInt64) async {
        let needle = String(query.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let routes = projectionRoutes.merging(historicalRoutes) { live, _ in live }
        var results: [AgentSearchResult] = []
        var unavailableHosts = Set<UUID>()
        var resultCounts = [UUID: Int]()
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for (threadID, route) in routes {
            guard !Task.isCancelled, isEnabled, searchGeneration == generation, applicationActive, hasSurfaceDemand else { return }
            if resultCounts[threadID.hostID, default: 0] >= 100 { continue }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { unavailableHosts.insert(threadID.hostID); continue }
            let routeIsCurrent = sessionRoutes[route.binding.liveSessionID]?.source.registrationID == route.source.registrationID
                && (threadRoutes[threadID]?.binding == route.binding || historicalRoutes[threadID]?.binding == route.binding)
            if routeIsCurrent {
                do {
                    let matches = try await searchNativeProvider(threadID: threadID, route: route, query: needle, remaining: remaining)
                    guard !Task.isCancelled, isEnabled, searchGeneration == generation, applicationActive, hasSurfaceDemand else { return }
                    guard isSearchRouteCurrent(route, threadID: threadID) else {
                        unavailableHosts.insert(threadID.hostID); continue
                    }
                    let admitted = matches.prefix(max(0, 100 - resultCounts[threadID.hostID, default: 0]))
                    results.append(contentsOf: admitted); resultCounts[threadID.hostID, default: 0] += admitted.count
                } catch is CancellationError { return }
                catch { unavailableHosts.insert(threadID.hostID) }
                continue
            }
            unavailableHosts.insert(threadID.hostID)
        }
        guard !Task.isCancelled, isEnabled, searchGeneration == generation, applicationActive, hasSurfaceDemand else { return }
        await bridge.applySearch(.init(results: results, unavailableHostIDs: Array(unavailableHosts)))
        presentation.searchSnapshot = bridge.searchSnapshot
        DiagnosticLogStore.appendAgentCenter("v2-search result=completed sources=\(routes.count) results=\(results.count) unavailableHosts=\(bridge.searchSnapshot.unavailableHostIDs.count)")
    }

    /// Registers an already-owned interactive session. This never connects a
    /// transport; discovery and projector acquisition are allowed to use only
    /// the carrier operations supplied by the session owner.
    func registerSessionSource(
        _ source: AgentSessionSource,
        hostID: UUID,
        hostDisplayLabel: String = "",
        profiles: @escaping @MainActor () -> [SwipePadProfile]
    ) {
        if let previous = sessionRoutes[source.sessionID],
           previous.source.registrationID != source.registrationID {
            closeIngestionHosts(sessionID: source.sessionID)
            ingestionScopes = ingestionScopes.filter { $0.key.sessionID != source.sessionID }
            invalidateSessionRefresh(sessionID: source.sessionID)
            retireIntegration(
                sessionID: source.sessionID,
                registrationID: previous.source.registrationID
            )
            retireRoutes(forRegistrationID: previous.source.registrationID)
            if sessionConformingProviders.removeValue(forKey: source.sessionID) != nil {
                scheduleProviderRegistryRefresh()
            }
            inventoryRetryTasks.removeValue(forKey: source.sessionID)?.cancel()
            let taskPrefix = "\(source.sessionID.uuidString):"
            inventoryRetryAfter = inventoryRetryAfter.filter { !$0.key.hasPrefix(taskPrefix) }
            for key in inventoryTasks.keys.filter({ $0.hasPrefix(taskPrefix) }) {
                inventoryTasks.removeValue(forKey: key)?.cancel()
                inventoryTaskIDs.removeValue(forKey: key)
            }
        }
        nextCarrierGeneration &+= 1
        sessionRoutes[source.sessionID] = AppleAgentSessionRoute(
            hostID: hostID,
            hostDisplayLabel: String(hostDisplayLabel.prefix(512)),
            source: source,
            profiles: profiles,
            carrierGeneration: nextCarrierGeneration
        )
        if let readCarrier = source.readCarrier?() {
            sessionReadCarriers[source.sessionID] = readCarrier
        } else {
            sessionReadCarriers.removeValue(forKey: source.sessionID)
        }
        scheduleSessionRefresh(sessionID: source.sessionID)
        scheduleIntegrationRefresh(sessionID: source.sessionID)
        if !pendingNotificationRoutes.isEmpty { startNotificationRouteRetry() }
        if hasSurfaceDemand { startInventory(sessionID: source.sessionID) }
    }

    func unregisterSessionSource(sessionID: UUID, registrationID: UUID) {
        guard let route = sessionRoutes[sessionID], route.source.registrationID == registrationID else { return }
        closeIngestionHosts(sessionID: sessionID)
        ingestionScopes = ingestionScopes.filter { $0.key.sessionID != sessionID }
        retireIntegration(sessionID: sessionID, registrationID: registrationID)
        sessionRoutes.removeValue(forKey: sessionID)
        if !sessionRoutes.values.contains(where: { $0.hostID == route.hostID }) {
            livePromptWatchOutcomes = livePromptWatchOutcomes.filter { $0.key.hostID != route.hostID }
        }
        if sessionConformingProviders.removeValue(forKey: sessionID) != nil {
            scheduleProviderRegistryRefresh()
        }
        sessionReadCarriers.removeValue(forKey: sessionID)
        validatedLaunchDirectories.removeValue(forKey: sessionID)
        occupancyDiagnosticOutcomes.removeValue(forKey: sessionID)
        lifecycleDiagnosticOutcomes = lifecycleDiagnosticOutcomes.filter { !$0.key.hasPrefix("\(sessionID.uuidString):") }
        invalidateSessionRefresh(sessionID: sessionID)
        inventoryRetryTasks.removeValue(forKey: sessionID)?.cancel()
        inventoryRetryAfter = inventoryRetryAfter.filter { !$0.key.hasPrefix("\(sessionID.uuidString):") }
        inventoryTasks.keys.filter { $0.hasPrefix("\(sessionID.uuidString):") }.forEach {
            inventoryTasks.removeValue(forKey: $0)?.cancel()
        }
        lifecycleScanners = lifecycleScanners.filter { $0.key.sessionID != sessionID }
        clearSwipePadFocus(sessionID: sessionID)
        retireRoutes(forRegistrationID: registrationID, rememberingHostID: isEnabled ? route.hostID : nil)
    }

    func noteOutput(
        sessionID: UUID,
        paneID: Int?,
        registrationID: UUID,
        data: ArraySlice<UInt8>
    ) {
        guard isEnabled,
              sessionRoutes[sessionID]?.source.registrationID == registrationID,
              !data.isEmpty else { return }
        scheduleIntegrationActivityRefresh(sessionID: sessionID)
        let id = AgentInstanceID(sessionID: sessionID, paneID: paneID)
        var scanner = lifecycleScanners[id] ?? AgentLifecycleOSCScanner()
        let events = scanner.feed(data)
        lifecycleScanners[id] = scanner
        let admitted = events.filter { admitLifecycle($0, at: id) }
        if admitted.isEmpty {
            scheduleSessionRefresh(sessionID: sessionID)
        }
        for event in admitted {
            scheduleSessionRefresh(sessionID: sessionID, paneID: paneID, lifecycle: event)
        }
    }

    func noteLifecyclePayload(
        sessionID: UUID,
        paneID: Int?,
        registrationID: UUID,
        json: String
    ) {
        guard isEnabled,
              sessionRoutes[sessionID]?.source.registrationID == registrationID,
              let event = AgentLifecycleEvent.decode(json: json),
              admitLifecycle(event, at: AgentInstanceID(sessionID: sessionID, paneID: paneID))
        else { return }
        scheduleIntegrationActivityRefresh(sessionID: sessionID, delay: .milliseconds(100))
        scheduleSessionRefresh(sessionID: sessionID, paneID: paneID, lifecycle: event)
    }

    /// Whether a delivered lifecycle frame may start a discovery pass. tmux
    /// announces a pane's option again with every change to the pane's other
    /// metadata, so an agent's title spinner repeats its last frame many times
    /// a second; and agents an agent runs in the background (Codex started by
    /// Claude) inherit its pane and write the option too. Every pass costs
    /// the host a process read and several tmux commands, so a repeat starts
    /// one only after `lifecycleRepeatInterval`, and a background agent's
    /// frames none while a proven agent holds the pane.
    private func admitLifecycle(_ event: AgentLifecycleEvent, at id: AgentInstanceID) -> Bool {
        let now = Date()
        if let last = lastLifecycleDeliveries[id], last.event == event,
           now.timeIntervalSince(last.admittedAt) < AgentCenterV2DiscoveryPolicy.lifecycleRepeatInterval {
            return false
        }
        // A session boundary is rare and may be a judged process taking the
        // pane after all, so it always gets a pass.
        let boundary = event.event == AgentLifecycleEventKind.sessionStart.rawValue
            || event.event == AgentLifecycleEventKind.sessionEnd.rawValue
        if let pid = event.agentPID, !boundary, foreignLifecyclePIDs[id]?[pid] != nil {
            let holders = paneHolderPIDs(at: id)
            if !isKnownForeign(pid, at: id) || holders?.contains(pid) == true {
                foreignLifecyclePIDs[id]?[pid] = nil
            } else if holders != nil {
                return false
            }
        }
        lastLifecycleDeliveries[id] = (event, now)
        return true
    }

    /// The PIDs proven agents hold `id`'s pane with; nil when none does.
    private func paneHolderPIDs(at id: AgentInstanceID) -> Set<Int>? {
        guard let registrationID = sessionRoutes[id.sessionID]?.source.registrationID else { return nil }
        let pids = Set(threadRoutes.values.compactMap { held -> Int? in
            guard held.registrationID == registrationID,
                  held.location.sessionID == id.sessionID, held.location.paneID == id.paneID
            else { return nil }
            return held.binding.agentPID
        })
        return pids.isEmpty ? nil : pids
    }

    func scheduleSessionRefresh(
        sessionID: UUID,
        paneID: Int? = nil,
        lifecycle: AgentLifecycleEvent? = nil
    ) {
        guard isEnabled, sessionRoutes[sessionID] != nil else { return }
        var queue = sessionRefreshQueues[sessionID] ?? .init()
        queue.enqueue(paneID: paneID, lifecycle: lifecycle)
        sessionRefreshQueues[sessionID] = queue
        guard sessionRefreshTasks[sessionID] == nil else { return }
        let taskID = UUID()
        sessionRefreshTaskIDs[sessionID] = taskID
        sessionRefreshTasks[sessionID] = Task { @MainActor [weak self] in
            await self?.runSessionRefreshWorker(sessionID: sessionID, taskID: taskID)
        }
    }

    /// Runs the quiet process sweep at once, as when the app returns from the
    /// background, without a full discovery pass or a SwipePad republish.
    func scheduleLivenessSweep(sessionID: UUID) {
        guard isEnabled, sessionRoutes[sessionID] != nil else { return }
        sessionLivenessRequested.insert(sessionID)
        guard sessionRefreshTasks[sessionID] == nil else { return }
        let taskID = UUID()
        sessionRefreshTaskIDs[sessionID] = taskID
        sessionRefreshTasks[sessionID] = Task { @MainActor [weak self] in
            await self?.runSessionRefreshWorker(sessionID: sessionID, taskID: taskID)
        }
    }

    private func invalidateSessionRefresh(sessionID: UUID) {
        lastLifecycleDeliveries = lastLifecycleDeliveries.filter { $0.key.sessionID != sessionID }
        foreignLifecyclePIDs = foreignLifecyclePIDs.filter { $0.key.sessionID != sessionID }
        sessionDiscoveryAfter.removeValue(forKey: sessionID)
        sessionRefreshQueues.removeValue(forKey: sessionID)
        sessionRefreshInFlight.remove(sessionID)
        sessionLivenessRequested.remove(sessionID)
        sessionRefreshTaskIDs.removeValue(forKey: sessionID)
        sessionRefreshTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func runSessionRefreshWorker(sessionID: UUID, taskID: UUID) async {
        defer {
            if AgentCenterV2TaskOwnership.owns(
                currentTaskID: sessionRefreshTaskIDs[sessionID], taskID: taskID
            ) {
                sessionRefreshTasks.removeValue(forKey: sessionID)
                sessionRefreshTaskIDs.removeValue(forKey: sessionID)
                sessionRefreshQueues.removeValue(forKey: sessionID)
                sessionRefreshInFlight.remove(sessionID)
                sessionLivenessRequested.remove(sessionID)
            }
        }
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return }
        var consecutiveReadMisses = 0
        var livenessAfter = Date().addingTimeInterval(AgentCenterV2DiscoveryPolicy.livenessInterval)
        while !Task.isCancelled,
              AgentCenterV2TaskOwnership.owns(
                  currentTaskID: sessionRefreshTaskIDs[sessionID], taskID: taskID
              ),
              isEnabled,
              sessionRoutes[sessionID] != nil {
            var queue = sessionRefreshQueues[sessionID] ?? .init()
            let sweepDue = applicationActive
                && (Date() >= livenessAfter || sessionLivenessRequested.contains(sessionID)) && threadRoutes.values.contains {
                $0.binding.liveSessionID == sessionID && $0.binding.agentPID != nil
            }
            if queue.isEmpty, !sweepDue {
                guard applicationActive, threadRoutes.values.contains(where: {
                    $0.binding.liveSessionID == sessionID && $0.binding.agentPID != nil
                }) else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            // Generic terminal bytes can be continuous. Rate-limit the
            // expensive all-pane inspection, but let lifecycle hooks bypass
            // the cooldown; no prompt/completion waits for a quiet terminal.
            let queued = sweepDue ? nil : queue.dequeue(allowGeneric: Date() >= (sessionDiscoveryAfter[sessionID] ?? .distantPast))
            let livenessOnly = queued == nil && sweepDue
            if livenessOnly { sessionLivenessRequested.remove(sessionID) }
            guard let request = queued ?? (livenessOnly ? .init(paneID: nil, lifecycle: nil) : nil) else {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            if request.lifecycle == nil, !livenessOnly {
                sessionDiscoveryAfter[sessionID] = Date().addingTimeInterval(
                    AgentCenterV2DiscoveryPolicy.genericDiscoveryInterval(
                        hasSurfaceDemand: hasSurfaceDemand
                    )
                )
            }
            if queue.isEmpty {
                sessionRefreshQueues.removeValue(forKey: sessionID)
            } else {
                sessionRefreshQueues[sessionID] = queue
            }
            let registrationID = sessionRoutes[sessionID]?.source.registrationID
            sessionRefreshInFlight.insert(sessionID)
            let retry = await refreshSession(
                sessionID: sessionID,
                paneID: request.paneID,
                lifecycle: request.lifecycle,
                taskID: taskID,
                livenessOnly: livenessOnly
            )
            guard sessionRefreshTaskIDs[sessionID] == taskID else { return }
            if livenessOnly { livenessAfter = Date().addingTimeInterval(AgentCenterV2DiscoveryPolicy.livenessInterval) }
            if retry {
                consecutiveReadMisses = min(consecutiveReadMisses + 1, 6)
                let retrySeconds = min(30, 1 << (consecutiveReadMisses - 1))
                repeat {
                    do { try await Task.sleep(for: .seconds(retrySeconds)) } catch { return }
                    guard !Task.isCancelled,
                          sessionRefreshTaskIDs[sessionID] == taskID,
                          sessionRoutes[sessionID]?.source.registrationID == registrationID else { return }
                } while !applicationActive
                if request.lifecycle == nil { sessionDiscoveryAfter.removeValue(forKey: sessionID) }
                if livenessOnly {
                    livenessAfter = .distantPast
                } else {
                    var pending = sessionRefreshQueues[sessionID] ?? .init()
                    pending.requeueIfAbsent(request)
                    sessionRefreshQueues[sessionID] = pending
                }
            } else {
                consecutiveReadMisses = 0
            }
            sessionRefreshInFlight.remove(sessionID)
        }
    }

    func sessionRefreshIsIdle(_ sessionID: UUID) -> Bool {
        !sessionRefreshInFlight.contains(sessionID) && sessionRefreshQueues[sessionID]?.isEmpty != false
            && !sessionLivenessRequested.contains(sessionID)
    }

    private func refreshSession(
        sessionID: UUID,
        paneID: Int?,
        lifecycle: AgentLifecycleEvent?,
        taskID: UUID,
        livenessOnly: Bool = false
    ) async -> Bool {
        guard !Task.isCancelled,
              !livenessOnly || applicationActive,
              AgentCenterV2TaskOwnership.owns(
                  currentTaskID: sessionRefreshTaskIDs[sessionID], taskID: taskID
              ),
              isEnabled,
              let route = sessionRoutes[sessionID]
        else { return false }
        let scope = AgentCenterV2DiscoveryScope(sessionID: sessionID, paneID: paneID)
        if livenessOnly {
            route.source.invalidateProcessSnapshots?()
            if await reconcileOccupancy(route: route) {
                await synchronizePresentation(refreshLaunchSuggestions: false)
                publishSwipePadEvidence(for: sessionID)
            }
            return false
        }
        defer {
            if lifecycle?.event == "SessionEnd" || lifecycle?.event == "WrapperExit" {
                scheduleLivenessSweep(sessionID: sessionID)
            }
        }
        let discoveryStarted = Date()
        DiagnosticLogStore.appendAgentCenter("latency-agent-v3 sid=\(sessionID.uuidString.prefix(8)) stage=discovery-start surfaceDemand=\(hasSurfaceDemand) trigger=\(lifecycle == nil ? "generic-output" : "lifecycle") nextGenericAfterSeconds=\(Int(AgentCenterV2DiscoveryPolicy.genericDiscoveryInterval(hasSurfaceDemand: hasSurfaceDemand)))")
        let discoveryResult = await route.source.discoverForLifecycle(lifecycle?.agentPID)
        DiagnosticLogStore.appendAgentCenter("latency-agent-v3 sid=\(sessionID.uuidString.prefix(8)) stage=discovery-end durationMs=\(Int(Date().timeIntervalSince(discoveryStarted) * 1_000))")
        performanceDiagnostics.record("discover", since: discoveryStarted)
        // Retain the request when a read misses: an idle pane may never emit another hook.
        guard case .success(let discovered) = discoveryResult else { return true }
        let reductionStarted = Date()
        defer { performanceDiagnostics.record("discoveryReduce", since: reductionStarted) }
        // Discovery is asynchronous over a transport-owned carrier. A
        // replacement may reuse the LiveSession ID while this await is in
        // flight; never let the former owner's result register or retire
        // routes after the new owner has taken over.
        guard !Task.isCancelled,
              !livenessOnly || applicationActive,
              AgentCenterV2TaskOwnership.owns(
                  currentTaskID: sessionRefreshTaskIDs[sessionID], taskID: taskID
              ),
              sessionRoutes[sessionID]?.source.registrationID == route.source.registrationID else {
            return false
        }
        let targets = discovered
        if let pid = lifecycle?.agentPID,
           threadRoutes.values.contains(where: { $0.registrationID == route.source.registrationID && $0.binding.agentPID == pid }),
           !targets.contains(where: { scope.contains($0.location) && $0.processIDs.contains(pid) }) {
            scheduleLivenessSweep(sessionID: sessionID)
        }
        var seenThreadIDs = Set<AgentThreadID>()
        var seenCandidateIDs = Set<AgentSourceCandidateID>()
        var frames: [(target: AgentProbeTarget, restored: AgentLifecycleEvent?)] = []
        for target in targets where scope.contains(target.location) {
            var currentIsOlderThanRestoredRoot = false
            if let paneID = target.location.paneID, target.processSnapshotTakenAt.map({ $0 >= discoveryStarted }) ?? true {
                let remembered = retiredPaneHolders.filter { key, _ in key.hostID == route.hostID && key.paneID == paneID }
                for (key, retired) in remembered {
                    retiredPaneHolders.removeValue(forKey: key)
                    // A remembered conversation whose process still runs in
                    // the pane comes back observe-only, also beside another
                    // proved agent there (a background or suspended holder):
                    // only its process's absence, read by occupancy, ends it.
                    if target.processIDs.contains(retired.agentPID) {
                        frames.append((target, retired.lifecycleEvent))
                        if let current = lifecycle ?? target.lifecycleEvent,
                           current.agentPID == retired.agentPID, current.provider == retired.lifecycleEvent.provider,
                           retired.lifecycleEvent.provider != "codex" || retired.lifecycleEvent.agentID == nil,
                           current.timestampNanoseconds < retired.lifecycleEvent.timestampNanoseconds {
                            currentIsOlderThanRestoredRoot = true
                        }
                    }
                }
            }
            if !currentIsOlderThanRestoredRoot { frames.append((target, nil)) }
        }
        // Remembered siblings precede the pane's current frame. A fresh root
        // boundary can then replace old restored conversations in Core.
        let frameTime: ((target: AgentProbeTarget, restored: AgentLifecycleEvent?)) -> UInt64 = { frame in
            let event: AgentLifecycleEvent? = frame.restored ?? lifecycle ?? frame.target.lifecycleEvent
            return event?.timestampNanoseconds ?? 0
        }
        frames.sort { frameTime($0) < frameTime($1) }
        for (target, restoredEvent) in frames {
            guard !Task.isCancelled,
                  isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID)
            else { return false }
            // Raw SSH/mosh deliver hooks through OSC, not retained tmux
            // metadata. Keep the last proven hook on its exact process route
            // so ordinary output cannot demote an identified thread to a
            // fallback or prevent observing a prompt drawn after the hook.
            let holder = paneHolder(of: target, registrationID: route.source.registrationID)
            var event = restoredEvent ?? lifecycle ?? target.lifecycleEvent ?? holder?.lifecycleEvent
            // A foreground restore replaces the connection and retires the
            // route that kept this pane its foreground agent's while background
            // agents wrote the pane option. The live session ID and tmux view
            // session change; the host's pane does not. Recover the retired
            // holder there only when nothing current is proven and this
            // connection's own fresh read finds its PID in the pane's
            // foreground. The binding below is minted from this carrier.
            let restoredThisPass = restoredEvent != nil
            // Agents an agent runs in the background (Codex started by Claude)
            // inherit its pane, so their hooks write the pane's lifecycle too,
            // naming a process outside the pane's foreground. While a proven
            // agent still runs there, the pane stays that agent's; the frame
            // must not turn it into an unproven row and unbind it until its
            // own next hook.
            if let foreignPID = event?.agentPID, !target.processIDs.contains(foreignPID) {
                if threadRoutes.values.contains(where: {
                    $0.registrationID == route.source.registrationID && $0.binding.agentPID == foreignPID
                }) { scheduleLivenessSweep(sessionID: sessionID) }
                if target.processSnapshotTakenAt.map({ $0 >= discoveryStarted }) ?? true {
                    let place = AgentInstanceID(sessionID: sessionID, paneID: target.location.paneID)
                    if !isKnownForeign(foreignPID, at: place) {
                        DiagnosticLogStore.appendAgentCenter(
                            "lifecycle-foreign sid=\(sessionID.uuidString.prefix(8)) pane=\(target.location.paneID.map(String.init) ?? "raw") holder=\(holder == nil ? "none" : "kept")"
                        )
                    }
                    let now = Date()
                    var judged = (foreignLifecyclePIDs[place] ?? [:]).filter { $0.value > now }
                    judged[foreignPID] = now.addingTimeInterval(AgentCenterV2DiscoveryPolicy.foreignLifecycleInterval)
                    foreignLifecyclePIDs[place] = judged
                }
                // The pane's own retained event, when this read proves it,
                // holds the pane even without a route that held it before.
                let current = target.lifecycleEvent.flatMap { option in
                    option.agentPID.map(target.processIDs.contains) == true ? option : nil
                }
                event = current ?? holder?.lifecycleEvent
            }
            if event?.agentPID != nil,
               target.processSnapshotTakenAt == .distantPast {
                event = nil
            }
            // A restored holder stays observe-only, also while later passes
            // keep the pane with its event, until the agent's own frame.
            let unconfirmed = restoredThisPass || threadRoutes.values.contains { held in
                held.restoredFromRetiredConnection && held.registrationID == route.source.registrationID
                    && held.location.paneID == target.location.paneID && held.lifecycleEvent == event
            }
            guard let profile = matchingProfile(target.processNames, profiles: route.profiles()),
                  let providerID = providerID(event: event, processNames: target.processNames),
                  let provider = providerManifest(for: providerID, sessionID: sessionID)
            else { continue }

            // A decoded OSC is only a syntactically valid hook envelope.  Do
            // not let a Tier-C provider acquire lifecycle status until this
            // exact session has passed its shared live capability gate.  The
            // binding/PID proof below remains the independent authority for
            // every accepted event.
            if let event,
               !supportsLifecycle(event, provider: provider) {
                continue
            }

            let provenAgentPID = event?.agentPID.flatMap { pid in
                target.processIDs.contains(pid) ? pid : nil
            }
            // A proven agent is its own process, not the pane's descendants:
            // every tool shell and hook comes and goes under it each turn.
            // Counting those rebound the thread mid-turn, which revoked a send
            // in flight, stranded its bubble at "receipt unavailable", opened
            // another reader per process set and made Core refuse the agent's
            // next frames as another route. An unproven pane keeps the set.
            let processIdentity = provenAgentPID.map { "agent-\($0)" } ?? String(
                target.processIDs.sorted().map(String.init).joined(separator: ",").prefix(160)
            )
            guard let incarnation = AgentIncarnationToken(
                "\(route.source.registrationID.uuidString):\(providerID.rawValue):\(processIdentity)"
            ) else { continue }

            // A lifecycle frame is transport input, not process proof. Until
            // the session-owned discovery target independently correlates its
            // PID, retain a useful observe-only row but advertise no mutations.
            var capabilities: AgentTerminalCapabilities = [.observe]
            if provenAgentPID != nil, !unconfirmed {
                capabilities.formUnion([.send, .interrupt, .promptAnswer])
            }
            if target.location.paneID != nil { capabilities.insert(.tmux) }
            let binding = AgentTerminalBinding(
                liveSessionID: sessionID,
                carrierGeneration: route.carrierGeneration,
                incarnation: incarnation,
                transport: transportKind(target.location),
                tmuxSession: target.location.tmuxSessionName,
                windowID: target.location.windowID.map(String.init),
                paneID: target.location.paneID.map(String.init),
                agentPID: provenAgentPID,
                capabilities: capabilities
            )
            let sourceIdentity = "live:\(route.source.registrationID.uuidString):\(target.location.paneID.map(String.init) ?? "raw"):\(processIdentity)"
            let threadRoute = AppleAgentThreadRoute(
                registrationID: route.source.registrationID,
                location: target.location,
                profile: profile,
                binding: binding,
                sourceIdentity: sourceIdentity,
                lifecycleEvent: event,
                restoredFromRetiredConnection: unconfirmed
            )

            let arrivalSequence = lifecycleArrivalGeneration &+ 1
            let envelope = event.flatMap { coreEnvelope($0, providerID: providerID, arrivalSequence: arrivalSequence) }
            if let event, event.agentID == nil, provenAgentPID != nil {
                let roots = threadRoutes.filter { id, held in
                    id.providerID == providerID && held.lifecycleEvent?.agentID == nil
                        && AgentCenterRuntime.sameProcess(held.binding, binding)
                }
                let blankRoot = event.providerSessionID.isEmpty && providerID == .codex
                let unlocatableSuccessor = !event.providerSessionID.isEmpty && envelope == nil
                    && roots.contains { id, held in
                        id.providerSessionID != event.providerSessionID
                            && (held.lifecycleEvent?.timestampNanoseconds ?? 0) < event.timestampNanoseconds
                    }
                if blankRoot || unlocatableSuccessor {
                    guard !roots.values.contains(where: {
                        ($0.lifecycleEvent?.timestampNanoseconds ?? 0) >= event.timestampNanoseconds
                    }) else { continue }
                    let bindings = threadRoutes.mapValues(\.binding)
                    let cleared = await runtime.clearConversations(providerID: providerID, binding: binding,
                        timestampNanoseconds: event.timestampNanoseconds)
                    for id in cleared { await retirePlatformRoute(id, matching: bindings[id]) }
                }
            }

            guard let event,
                  !event.providerSessionID.isEmpty,
                  let threadID = AgentThreadID(
                      hostID: route.hostID,
                      providerID: providerID,
                      providerSessionID: event.providerSessionID
                  ) else {
                if let candidateID = AgentSourceCandidateID(
                    hostID: route.hostID,
                    providerID: providerID,
                    sourceIdentity: sourceIdentity
                ) {
                    seenCandidateIDs.insert(candidateID)
                }
                await registerCandidate(
                    target,
                    provider: provider,
                    providerID: providerID,
                    hostID: route.hostID,
                    route: threadRoute
                )
                guard !Task.isCancelled,
                      isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID)
                else { return false }
                continue
            }
            guard let envelope else { continue }
            lifecycleArrivalGeneration &+= 1
            let availability = availability(
                provider: provider,
                lifecycle: event,
                binding: binding,
                source: route.source
            )
            let summary = AgentThreadSummary(
                id: threadID,
                title: event.agentType?.isEmpty == false ? event.agentType! : provider.displayName,
                providerName: provider.displayName,
                hostDisplayLabel: route.hostDisplayLabel.isEmpty ? target.location.hostName : route.hostDisplayLabel,
                permissionMode: permissionMode(event.permissionMode),
                status: providerID == .codex && event.event == "PermissionRequest" ? .working : coreStatus(event.state, event: event.event),
                attention: providerID == .codex && event.event == "PermissionRequest" ? .none : attention(event),
                lastActivitySequence: arrivalSequence,
                lastActivity: event.timestamp,
                preview: Self.rowPreview(for: target, provider: provider),
                isFork: event.rootAgentID?.isEmpty == false,
                availability: availability
            )
            if let current = await runtime.snapshot(for: threadID)?.binding,
               !AgentCenterRuntime.sameProcess(current, binding),
               !AgentCenterRuntime.competesForLiveRoute(held: current, incoming: binding) {
                await runtime.replaceBinding(nil, for: threadID)
            }
            var registration = await runtime.register(summary, binding: binding)
            if case .liveElsewhere = registration {
                _ = await reconcileOccupancy(route: route)
                guard !Task.isCancelled,
                      isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID)
                else { return false }
                registration = await runtime.register(summary, binding: binding)
                if case .liveElsewhere = registration {
                    DiagnosticLogStore.appendAgentCenter(
                        "lifecycle-conflict sid=\(sessionID.uuidString.prefix(8)) pane=\(target.location.paneID.map(String.init) ?? "raw") result=kept"
                    )
                    continue
                }
            }
            guard !Task.isCancelled,
                  isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID)
            else { return false }
            do {
                let previousBindings = threadRoutes.mapValues(\.binding)
                let proof = AgentLifecycleBindingProof(
                    hostID: route.hostID,
                    binding: binding,
                    sourceIdentity: sourceIdentity,
                    processIDs: target.processIDs
                )
                let acceptance = await runtime.applyLifecycle(
                    envelope,
                    proof: proof,
                    expectedSourceIdentity: sourceIdentity
                )
                guard !Task.isCancelled,
                      isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID) else { return false }
                // The conversation this frame replaced on its pane (`/clear`)
                // left Core; the presentation drops it, and a reader on it
                // follows the pane to the conversation that holds it now.
                let replaced = await runtime.takeReplacedConversations()
                for (old, successor) in replaced {
                    await retirePlatformRoute(old, matching: previousBindings[old])
                    await bridge.refresh(old, refreshList: false, successor: successor)
                }
                let pane = target.location.paneID.map(String.init) ?? "raw"
                if case .rejected(let reason) = acceptance {
                    noteLifecycleOutcome(sessionID, pane: pane, frame: event.timestampNanoseconds,
                        "lifecycle-rejected sid=\(sessionID.uuidString.prefix(8)) pane=\(pane) provider=\(providerID.rawValue) event=\(event.event) reason=\(reason.rawValue) proven=\(provenAgentPID != nil)")
                } else if event.event == "PermissionRequest" || event.event == "Notification" {
                    noteLifecycleOutcome(sessionID, pane: pane, frame: event.timestampNanoseconds,
                        "lifecycle-accepted sid=\(sessionID.uuidString.prefix(8)) pane=\(pane) provider=\(providerID.rawValue) event=\(event.event) proven=\(provenAgentPID != nil)")
                }
                guard case .accepted = acceptance else {
                    if provenAgentPID == nil { scheduleLivenessSweep(sessionID: sessionID) }
                    if await runtime.snapshot(for: threadID)?.binding != threadRoutes[threadID]?.binding {
                        await runtime.replaceBinding(nil, for: threadID)
                        await retirePlatformRoute(threadID, matching: threadRoutes[threadID]?.binding)
                    }
                    await bridge.refresh(threadID, refreshList: false)
                    continue
                }
                if event.event == "SessionEnd" || event.event == "WrapperExit" {
                    scheduleLivenessSweep(sessionID: sessionID)
                }
            }
            guard !Task.isCancelled,
                  isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID),
                  await runtime.snapshot(for: threadID)?.binding == binding else { return false }
            seenThreadIDs.insert(threadID)
            if let previous = threadRoutes[threadID],
               previous.binding != binding || previous.registrationID != threadRoute.registrationID
                   || previous.lifecycleEvent?.transcriptRef != event.transcriptRef {
                cancelLivePromptWatch(threadID)
                clearNativeReadFailure(threadID)
                initialProjectionRoutes.removeValue(forKey: threadID)
                if projectionRoutes[threadID] == nil {
                    projectionTasks.removeValue(forKey: threadID)?.cancel()
                    projectionTaskIDs.removeValue(forKey: threadID)
                    pendingProjectionRefreshes.remove(threadID)
                    presentation.loadingTranscriptThreads.remove(threadID)
                }
            }
            // Only an accepted frame for this same first-read source renews
            // its bounded retry budget. Other failures still require their
            // existing recovery, and ordinary refreshes cannot renew it.
            if projectionRoutes[threadID] == nil, provenAgentPID != nil,
               lifecycle != nil || threadRoutes[threadID]?.lifecycleEvent != event,
               presentation.ingestionReadStatuses[threadID]?.code == "sourceMissing",
               presentation.threadSnapshots[threadID]?.messages.isEmpty != false,
               let transcriptRef = event.transcriptRef,
               initialProjectionRoutes[threadID]?.matchesInventorySource(transcriptRef: transcriptRef,
                   binding: binding, registrationID: route.source.registrationID) == true {
                clearNativeReadFailure(threadID)
            }
            threadRoutes[threadID] = threadRoute
            historicalRoutes.removeValue(forKey: threadID)
            terminalAdapters[threadID] = makeTerminalAdapter(threadID: threadID, session: route, thread: threadRoute)
            livePromptLifecycleSequences[threadID] = arrivalSequence
            livePromptFrameTimes[threadID] = .now
            // A candidate's process set changes before its PID is named.
            for (candidateID, candidate) in candidateRoutes
            where candidate.registrationID == route.source.registrationID
                && candidate.location.sessionID == target.location.sessionID && candidate.location.paneID == target.location.paneID {
                candidateRoutes.removeValue(forKey: candidateID)
                await runtime.removeCandidate(candidateID)
            }
            startLivePromptWatch(threadID)
            guard !Task.isCancelled,
                  isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID),
                  threadRoutes[threadID]?.binding == binding
            else { return false }
            await bridge.refresh(threadID, refreshList: false)
            await synchronizePresentation()
            publishSwipePadEvidence(for: sessionID)
            if presentation.threadSnapshots[threadID]?.summary.attention == AgentAttention.none {
                await invalidateAttentionIfPresent(for: threadID)
            } else {
                await scheduleAttentionIfNeeded(for: threadID)
            }
            // Bootstrap metadata once. The visible transcript owns its
            // periodic refresh; output discovery must not continuously scan
            // every agent's entire remote transcript in the background.
            if applicationActive, hasSurfaceDemand, projectionRoutes[threadID] == nil,
               let transcriptRef = event.transcriptRef {
                project(
                    transcriptRef: transcriptRef,
                    providerID: providerID,
                    threadID: threadID,
                    binding: binding,
                    source: route.source,
                    cursor: nil
                )
            }
            if hasSurfaceDemand { startInventory(sessionID: sessionID) }
        }
        await retireAbsentRoutes(
            registrationID: route.source.registrationID,
            scope: scope,
            seenThreadIDs: seenThreadIDs,
            seenCandidateIDs: seenCandidateIDs
        )
        await synchronizePresentation()
        publishSwipePadEvidence(for: sessionID)
        await resolvePendingNotificationRoutes()
        return false
    }

    private func isKnownForeign(_ pid: Int, at place: AgentInstanceID) -> Bool {
        (foreignLifecyclePIDs[place]?[pid]).map { $0 > Date() } ?? false
    }

    /// The newest route whose proven agent still runs in `target`'s pane.
    /// Matched by place and process, not by the whole location: a tmux
    /// window renames itself after its active command.
    private func paneHolder(of target: AgentProbeTarget, registrationID: UUID) -> AppleAgentThreadRoute? {
        threadRoutes.values.filter { held in
            held.registrationID == registrationID
                && held.location.sessionID == target.location.sessionID && held.location.paneID == target.location.paneID
                && (held.binding.agentPID.map(target.processIDs.contains) ?? false)
        }.max { ($0.lifecycleEvent?.timestampNanoseconds ?? 0) < ($1.lifecycleEvent?.timestampNanoseconds ?? 0) }
    }

    private func reconcileOccupancy(route: AppleAgentSessionRoute) async -> Bool {
        let sessionID = route.source.sessionID
        guard applicationActive,
              isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID),
              let observeOccupancy = route.source.observeOccupancy else { return false }
        let live = threadRoutes.filter {
            $0.value.registrationID == route.source.registrationID && $0.value.location.sessionID == sessionID
                && $0.value.binding.agentPID != nil
        }
        let bindings = live.mapValues(\.binding)
        guard !bindings.isEmpty else { return false }
        let observed = await observeOccupancy(Array(bindings.values))
        guard let observed,
              !Task.isCancelled, applicationActive,
              isSessionRegistrationCurrent(sessionID, registrationID: route.source.registrationID),
              threadRoutes.filter({
                  $0.value.registrationID == route.source.registrationID && $0.value.location.sessionID == sessionID
                      && $0.value.binding.agentPID != nil
              }).mapValues(\.binding) == bindings else {
            noteOccupancyOutcome(sessionID, observed == nil ? "unobserved" : "superseded")
            return false
        }
        var contexts: [AgentTerminalBinding] = []
        for binding in bindings.values where !contexts.contains(where: {
            $0.transport == binding.transport && $0.tmuxSession == binding.tmuxSession
        }) { contexts.append(binding) }
        var didRetire = false
        var retiredCount = 0
        var heldCount = 0
        for context in contexts {
            let observation = AgentOccupancyObservation(hostID: route.hostID, liveSessionID: sessionID,
                carrierGeneration: route.carrierGeneration, transport: context.transport,
                tmuxSession: context.tmuxSession, panes: observed.panes, allPaneIDs: observed.allPaneIDs)
            // Routes the observation proves absent that Core declines to
            // retire hold a binding Core no longer treats as live.
            let provedAbsent = Set(AgentOccupancyPolicy.retirements(live: bindings.map { ($0.key, $0.value) },
                observation: observation))
            let retired = await runtime.reconcileOccupancy(observation)
            for id in retired { await retirePlatformRoute(id, matching: bindings[id]) }
            didRetire = didRetire || !retired.isEmpty
            retiredCount += retired.count
            heldCount += provedAbsent.subtracting(retired).count
        }
        let staleCarrier = bindings.values.filter { $0.carrierGeneration != route.carrierGeneration }.count
        noteOccupancyOutcome(sessionID,
            "observed retired=\(retiredCount) held=\(heldCount) staleCarrier=\(staleCarrier) contexts=\(contexts.count)")
        return didRetire
    }

    /// Every discovery pass re-reads a pane's retained frame; log each frame's
    /// admission once.
    private func noteLifecycleOutcome(_ sessionID: UUID, pane: String, frame: UInt64, _ line: String) {
        let key = "\(sessionID.uuidString):\(pane)"
        let outcome = "\(frame) \(line)"
        guard lifecycleDiagnosticOutcomes[key] != outcome else { return }
        lifecycleDiagnosticOutcomes[key] = outcome
        DiagnosticLogStore.appendAgentCenter(line)
    }

    private func noteOccupancyOutcome(_ sessionID: UUID, _ outcome: String) {
        guard occupancyDiagnosticOutcomes[sessionID] != outcome else { return }
        occupancyDiagnosticOutcomes[sessionID] = outcome
        DiagnosticLogStore.appendAgentCenter("occupancy-reconcile sid=\(sessionID.uuidString.prefix(8)) result=\(outcome)")
    }

    private func retirePlatformRoute(_ threadID: AgentThreadID, matching binding: AgentTerminalBinding?) async {
        guard let route = threadRoutes[threadID], route.binding == binding else { return }
        let place = AgentInstanceID(sessionID: route.location.sessionID, paneID: route.location.paneID)
        lastLifecycleDeliveries.removeValue(forKey: place)
        foreignLifecyclePIDs.removeValue(forKey: place)
        cancelInitialPrefetch(threadID)
        clearNativeReadFailure(threadID)
        threadRoutes.removeValue(forKey: threadID)
        terminalAdapters.removeValue(forKey: threadID)
        projectionTasks.removeValue(forKey: threadID)?.cancel()
        cancelLivePromptWatch(threadID)
        presentation.loadingTranscriptThreads.remove(threadID)
        projectionTaskIDs.removeValue(forKey: threadID)
        pendingProjectionRefreshes.remove(threadID)
        pendingHistoryRequests.remove(threadID)
        pendingFillRequests.remove(threadID)
        pendingLatestRequests.remove(threadID)
        outgoingReceiptLeases.removeValue(forKey: threadID)
        projectionRoutes.removeValue(forKey: threadID)
        initialProjectionRoutes.removeValue(forKey: threadID)
        await invalidateAttentionIfPresent(for: threadID)
        await bridge.refresh(threadID, refreshList: false)
    }

    /// Successful discovery is authoritative for the scope it was asked to
    /// inspect. Remove only absent live routes/candidates from that scope;
    /// historic inventory remains read-only and is intentionally untouched.
    private func retireAbsentRoutes(
        registrationID: UUID,
        scope: AgentCenterV2DiscoveryScope,
        seenThreadIDs: Set<AgentThreadID>,
        seenCandidateIDs: Set<AgentSourceCandidateID>,
        refreshLaunchSuggestions: Bool = true
    ) async {
        let liveLocations = Dictionary(uniqueKeysWithValues: threadRoutes.compactMap { id, route in
            route.registrationID == registrationID && route.binding.agentPID == nil ? (id, route.location) : nil
        })
        let absentThreads = scope.absentRouteIDs(
            locations: liveLocations,
            seenIDs: seenThreadIDs
        )
        // tmux announces a retired place's unchanged option again when it
        // returns (a reattach, `fg`); that announcement must buy a pass.
        let retiredPlaces = absentThreads.compactMap { liveLocations[$0] }.map {
            AgentInstanceID(sessionID: $0.sessionID, paneID: $0.paneID)
        }
        for place in retiredPlaces {
            lastLifecycleDeliveries.removeValue(forKey: place)
            // Judged against the agent that held the place, now gone.
            foreignLifecyclePIDs.removeValue(forKey: place)
        }
        for threadID in absentThreads {
            let binding = threadRoutes[threadID]?.binding
            await runtime.replaceBinding(nil, for: threadID)
            await retirePlatformRoute(threadID, matching: binding)
        }

        let candidateLocations = Dictionary(uniqueKeysWithValues: candidateRoutes.compactMap { id, route in
            route.registrationID == registrationID ? (id, route.location) : nil
        })
        let absentCandidates = scope.absentRouteIDs(
            locations: candidateLocations,
            seenIDs: seenCandidateIDs
        )
        for candidateID in absentCandidates {
            if let location = candidateLocations[candidateID] {
                lastLifecycleDeliveries.removeValue(forKey: AgentInstanceID(sessionID: location.sessionID, paneID: location.paneID))
            }
            candidateRoutes.removeValue(forKey: candidateID)
            await bridge.removeCandidate(candidateID)
        }
        if !absentThreads.isEmpty || !absentCandidates.isEmpty {
            publishSwipePadEvidence(for: scope.sessionID)
            await synchronizePresentation(refreshLaunchSuggestions: refreshLaunchSuggestions)
        }
    }

    /// Keeps each retired conversation's newest proven frame for the
    /// connection that replaces its tmux pane's carrier.
    private func rememberRetiredPaneHolder(_ route: AppleAgentThreadRoute, hostID: UUID) {
        guard let paneID = route.location.paneID,
              let pid = route.binding.agentPID,
              let event = route.lifecycleEvent, event.agentPID == pid else { return }
        let key = AppleAgentRetiredPaneHolder.Key(hostID: hostID, paneID: paneID,
            provider: event.provider, providerSessionID: event.providerSessionID)
        if let previous = retiredPaneHolders[key],
           previous.lifecycleEvent.timestampNanoseconds >= event.timestampNanoseconds { return }
        retiredPaneHolders[key] = AppleAgentRetiredPaneHolder(lifecycleEvent: event, agentPID: pid, retiredAt: Date())
        if retiredPaneHolders.count > AppleAgentRetiredPaneHolder.limit,
           let oldest = retiredPaneHolders.min(by: { $0.value.retiredAt < $1.value.retiredAt })?.key {
            retiredPaneHolders.removeValue(forKey: oldest)
        }
    }

    private func retireRoutes(forRegistrationID registrationID: UUID, rememberingHostID hostID: UUID? = nil) {
        let removed = threadRoutes.filter { $0.value.registrationID == registrationID }.map(\.key)
        for threadID in removed {
            if let hostID, let route = threadRoutes[threadID] {
                rememberRetiredPaneHolder(route, hostID: hostID)
            }
            cancelInitialPrefetch(threadID)
            clearNativeReadFailure(threadID)
            threadRoutes.removeValue(forKey: threadID)
            terminalAdapters.removeValue(forKey: threadID)
            projectionTasks.removeValue(forKey: threadID)?.cancel()
            cancelLivePromptWatch(threadID)
            if presentation.loadingTranscriptThreads.contains(threadID) { presentation.loadingTranscriptThreads.remove(threadID) }
            projectionTaskIDs.removeValue(forKey: threadID)
            pendingProjectionRefreshes.remove(threadID)
            pendingHistoryRequests.remove(threadID)
            pendingFillRequests.remove(threadID)
            pendingLatestRequests.remove(threadID)
            outgoingReceiptLeases.removeValue(forKey: threadID)
            projectionRoutes.removeValue(forKey: threadID)
            initialProjectionRoutes.removeValue(forKey: threadID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A replacement source can rediscover the same stable thread
                // before this cleanup task runs. Never let the retired source
                // clear a binding already owned by that newer registration.
                guard self.threadRoutes[threadID] == nil else { return }
                await self.invalidateAttentionIfPresent(for: threadID)
                // The replacement may have restored the thread meanwhile.
                guard self.threadRoutes[threadID] == nil else { return }
                await self.replaceBinding(nil, terminal: nil, for: threadID)
            }
        }
        let removedCandidates = candidateRoutes.filter {
            $0.value.registrationID == registrationID
        }.map(\.key)
        for candidateID in removedCandidates {
            candidateRoutes.removeValue(forKey: candidateID)
            Task { @MainActor [weak self] in
                guard let self, self.candidateRoutes[candidateID] == nil else { return }
                await self.bridge.removeCandidate(candidateID)
            }
        }
    }

    func makeTerminalAdapter(
        threadID: AgentThreadID,
        session: AppleAgentSessionRoute,
        thread: AppleAgentThreadRoute
    ) -> AppleAgentTerminalAdapter {
        let source = session.source
        let location = thread.location
        let profile = thread.profile
        let binding = thread.binding
        let registrationID = thread.registrationID
        let operations = AppleAgentTerminalOperations(
            inspect: { [weak self] expected in
                guard let self,
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID)
                else { throw AgentActionError.staleBinding }
                // No settled frame (tmux moved the cursor mid-capture, a redraw
                // was in flight, or a process probe missed). Callers may retry.
                guard let target = await source.inspectInputTarget(location, expected.agentPID) else { throw AppleAgentInspectionUnavailable.capture }
                guard self.isCurrent(expected, threadID: threadID, registrationID: registrationID),
                      self.target(target, stillMatches: profile, binding: expected),
                      expected.agentPID.map(target.processIDs.contains) ?? true
                else { throw AgentActionError.staleBinding }
                let parsed = target.visibleText.flatMap { visible in
                    AgentPromptObservationRequest(providerID: threadID.providerID,
                        visibleText: AppleAgentPromptCapture.bottomWholeRows(visible),
                        currentCursorLine: target.currentInputLine.map { AppleAgentPromptCapture.utf8Prefix($0, limit: 2_048) })
                }.flatMap(AgentPromptGrammar.observe)
                return AppleAgentTerminalInspection(
                    observation: AgentTerminalObservation(
                        binding: expected,
                        liveTail: target.visibleText ?? "",
                        prompt: parsed.flatMap { observed in
                            AgentAuthoritativePrompt(signature: observed.signature,
                                options: observed.options.map {
                                    TesseraCore.AgentPromptOption(id: $0.id, label: $0.label, isDefault: $0.isDefault)
                                }, cursorOwned: true, visiblyBlocking: observed.blocksComposer)
                        }
                    ),
                    promptScreen: parsed,
                    composerText: target.currentInputLine,
                    queueSupported: true,
                    composerRow: target.cursorRow,
                    composerColumn: target.cursorColumn,
                    composerVisibleText: target.visibleText,
                    composerCursorVisible: target.cursorVisible,
                    screenEvidence: target.screenEvidence,
                    bracketedPasteEnabled: target.bracketedPasteEnabled
                )
            },
            sendText: { [weak self] data, purpose, expected, inspection in
                // Both refusals precede the first byte; only `send` itself is
                // ambiguous.
                guard let self,
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID),
                      expected.capabilities.contains(purpose == .promptAnswer ? .promptAnswer : .send),
                      expected.agentPID != nil,
                      inspection.observation.binding == expected
                else { throw AppleAgentSendNotWritten(error: .staleBinding, reason: "route", attempts: 0, shape: nil) }
                // An end accepted while this action awaited its inspection
                // revokes it: the process may already run the next conversation.
                guard !self.conversationEnded(threadID)
                else { throw AppleAgentSendNotWritten(error: .staleBinding, reason: "conversation-ended", attempts: 0, shape: nil) }
                guard let bytes = AppleAgentTerminalInputPolicy.bytes(data, purpose: purpose, provider: threadID.providerID.rawValue,
                        bracketedPasteEnabled: inspection.bracketedPasteEnabled)
                else { throw AppleAgentSendNotWritten(error: .unavailable, reason: "input-policy", attempts: 0, shape: nil) }
                // Checked just before `send`; a refusal `send` still makes
                // after this check stays ambiguous, the safe direction.
                if let refusal = source.sendRefusal?(location, Array(bytes)) {
                    throw AppleAgentSendNotWritten(error: refusal == "empty" ? .unavailable : .staleBinding,
                        reason: "transport-\(refusal)", attempts: 0, shape: nil)
                }
                return await source.send(location, Array(bytes))
            },
            sendKey: { [weak self] key, expected, inspection in
                guard let self,
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID),
                      !self.conversationEnded(threadID),
                      (key == .escape
                        ? expected.capabilities.contains(.interrupt)
                        : expected.capabilities.contains(.send)),
                      expected.agentPID != nil,
                      inspection.observation.binding == expected
                else { return false }
                // The acknowledged byte path delivers Tab to the exact raw
                // or tmux carrier; it does not enter bracketed paste mode.
                if key == .tab { return await source.send(location, [0x09]) }
                if let semantic = source.sendKey {
                    return await semantic(location, key == .return ? .enter : .escape)
                }
                return await source.send(location, key == .return ? [0x0D] : [0x1B])
            },
            verifySubmission: { [weak self] _, submittedText, expected in
                guard let self,
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID),
                      let fresh = await source.inspectInputTarget(location, expected.agentPID),
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID),
                      fresh.location == location,
                      expected == binding,
                      self.target(fresh, stillMatches: profile, binding: expected),
                      expected.agentPID.map(fresh.processIDs.contains) ?? false,
                      let cursor = fresh.currentInputLine,
                      let visible = fresh.visibleText
                else { return false }
                // Return is confirmed only after the exact pane/raw cursor no
                // longer owns the inserted composer payload. Echoed transcript
                // text may remain in the terminal body and is not used here.
                return AgentComposerEvidence.presence(provider: threadID.providerID.rawValue,
                    visibleText: visible, cursorLine: cursor, text: submittedText, cursorRow: fresh.cursorRow) == .absent
            },
            openExactBinding: { [weak self] expected in
                // The adapter proved this pane moments ago. A capture that
                // races a redraw is retried briefly, not read as a new pane.
                var fresh: AgentProbeTarget?
                for attempt in 0..<3 where fresh == nil {
                    if attempt > 0 { try await Task.sleep(for: .milliseconds(150)) }
                    guard let self, self.isCurrent(expected, threadID: threadID, registrationID: registrationID) else { return .staleBinding }
                    fresh = await source.inspectInputTarget(location, expected.agentPID)
                }
                guard let self,
                      self.isCurrent(expected, threadID: threadID, registrationID: registrationID)
                else { return .staleBinding }
                guard let fresh else { return .inputNotReady }
                guard self.target(fresh, stillMatches: profile, binding: expected),
                      expected.agentPID.map(fresh.processIDs.contains) ?? true
                else { return .staleBinding }
                source.jump(location)
                return .opened
            }
        )
        return AppleAgentTerminalAdapter(binding: binding, operations: operations)
    }

    /// Cold notification routing must not trust a cached presentation binding.
    /// Re-inspect the exact owner route so a queued tap cannot select a pane
    /// which was replaced, moved, or lost while the app was suspended.
    func currentBindingIsProven(
        threadID: AgentThreadID,
        binding: AgentTerminalBinding
    ) async -> Bool {
        guard let route = threadRoutes[threadID],
              route.binding == binding,
              let session = sessionRoutes[binding.liveSessionID],
              session.source.registrationID == route.registrationID,
              let fresh = await session.source.inspectInputTarget(route.location, route.binding.agentPID),
              isCurrent(binding, threadID: threadID, registrationID: route.registrationID)
        else { return false }
        return target(fresh, stillMatches: route.profile, binding: binding)
            && (binding.agentPID.map(fresh.processIDs.contains) ?? true)
    }

    private func project(
        transcriptRef: String,
        providerID: AgentProviderID,
        threadID: AgentThreadID,
        binding: AgentTerminalBinding,
        source: AgentSessionSource,
        cursor: String?, nativeDirection: String = "before"
    ) {
        guard AgentCenterV2ReadPolicy.allows(
            isEnabled: isEnabled,
            applicationActive: applicationActive,
            hasSurfaceDemand: hasSurfaceDemand
        ), !ingestionManualReadThreads.contains(threadID), ingestionReadRetryTasks[threadID] == nil else { return }
        if cursor == nil, nativeDirection != "bootstrap", initialPrefetchTasks[threadID]?.isCancelled == false { return }
        // A newest-page refresh must let its bounded in-flight read finish.
        // Source retirement cancels the old task separately; repeatedly
        // replacing it on terminal output can otherwise starve projection.
        if projectionTasks[threadID] != nil || outgoingReceiptLeases[threadID] != nil {
            if nativeDirection == "bootstrap" { pendingLatestRequests.insert(threadID) }
            else if cursor == nil { pendingProjectionRefreshes.insert(threadID) }
            else if nativeDirection == "before" { pendingHistoryRequests.insert(threadID) }
            return
        }
        pendingProjectionRefreshes.remove(threadID)
        if cursor == nil, projectionRoutes[threadID] == nil, historicalRoutes[threadID] == nil {
            initialProjectionRoutes[threadID] = AppleAgentProjectionRoute(transcriptRef: transcriptRef,
                providerID: providerID, binding: binding, source: source)
        }
        let cancelledPrefetch = cancelInitialPrefetch(threadID)
        projectionTasks[threadID]?.cancel()
        let registrationID = source.registrationID
        let taskID = UUID()
        projectionTaskIDs[threadID] = taskID
        if cursor != nil || presentation.threadSnapshots[threadID]?.messages.isEmpty != false {
            if !presentation.loadingTranscriptThreads.contains(threadID) { presentation.loadingTranscriptThreads.insert(threadID) }
        }
        projectionTasks[threadID] = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = Date()
            defer {
                self.performanceDiagnostics.record(cursor == nil ? "refresh" : "history", since: started)
                if AgentCenterV2TaskOwnership.owns(
                    currentTaskID: self.projectionTaskIDs[threadID], taskID: taskID
                ) {
                    self.projectionTasks.removeValue(forKey: threadID)
                    self.projectionTaskIDs.removeValue(forKey: threadID)
                    if self.presentation.loadingTranscriptThreads.contains(threadID) { self.presentation.loadingTranscriptThreads.remove(threadID) }
                    if self.pendingLatestRequests.remove(threadID) != nil, !Task.isCancelled {
                        self.pendingHistoryRequests.remove(threadID)
                        self.pendingProjectionRefreshes.remove(threadID)
                        self.requestNewerPage(threadID, latest: true)
                    } else if self.pendingHistoryRequests.remove(threadID) != nil, !Task.isCancelled {
                        self.requestOlderPage(threadID)
                    } else if self.pendingProjectionRefreshes.remove(threadID) != nil, !Task.isCancelled {
                        self.project(
                            transcriptRef: transcriptRef, providerID: providerID,
                            threadID: threadID, binding: binding, source: source, cursor: nil
                        )
                    } else if self.pendingFillRequests.remove(threadID) != nil, !Task.isCancelled {
                        self.requestOlderPage(threadID, fill: true)
                    }
                }
            }
            let isCurrent: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { [weak self] candidate in
                self?.isProjectionEndpointCurrent(
                    candidate,
                    threadID: threadID,
                    registrationID: registrationID
                ) == true
            }
            // Wait only for canceled optional work to release its local window
            // ownership. Its unanswered read is canceled independently.
            await cancelledPrefetch?.value
            guard !Task.isCancelled else { return }
            guard case .available(let factory) = source.projectorExecAvailability(binding, isCurrent) else { return }
            do {
                if [.codex, .claude, .pi, .opencode, .kimi].contains(providerID) {
                    try await self.projectNative(transcriptRef: transcriptRef, providerID: providerID,
                        threadID: threadID, binding: binding, source: source, cursor: cursor, direction: nativeDirection)
                    if cursor == nil,
                       let route = self.projectionRoutes[threadID],
                       let connection = self.ingestionHosts[AppleAgentIngestionHostKey(sessionID: source.sessionID, binding: binding)]?.connection {
                        self.scheduleInitialPrefetch(threadID: threadID, route: route, nativeConnection: connection)
                    }
                    return
                }
                let exec = AppleAgentStreamingExecPort(binding: binding, factory: factory)
                let endpoint = AppleAgentProjectionEndpoint.projector(exec: exec, searchThreadID: threadID)
                let channel = AppleAgentRemoteDataChannel(binding: binding, endpoint: endpoint)
                let initialSnapshot = await self.runtime.snapshot(for: threadID)
                let isInitial = cursor == nil && initialSnapshot?.cursor == nil
                    && initialSnapshot?.messages.isEmpty != false
                guard !Task.isCancelled,
                      let request = AgentProjectionRequest(kind: .project, providerID: providerID,
                        transcriptRef: transcriptRef, cursor: cursor,
                        limitBytes: AgentProjectionRequest.maximumBytes,
                        limitRecords: AgentProjectionRequest.maximumRecords,
                        continuationCursor: cursor == nil ? initialSnapshot?.cursor : nil) else { return }
                for try await page in try await channel.project(request) {
                    guard !Task.isCancelled,
                          self.isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: registrationID),
                          self.projectionTaskIDs[threadID] == taskID else { return }
                    guard await self.apply(page: page, to: threadID).accepted else { return }
                    guard !Task.isCancelled,
                          self.isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: registrationID),
                          self.projectionTaskIDs[threadID] == taskID else { return }
                    // A read route is published only by an accepted page on a
                    // current endpoint; a retired or superseded projector must
                    // not become the route later navigation reuses.
                    let route = AppleAgentProjectionRoute(transcriptRef: transcriptRef, providerID: providerID,
                        binding: binding, source: source)
                    self.projectionRoutes[threadID] = route
                    if isInitial, page.hasMore, page.cursor != cursor {
                        self.scheduleInitialPrefetch(threadID: threadID, route: route)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: registrationID),
                      self.projectionTaskIDs[threadID] == taskID else { return }
                // Before a first page lands no thread handle exists for the
                // connection's typed recovery to act on, so a first read that
                // raced a transcript replacement, an interrupted read or a
                // renewed connection retries here, bounded, as a missing source does.
                let sourceMissing = error as? AgentIngestionError == .remote("sourceMissing")
                let recoverable = sourceMissing || error as? AgentProjectionError == .sourceChanged
                    || self.presentation.ingestionReadStatuses[threadID].map {
                        [.retryRead, .rebootstrap, .renewConnection].contains($0.recovery)
                    } == true
                if let route = self.initialProjectionRoutes[threadID], recoverable {
                    if sourceMissing, self.presentation.ingestionReadStatuses[threadID] == nil {
                        self.presentation.ingestionReadStatuses[threadID] = try? AgentIngestionReadStatus.decode(.object([
                            "v": .number(1), "state": .string("failed"), "domain": .string("source"),
                            "recovery": .string("manual"), "code": .string("sourceMissing")]))
                    }
                    self.scheduleInitialProjectionRetry(threadID, route: route)
                } else if self.initialProjectionRoutes[threadID] != nil,
                          self.presentation.ingestionReadStatuses[threadID]?.recovery == .manual {
                    self.ingestionManualReadThreads.insert(threadID)
                }
                if self.presentation.ingestionReadStatuses[threadID]?.recovery == .retryRead {
                    self.ingestionRetryPageRequests[threadID] = (cursor, nativeDirection)
                }
                DiagnosticLogStore.appendAgentCenter(
                    "v2-project result=failed provider=\(providerID.rawValue) older=\(cursor != nil) reason=\(Self.projectionFailureReason(error))"
                )
                if cursor != nil, error as? AgentProjectionError == .sourceChanged {
                    self.pendingProjectionRefreshes.insert(threadID)
                }
            }
        }
    }

    func startInventory(sessionID: UUID) {
        guard AgentCenterV2ReadPolicy.allows(
            isEnabled: isEnabled,
            applicationActive: applicationActive,
            hasSurfaceDemand: hasSurfaceDemand
        ),
              let session = sessionRoutes[sessionID] else { return }
        // A session can move into or out of tmux after registration. Refresh
        // the read-only carrier at demand time; it remains deliberately
        // distinct from a pane-authorized action binding.
        if let refreshedCarrier = session.source.readCarrier?() {
            sessionReadCarriers[sessionID] = refreshedCarrier
        }
        let carrier = threadRoutes.values.first(where: {
            $0.registrationID == session.source.registrationID
        })?.binding ?? sessionReadCarriers[sessionID]
        guard let carrier else { return }
        // Tier-C providers must be asked to prove themselves. Their fixed
        // projector routes fail closed when the CLI, schema, hook install, or
        // RPC wire does not match; only a clean completed inventory enables
        // the manifest for this authenticated session.
        startNativeInventory(sessionID: sessionID)
        let providers = AgentProviderRegistry.builtIn.allManifests.filter { ![.custom, .codex, .claude, .pi, .opencode, .kimi].contains($0.id) }
        for provider in providers {
            let taskKey = "\(sessionID.uuidString):\(provider.id.rawValue)"
            guard inventoryTasks[taskKey]?.isCancelled != false else { continue }
            // Terminal output can arrive continuously; a completed or missing
            // provider inventory is not a reason to probe the host per frame.
            guard inventoryRetryAfter[taskKey].map({ $0 <= Date() }) ?? true else { continue }
            inventoryRetryAfter[taskKey] = Date().addingTimeInterval(10)
            let taskID = UUID()
            inventoryTaskIDs[taskKey] = taskID
            inventoryTasks[taskKey] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if AgentCenterV2TaskOwnership.owns(
                        currentTaskID: self.inventoryTaskIDs[taskKey], taskID: taskID
                    ) {
                        self.inventoryTasks.removeValue(forKey: taskKey)
                        self.inventoryTaskIDs.removeValue(forKey: taskKey)
                    }
                }
                let binding = carrier
                let isCurrent: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { [weak self] candidate in
                    guard let self, candidate == binding else { return false }
                    if self.threadRoutes.values.contains(where: {
                        $0.registrationID == session.source.registrationID && $0.binding == binding
                    }) {
                        return self.isLiveRouteCurrent(binding, registrationID: session.source.registrationID)
                    }
                    return self.isSessionReadCarrierCurrent(binding, registrationID: session.source.registrationID)
                }
                guard case .available(let factory) = session.source.projectorExecAvailability(binding, isCurrent) else { return }
                do {
                    let exec = AppleAgentStreamingExecPort(binding: binding, factory: factory)
                    let endpoint = AppleAgentProjectionEndpoint.projector(exec: exec)
                    let channel = AppleAgentRemoteDataChannel(binding: binding, endpoint: endpoint)
                    var inventoryCursor: String?
                    var completedInventory = false
                    var inventoryChanged = false
                    var seenCursors = Set<String>()
                    for _ in 0..<32 {
                        guard let request = AgentProjectionRequest(
                            kind: .inventory,
                            providerID: provider.id,
                            cursor: inventoryCursor,
                            limitBytes: AgentProjectionRequest.maximumBytes,
                            limitRecords: AgentProjectionRequest.maximumRecords
                        ) else { throw AppleAgentPlatformError.malformedStreamFrame }
                        let pages = try await channel.inventory(request)
                        var receivedPage = false
                        for try await page in pages {
                            receivedPage = true
                        guard !Task.isCancelled,
                              self.isEnabled,
                              self.applicationActive,
                              self.hasSurfaceDemand,
                              AgentCenterV2TaskOwnership.owns(
                                  currentTaskID: self.inventoryTaskIDs[taskKey], taskID: taskID
                              ),
                              isCurrent(binding)
                        else { return }
                        for record in page.records {
                            guard let object = record.record.objectValue,
                                  let providerSessionID = object["providerSessionID"]?.stringValue,
                                  let transcriptRef = object["transcriptRef"]?.stringValue,
                                  let threadID = AgentThreadID(
                                      hostID: session.hostID,
                                      providerID: provider.id,
                                      providerSessionID: providerSessionID
                                  ) else { continue }
                            let nanos = object["lastActivityNs"]?.numberValue.map {
                                NSDecimalNumber(decimal: $0).uint64Value
                            } ?? 0
                            let activity = nanos > 0
                                ? Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
                                : .distantPast
                            if self.historicalRoutes[threadID]?.matchesInventorySource(
                                transcriptRef: transcriptRef, binding: binding,
                                registrationID: session.source.registrationID
                            ) == true { continue }
                            inventoryChanged = true
                            self.historicalRoutes[threadID] = AppleAgentProjectionRoute(
                                transcriptRef: transcriptRef,
                                providerID: provider.id,
                                binding: binding,
                                source: session.source
                            )
                            guard self.threadRoutes[threadID] == nil else { continue }
                            let summary = AgentThreadSummary(
                                id: threadID,
                                title: "\(provider.displayName) · \(String(providerSessionID.prefix(8)))",
                                providerName: provider.displayName,
                                hostDisplayLabel: session.hostDisplayLabel,
                                status: .unavailable,
                                attention: .none,
                                lastActivitySequence: nanos,
                                lastActivity: activity,
                                preview: nil,
                                availability: .init(
                                    content: true,
                                    status: false,
                                    actions: false,
                                    spawn: false,
                                    fork: false,
                                    search: false,
                                    reason: nil
                                )
                            )
                            await self.register(summary: summary, binding: nil)
                        }
                            if page.hasMore {
                                guard let next = page.cursor,
                                      next != inventoryCursor,
                                      seenCursors.insert(next).inserted else {
                                    throw AppleAgentPlatformError.malformedStreamFrame
                                }
                                inventoryCursor = next
                            } else {
                                completedInventory = true
                            }
                        }
                        guard receivedPage else { throw AppleAgentPlatformError.malformedStreamFrame }
                        if completedInventory { break }
                    }
                    guard completedInventory else { throw AppleAgentPlatformError.boundedPayloadExceeded }
                    if provider.id == .opencode || provider.id == .pi || provider.id == .kimi {
                        await self.markProviderConforming(provider.id, sessionID: sessionID)
                    }
                    await self.synchronizePresentation()
                    if inventoryChanged,
                       !self.presentation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       self.isEnabled,
                       self.applicationActive,
                       self.hasSurfaceDemand,
                       AgentCenterV2TaskOwnership.owns(
                           currentTaskID: self.inventoryTaskIDs[taskKey], taskID: taskID
                       ) {
                        self.scheduleSearch(query: self.presentation.searchQuery)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    DiagnosticLogStore.appendAgentCenter(
                        "v2-inventory result=failed provider=\(provider.id.rawValue) failureType=\(String(describing: type(of: error))) reason=\((error as? AgentProjectionError).map { String(describing: $0) } ?? (error as? AppleAgentPlatformError).map { String(describing: $0) } ?? "transport")"
                    )
                    await self.markProviderNonconforming(provider.id, sessionID: sessionID)
                }
            }
        }
    }

    /// Validate the entire bounded page before reserving any identity. Route
    /// publication is the retry-success marker, so it follows Core acceptance
    /// and the post-await ownership check, never an individual decoded row.
    func applyNativeInventoryPage(
        _ objects: [[String: AgentJSONValue]], host: AppleAgentIngestionHost,
        session: AppleAgentSessionRoute, isCurrent: () -> Bool
    ) async throws -> Bool {
        guard objects.count <= 500 else { throw AgentIngestionError.capacityExceeded }
        guard isCurrent() else { return false }
        var staged: [(AgentThreadID, String, AppleAgentProjectionRoute)] = []
        var summaries: [AgentThreadSummary] = []
        var seen = Set<AgentThreadID>()
        for object in objects {
            guard let rawProvider = object["provider"]?.stringValue,
                  let provider = AgentProviderRegistry.builtIn.allManifests.first(where: { $0.id.rawValue == rawProvider }),
                  [.codex, .claude, .pi, .opencode, .kimi].contains(provider.id),
                  provider.id != .pi || host.connection?.supportsPiSessions == true,
                  provider.id != .opencode || host.connection?.supportsOpenCodeSessions == true,
                  provider.id != .kimi || host.connection?.supportsKimiSessions == true,
                  let sessionID = object["sessionID"]?.stringValue,
                  let handle = object["thread"]?.stringValue, AgentIngestionRange.identifier(handle),
                  let path = object["transcriptRef"]?.stringValue,
                  path.hasPrefix("/") || (path.isEmpty && [.codex, .opencode].contains(provider.id) && object["nativeSessionID"]?.stringValue == sessionID),
                  let thread = AgentThreadID(hostID: session.hostID, providerID: provider.id, providerSessionID: sessionID),
                  seen.insert(thread).inserted else { throw AgentIngestionError.malformedFrame }
            try validateNativeThreadClaim(thread, host: host)
            let locator = path.isEmpty ? "native:" + sessionID : Data(path.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let route = AppleAgentProjectionRoute(transcriptRef: locator, providerID: provider.id,
                binding: host.binding, source: session.source)
            staged.append((thread, handle, route))
            let unchanged = historicalRoutes[thread]?.matchesInventorySource(transcriptRef: locator,
                binding: host.binding, registrationID: host.registrationID) == true
            guard !unchanged, threadRoutes[thread] == nil else { continue }
            let seconds = object["modified"]?.numberValue.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
            // Filesystem time is display metadata, never lifecycle authority.
            summaries.append(AgentThreadSummary(id: thread,
                title: "\(provider.displayName) · \(String(sessionID.prefix(8)))", providerName: provider.displayName,
                hostDisplayLabel: session.hostDisplayLabel, status: .unavailable, attention: .none,
                lastActivity: Date(timeIntervalSince1970: seconds), availability: .init(content: true,
                    status: false, actions: false, spawn: false, fork: false, search: false)))
        }
        // Reserve all claims without suspension so another context cannot win
        // the same identity while Core processes this page.
        try host.reserveHandles(staged.map { ($0.0, $0.1) })
        for (thread, _, _) in staged { host.claimedThreads.insert(thread) }
        for offset in stride(from: 0, to: summaries.count, by: 100) {
            try await bridge.registerInventoryPage(Array(summaries[offset..<min(offset + 100, summaries.count)]))
            guard isCurrent() else { return false }
        }
        guard isCurrent() else { return false }
        for (thread, handle, route) in staged {
            host.threads[thread] = handle
            historicalRoutes[thread] = route
        }
        return true
    }

    func cancelInventoryRetries() {
        inventoryRetryTasks.values.forEach { $0.cancel() }
        inventoryRetryTasks.removeAll()
    }

    /// A quiet shell emits no output after a failed inventory. Keep exactly
    /// one bounded retry per session while its Agent Center surface is visible,
    /// rather than relying on another terminal packet or an app relaunch.
    private func scheduleInventoryRetry(sessionID: UUID, registrationID: UUID) {
        guard inventoryRetryTasks[sessionID] == nil,
              AgentCenterV2ReadPolicy.allows(isEnabled: isEnabled, applicationActive: applicationActive,
                  hasSurfaceDemand: hasSurfaceDemand),
              sessionRoutes[sessionID]?.source.registrationID == registrationID else { return }
        let retryAfter = inventoryRetryAfter["\(sessionID.uuidString):native"] ?? Date().addingTimeInterval(10)
        inventoryRetryTasks[sessionID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, retryAfter.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled,
                  self.sessionRoutes[sessionID]?.source.registrationID == registrationID else { return }
            self.inventoryRetryTasks.removeValue(forKey: sessionID)
            self.startInventory(sessionID: sessionID)
        }
    }

    private func startNativeInventory(sessionID: UUID) {
        guard let session = sessionRoutes[sessionID] else { return }
        let key = "\(sessionID.uuidString):native"
        guard inventoryTasks[key] == nil else { return }
        guard inventoryRetryAfter[key].map({ $0 <= Date() }) ?? true else {
            scheduleInventoryRetry(sessionID: sessionID, registrationID: session.source.registrationID)
            return
        }
        inventoryRetryTasks.removeValue(forKey: sessionID)?.cancel()
        inventoryRetryAfter[key] = Date().addingTimeInterval(10)
        let taskID = UUID()
        inventoryTaskIDs[key] = taskID
        inventoryTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                if self.inventoryTaskIDs[key] == taskID {
                    self.inventoryTasks.removeValue(forKey: key); self.inventoryTaskIDs.removeValue(forKey: key)
                    if !completed, !Task.isCancelled {
                        self.scheduleInventoryRetry(sessionID: sessionID, registrationID: session.source.registrationID)
                    }
                }
            }
            do {
                let (host, connection) = try await self.nativeHost(source: session.source)
                var cursor: String?
                var seen = Set<String>()
                for _ in 0..<164 {
                    var fields: [String: AgentJSONValue] = ["kind": .string("inventory"), "limit": .number(500)]
                    if let cursor { fields["cursor"] = .string(cursor) }
                    let reply = try await connection.request(fields)
                    guard !Task.isCancelled, self.isEnabled, self.applicationActive, self.hasSurfaceDemand,
                          self.inventoryTaskIDs[key] == taskID, self.isNativeHostCurrent(host, sessionID: sessionID),
                          self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID) else { return }
                    let applied = try await self.applyNativeInventoryPage(reply.inventory, host: host, session: session) {
                        !Task.isCancelled && self.isEnabled && self.applicationActive && self.hasSurfaceDemand &&
                        self.inventoryTaskIDs[key] == taskID && self.isNativeHostCurrent(host, sessionID: sessionID) &&
                        self.isSessionReadCarrierCurrent(host.binding, registrationID: host.registrationID)
                    }
                    guard applied else { return }
                    await self.synchronizePresentation()
                    self.scheduleNativeInterests()
                    guard reply.object["hasMore"]?.boolValue == true else { completed = true; return }
                    guard let next = reply.object["cursor"]?.stringValue, seen.insert(next).inserted else {
                        throw AgentIngestionError.malformedFrame
                    }
                    cursor = next
                }
                throw AgentIngestionError.capacityExceeded
            } catch is CancellationError { return }
            catch { DiagnosticLogStore.appendAgentCenter("v2-native-inventory result=failed failureType=\(String(describing: type(of: error))) reason=\(Self.projectionFailureReason(error))") }
        }
    }

    private func providerManifest(
        for providerID: AgentProviderID,
        sessionID: UUID
    ) -> AgentProviderManifest? {
        guard let base = AgentProviderRegistry.builtIn.manifest(for: providerID) else { return nil }
        guard sessionConformingProviders[sessionID]?.contains(providerID) == true,
              let conformance = Self.compiledConformance(for: providerID)
        else { return base }
        return AgentProviderCapabilityGate().manifest(base, enabling: conformance)
    }

    private func markProviderConforming(
        _ providerID: AgentProviderID,
        sessionID: UUID
    ) async {
        guard sessionRoutes[sessionID] != nil,
              Self.compiledConformance(for: providerID) != nil
        else { return }
        let inserted = sessionConformingProviders[sessionID, default: []].insert(providerID).inserted
        guard inserted else { return }
        await configureRegistryForLiveGates()
        DiagnosticLogStore.appendAgentCenter(
            "v2-provider-gate result=passed provider=\(providerID.rawValue) sid=\(String(sessionID.uuidString.prefix(8)))"
        )
        scheduleSessionRefresh(sessionID: sessionID)
    }

    private func markProviderNonconforming(
        _ providerID: AgentProviderID,
        sessionID: UUID
    ) async {
        guard Self.compiledConformance(for: providerID) != nil else { return }

        var removedGate = false
        if var conforming = sessionConformingProviders[sessionID] {
            removedGate = conforming.remove(providerID) != nil
            if conforming.isEmpty {
                sessionConformingProviders.removeValue(forKey: sessionID)
            } else {
                sessionConformingProviders[sessionID] = conforming
            }
        }

        let affected = Set(
            historicalRoutes.compactMap { threadID, route in
                route.providerID == providerID && route.binding.liveSessionID == sessionID
                    ? threadID
                    : nil
            } + projectionRoutes.compactMap { threadID, route in
                route.providerID == providerID && route.binding.liveSessionID == sessionID
                    ? threadID
                    : nil
            }
        )
        for threadID in affected {
            cancelInitialPrefetch(threadID)
            clearNativeReadFailure(threadID)
            historicalRoutes.removeValue(forKey: threadID)
            projectionRoutes.removeValue(forKey: threadID)
            projectionTasks.removeValue(forKey: threadID)?.cancel()
            if presentation.loadingTranscriptThreads.contains(threadID) { presentation.loadingTranscriptThreads.remove(threadID) }
            projectionTaskIDs.removeValue(forKey: threadID)
            pendingProjectionRefreshes.remove(threadID)
            pendingHistoryRequests.remove(threadID)
            pendingFillRequests.remove(threadID)
            pendingLatestRequests.remove(threadID)
            await bridge.retireProjection(for: threadID)
        }

        if removedGate {
            await configureRegistryForLiveGates()
            DiagnosticLogStore.appendAgentCenter(
                "v2-provider-gate result=revoked provider=\(providerID.rawValue) sid=\(String(sessionID.uuidString.prefix(8)))"
            )
        }
        scheduleSessionRefresh(sessionID: sessionID)
        await synchronizePresentation()
    }

    private func scheduleProviderRegistryRefresh() {
        Task { @MainActor [weak self] in
            await self?.configureRegistryForLiveGates()
        }
    }

    func configureRegistryForLiveGates() async {
        let enabled = Set(sessionConformingProviders.values.flatMap { $0 })
        let gate = AgentProviderCapabilityGate()
        let registry = AgentProviderRegistry(manifests: AgentProviderRegistry.builtIn.allManifests.map { base in
            guard enabled.contains(base.id), let conformance = Self.compiledConformance(for: base.id) else {
                return base
            }
            return gate.manifest(base, enabling: conformance)
        })
        await bridge.configure(registry: registry)
    }

    private static func compiledConformance(
        for providerID: AgentProviderID
    ) -> AgentAdapterConformance? {
        let adapterID: String
        switch providerID {
        case .opencode: adapterID = AgentOpenCodeSQLiteAdapter.adapterID
        case .pi: adapterID = AgentPiSessionAdapter.adapterID
        case .kimi: adapterID = AgentKimiWireAdapter.adapterID
        default: return nil
        }
        guard let digest = AgentProviderCapabilityGate.expectedFixtureDigests[providerID] else { return nil }
        return AgentAdapterConformance(
            providerID: providerID,
            adapterID: adapterID,
            sourceFixtureDigest: digest,
            liveGatePassed: true
        )
    }

    func projectHistoricalIfNeeded(_ threadID: AgentThreadID) {
        guard threadRoutes[threadID] == nil,
              let route = historicalRoutes[threadID] else { return }
        project(
            transcriptRef: route.transcriptRef,
            providerID: route.providerID,
            threadID: threadID,
            binding: route.binding,
            source: route.source,
            cursor: nil
        )
    }

    /// A bounded source frontier is independent of transcript/window indexing.
    /// Optional history is canceled, but its network reply is never a Send gate.
    func prepareOutgoingReceipt(_ lease: AgentActionLease) async throws {
        let threadID = lease.threadID, binding = lease.binding
        cancelInitialPrefetch(threadID)
        guard outgoingReceiptLeases[threadID] == nil else { throw AgentActionError.actionInFlight }
        outgoingReceiptLeases[threadID] = lease.token
        defer {
            if outgoingReceiptLeases[threadID] == lease.token {
                outgoingReceiptLeases.removeValue(forKey: threadID)
                if !Task.isCancelled {
                    if pendingLatestRequests.remove(threadID) != nil {
                        pendingHistoryRequests.remove(threadID)
                        pendingProjectionRefreshes.remove(threadID)
                        requestNewerPage(threadID, latest: true)
                    } else if pendingHistoryRequests.remove(threadID) != nil {
                        requestOlderPage(threadID)
                    } else if pendingProjectionRefreshes.remove(threadID) != nil {
                        refreshVisibleTranscript(threadID)
                    } else if pendingFillRequests.remove(threadID) != nil {
                        requestOlderPage(threadID, fill: true)
                    }
                }
            }
        }
        let route: AppleAgentProjectionRoute?
        if let existing = projectionRoutes[threadID] ?? historicalRoutes[threadID], existing.binding == binding {
            route = existing
        } else if let live = threadRoutes[threadID], live.binding == binding,
                  let source = sessionRoutes[binding.liveSessionID]?.source,
                  source.registrationID == live.registrationID,
                  let transcriptRef = live.lifecycleEvent?.transcriptRef {
            route = AppleAgentProjectionRoute(transcriptRef: transcriptRef, providerID: threadID.providerID,
                binding: binding, source: source)
        } else { route = nil }
        var frontier = AgentOutgoingFrontier.unavailable(for: lease)
        if let route, [.codex, .claude, .pi, .opencode, .kimi].contains(route.providerID) {
            do {
                frontier = try await AppleAgentIngestionConnection.withSearchDeadline(.seconds(2)) { [self] in
                    let (host, connection) = try await nativeHost(source: route.source, context: binding)
                    try Task.checkCancellation()
                    if host.threads[threadID] == nil {
                        let nativeLocator = [.codex, .opencode].contains(route.providerID) && route.transcriptRef.hasPrefix("native:")
                        let reply = try await connection.request(["kind": .string("resolve"), "provider": .string(route.providerID.rawValue),
                            nativeLocator ? "nativeSessionID" : "transcriptRef": .string(nativeLocator ? String(route.transcriptRef.dropFirst(7)) : route.transcriptRef)])
                        guard let handle = reply.object["thread"]?.stringValue,
                              reply.object["provider"]?.stringValue == route.providerID.rawValue,
                              reply.object["sessionID"]?.stringValue == threadID.providerSessionID else {
                            throw AgentActionError.staleBinding
                        }
                        try claimNativeThread(threadID, host: host)
                        try host.reserveHandles([(threadID, handle)])
                        host.threads[threadID] = handle
                    }
                    guard let handle = host.threads[threadID] else { throw AgentActionError.unavailable }
                    let reply = try await connection.request(["kind": .string("receipt.frontier"), "thread": .string(handle),
                        "actionID": .string(lease.token.uuidString)])
                    try Task.checkCancellation()
                    guard isNativeHostCurrent(host, sessionID: route.source.sessionID), !connection.isClosed,
                          isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: route.source.registrationID),
                          let raw = reply.object["frontier"] else { throw AgentActionError.staleBinding }
                    let observed = try JSONDecoder().decode(AgentOutgoingFrontier.self, from: JSONEncoder().encode(raw))
                    guard observed.serviceEpoch == nil || observed.serviceEpoch == connection.epoch else { throw AgentActionError.staleBinding }
                    return observed
                }
            } catch {
                // Relay cancellation is distinct from caller cancellation. A
                // canceled optional control can retire that child while the
                // exact live terminal is still authorized for this Send.
                try Task.checkCancellation()
                // A missing/older reader only limits receipt observation. The
                // exact live process/composer is still proven before dispatch.
                DiagnosticLogStore.appendAgentCenter("v2-receipt-frontier result=unavailable provider=\(threadID.providerID.rawValue)")
            }
        }
        try Task.checkCancellation()
        if let route {
            guard isProjectionEndpointCurrent(binding, threadID: threadID, registrationID: route.source.registrationID) else {
                throw AgentActionError.staleBinding
            }
        } else {
            guard let live = threadRoutes[threadID], live.binding == binding,
                  isLiveRouteCurrent(binding, registrationID: live.registrationID) else { throw AgentActionError.staleBinding }
        }
        try await runtime.armOutgoing(lease, frontier: frontier)
    }

    func refreshVisibleTranscript(_ threadID: AgentThreadID) {
        guard presentation.selectedThreadID == threadID,
              let route = projectionRoutes[threadID] ?? historicalRoutes[threadID] ?? initialProjectionRoutes[threadID],
              isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID)
        else { return }
        project(
            transcriptRef: route.transcriptRef, providerID: route.providerID,
            threadID: threadID, binding: route.binding, source: route.source, cursor: nil
        )
    }

    func requestOlderPage(_ threadID: AgentThreadID, fill: Bool = false) {
        if fill {
            // Filling a short transcript is optional: it stops where a page
            // would trim the live head, never clears a failed read or its
            // Retry, and waits for other reads rather than cancelling one
            // (the initial prefetch reads that same history). Queued fills
            // replay here, so a thread left since then is not read.
            guard presentation.threadSnapshots[threadID]?.ingestionWindow?.olderPageFits == true,
                  presentation.selectedThreadID == threadID || ingestionOpenDetails.contains(threadID),
                  presentation.ingestionReadStatuses[threadID]?.isProgress != false,
                  !ingestionManualReadThreads.contains(threadID), ingestionReadRetryTasks[threadID] == nil,
                  !presentation.ingestionCapacityThreads.contains(threadID) else { return }
            if projectionTasks[threadID] != nil || outgoingReceiptLeases[threadID] != nil ||
                initialPrefetchTasks[threadID]?.isCancelled == false {
                pendingFillRequests.insert(threadID); return
            }
        } else {
            cancelInitialPrefetch(threadID)
            clearNativeReadFailure(threadID)
        }
        // The view retries after the current projection publishes its cursor.
        // Never cancel a refresh or issue duplicate reads during a drag.
        if projectionTasks[threadID] != nil || outgoingReceiptLeases[threadID] != nil {
            pendingHistoryRequests.insert(threadID)
            return
        }
        // Pagination belongs to the shared transcript snapshot. A connection
        // route can be retired/recreated independently and is not a second
        // authority for what history is already loaded.
        guard let snapshot = presentation.threadSnapshots[threadID],
              snapshot.hasMore, let cursor = snapshot.cursor else { return }
        guard let route = projectionRoutes[threadID] ?? historicalRoutes[threadID],
              isProjectionEndpointCurrent(
                  route.binding,
                  threadID: threadID,
                  registrationID: route.source.registrationID
              )
        else {
            return
        }
        project(
            transcriptRef: route.transcriptRef,
            providerID: route.providerID,
            threadID: threadID,
            binding: route.binding,
            source: route.source,
            cursor: cursor
        )
    }

    func requestNewerPage(_ threadID: AgentThreadID, latest: Bool = false, bridge: Bool = false) {
        if bridge {
            // Retaining bridged rows is optional, like a fill.
            guard presentation.threadSnapshots[threadID]?.ingestionWindow?.bridgesToHead == true,
                  presentation.ingestionReadStatuses[threadID]?.isProgress != false,
                  !ingestionManualReadThreads.contains(threadID), ingestionReadRetryTasks[threadID] == nil else { return }
        } else {
            cancelInitialPrefetch(threadID)
            clearNativeReadFailure(threadID)
        }
        guard AgentCenterV2ReadPolicy.allows(isEnabled: isEnabled, applicationActive: applicationActive,
            hasSurfaceDemand: hasSurfaceDemand) else { return }
        if projectionTasks[threadID] != nil || outgoingReceiptLeases[threadID] != nil {
            if latest {
                pendingLatestRequests.insert(threadID)
                pendingHistoryRequests.remove(threadID)
                pendingProjectionRefreshes.remove(threadID)
            }
            return
        }
        let window = presentation.threadSnapshots[threadID]?.ingestionWindow
        // A bridged window reads as live, but its newest rows are not
        // retained until a newer page arrives (bridgesToHead).
        guard latest || (window?.hasNewer == true && window?.atLiveHead == false) || window?.bridgesToHead == true,
              let route = projectionRoutes[threadID] ?? historicalRoutes[threadID] ?? initialProjectionRoutes[threadID],
              isProjectionEndpointCurrent(route.binding, threadID: threadID, registrationID: route.source.registrationID) else { return }
        project(transcriptRef: route.transcriptRef, providerID: route.providerID, threadID: threadID, binding: route.binding,
            source: route.source, cursor: latest ? nil : window?.after, nativeDirection: latest ? "bootstrap" : "after")
    }

    func cancelLivePromptWatch(_ threadID: AgentThreadID) {
        livePromptWatchTasks.removeValue(forKey: threadID)?.task.cancel()
        livePromptLifecycleSequences.removeValue(forKey: threadID)
        livePromptFrameTimes.removeValue(forKey: threadID)
    }

    /// The conversation on screen is watched even when no hook announced a
    /// question: older integrations send no hint, and a dialog raised before
    /// the app connected announces nothing. A selection alone is not on
    /// screen: the narrow list keeps one behind it.
    func isDisplayingThread(_ threadID: AgentThreadID) -> Bool {
        applicationActive && hasSurfaceDemand && ingestionOpenDetails.contains(threadID)
    }

    func startLivePromptWatch(_ threadID: AgentThreadID) {
        guard livePromptWatchTasks[threadID] == nil else { return }
        guard applicationActive, let route = threadRoutes[threadID],
              isCurrent(route.binding, threadID: threadID, registrationID: route.registrationID) else {
            let reason = !applicationActive ? "inactive" : threadRoutes[threadID] == nil ? "no-route" : "not-current"
            noteLivePromptWatch(threadID, "refused-\(reason)")
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var exit = "cancelled"
            defer {
                self.noteLivePromptWatch(threadID, "ended-\(exit)")
                if self.livePromptWatchTasks[threadID]?.id == id { self.livePromptWatchTasks.removeValue(forKey: threadID) }
            }
            while !Task.isCancelled,
                  self.applicationActive,
                  self.isCurrent(route.binding, threadID: threadID, registrationID: route.registrationID) {
                let sequence = self.livePromptLifecycleSequences[threadID]
                let frameTime = self.livePromptFrameTimes[threadID]
                let elapsed = frameTime.map { $0.duration(to: .now) } ?? .seconds(3)
                let snapshot = await self.runtime.snapshot(for: threadID)
                let displayed = self.isDisplayingThread(threadID)
                guard snapshot?.summary.livePromptWatch == true || elapsed < .milliseconds(1_500) || displayed else {
                    exit = "unwatched"
                    break
                }
                // A thread this route has forwarded no frame for yet (a
                // rebind whose frames Core already held) is fenced by its
                // delivery generation instead, read before the capture.
                let generation = sequence == nil ? snapshot?.deliveryGeneration : nil
                var outcome = "unfenced"
                if sequence != nil || generation != nil,
                   let source = self.sessionRoutes[route.binding.liveSessionID]?.source,
                   source.registrationID == route.registrationID {
                    var inspected = await source.inspectInputTarget(route.location, route.binding.agentPID)
                    if inspected?.visibleText == nil {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled,
                              self.isCurrent(route.binding, threadID: threadID, registrationID: route.registrationID) else {
                            exit = "superseded"
                            break
                        }
                        inspected = await source.inspectInputTarget(route.location, route.binding.agentPID)
                    }
                    outcome = inspected == nil ? "inspect-failed"
                        : inspected.map { self.target($0, stillMatches: route.profile, binding: route.binding) } == false ? "target-moved"
                        : inspected?.visibleText == nil ? "no-screen" : "unparsed"
                    if !Task.isCancelled, let fresh = inspected,
                       self.isCurrent(route.binding, threadID: threadID, registrationID: route.registrationID),
                       self.target(fresh, stillMatches: route.profile, binding: route.binding),
                       let visible = fresh.visibleText,
                       let request = AgentPromptObservationRequest(providerID: threadID.providerID,
                           visibleText: AppleAgentPromptCapture.bottomWholeRows(visible),
                           currentCursorLine: fresh.currentInputLine.map { AppleAgentPromptCapture.utf8Prefix($0, limit: 2_048) }) {
                        // The conversation can leave the screen while the capture runs.
                        let changed = await self.runtime.observeLivePrompt(request, threadID: threadID,
                            binding: route.binding, observedGeneration: generation, observedLifecycleSequence: sequence,
                            onDisplay: self.isDisplayingThread(threadID))
                        if changed {
                            await self.bridge.refresh(threadID, refreshList: false)
                            await self.synchronizePresentation()
                            self.publishSwipePadEvidence(for: route.binding.liveSessionID)
                            if self.presentation.threadSnapshots[threadID]?.summary.attention == TesseraCore.AgentAttention.none {
                                await self.invalidateAttentionIfPresent(for: threadID)
                            } else {
                                await self.scheduleAttentionIfNeeded(for: threadID)
                            }
                        }
                        let attention = self.presentation.threadSnapshots[threadID]?.summary.attention
                        outcome = "observed attention=\(attention.map { "\($0)" } ?? "none") watch=\(snapshot?.summary.livePromptWatch == true) displayed=\(displayed)"
                    }
                }
                self.noteLivePromptWatch(threadID, outcome)
                // Check for a newer frame every fast tick even in the slow
                // phase, so that frame restarts the cadence without a second task.
                for _ in 0..<(elapsed < .seconds(2) ? 1 : 4) {
                    try? await Task.sleep(for: .milliseconds(250))
                    if self.livePromptLifecycleSequences[threadID] != sequence { break }
                }
            }
            if exit == "cancelled", !Task.isCancelled { exit = self.applicationActive ? "not-current" : "inactive" }
        }
        livePromptWatchTasks[threadID] = (id, task)
    }

    /// A retained frame restarts the watch on every discovery pass, so a
    /// steady pass/exit cycle logs once: a pass outcome when it changes, an
    /// exit or refusal once after each logged pass.
    private func noteLivePromptWatch(_ threadID: AgentThreadID, _ outcome: String) {
        // A cancelled watch ends after the cleanup that disabled Agent Center
        // or unregistered its host's last session; keep that cleanup final.
        guard isEnabled, sessionRoutes.values.contains(where: { $0.hostID == threadID.hostID }) else { return }
        var last = livePromptWatchOutcomes[threadID] ?? (pass: nil, exit: nil)
        if outcome.hasPrefix("ended-") || outcome.hasPrefix("refused-") {
            guard last.exit != outcome else { return }
            last.exit = outcome
        } else {
            guard last.pass != outcome else { return }
            last = (pass: outcome, exit: nil)
        }
        livePromptWatchOutcomes[threadID] = last
        DiagnosticLogStore.appendAgentCenter(
            "live-prompt-watch provider=\(threadID.providerID.rawValue) thread=\(threadID.providerSessionID.prefix(8)) result=\(outcome)"
        )
    }

    /// The route's last accepted frame ended its conversation. Navigation
    /// and observation stay possible; no write may follow until a newer
    /// frame reopens it.
    private func conversationEnded(_ threadID: AgentThreadID) -> Bool {
        guard let event = threadRoutes[threadID]?.lifecycleEvent?.event else { return false }
        return event == AgentLifecycleEventKind.sessionEnd.rawValue || event == AgentLifecycleEventKind.wrapperExit.rawValue
    }

    private func isCurrent(
        _ binding: AgentTerminalBinding,
        threadID: AgentThreadID,
        registrationID: UUID
    ) -> Bool {
        guard isEnabled,
              let route = threadRoutes[threadID],
              route.registrationID == registrationID,
              route.binding == binding,
              sessionRoutes[binding.liveSessionID]?.source.registrationID == registrationID
        else { return false }
        return true
    }

    /// Historical inventory rows have no live terminal route. Their reads are
    /// still allowed through the already-connected, generation-current source;
    /// mutation authority remains restricted to `isCurrent` above.
    private func isProjectionEndpointCurrent(
        _ binding: AgentTerminalBinding,
        threadID: AgentThreadID,
        registrationID: UUID
    ) -> Bool {
        guard AgentCenterV2ReadPolicy.allows(
            isEnabled: isEnabled,
            applicationActive: applicationActive,
            hasSurfaceDemand: hasSurfaceDemand
        ),
        sessionRoutes[binding.liveSessionID]?.source.registrationID == registrationID else {
            return false
        }
        return threadRoutes[threadID]?.binding == binding
            || projectionRoutes[threadID]?.binding == binding
            || initialProjectionRoutes[threadID]?.binding == binding
            || historicalRoutes[threadID]?.binding == binding
    }

    func target(
        _ target: AgentProbeTarget,
        stillMatches profile: SwipePadProfile,
        binding: AgentTerminalBinding
    ) -> Bool {
        guard target.location.sessionID == binding.liveSessionID,
              target.location.windowID.map(String.init) == binding.windowID,
              target.location.paneID.map(String.init) == binding.paneID else { return false }
        return target.processNames.contains {
            SwipePadActiveProfileResolver.matches(profile: profile, processName: $0)
        }
    }

    private func matchingProfile(
        _ processNames: [String],
        profiles: [SwipePadProfile]
    ) -> SwipePadProfile? {
        profiles.first { profile in
            let isBuiltInTierCDetectionProfile = profile.isBuiltIn && [
                SwipePadProfile.builtInOpenCodeID,
                SwipePadProfile.builtInPiID,
                SwipePadProfile.builtInKimiID,
            ].contains(profile.id)
            return (profile.agentDetection != nil || isBuiltInTierCDetectionProfile) && processNames.contains {
                SwipePadActiveProfileResolver.matches(profile: profile, processName: $0)
            }
        }
    }

    private func providerID(
        event: AgentLifecycleEvent?,
        processNames: [String]
    ) -> AgentProviderID? {
        if let event, let providerID = AgentProviderID(rawValue: event.provider) {
            return providerID
        }
        return AgentProviderRegistry.builtIn.allManifests.first { manifest in
            manifest.id != .custom && manifest.processMatchers.contains { matcher in
                processNames.contains { process in
                    matcher.executableNames.contains {
                        $0.caseInsensitiveCompare(process) == .orderedSame
                    }
                }
            }
        }?.id
    }

    private func registerCandidate(
        _ target: AgentProbeTarget,
        provider: AgentProviderManifest,
        providerID: AgentProviderID,
        hostID: UUID,
        route: AppleAgentThreadRoute
    ) async {
        guard let candidateID = AgentSourceCandidateID(
            hostID: hostID,
            providerID: providerID,
            sourceIdentity: route.sourceIdentity
        ) else { return }
        guard isSessionRegistrationCurrent(route.binding.liveSessionID, registrationID: route.registrationID) else {
            return
        }
        let parsed = target.visibleText.map {
            AgentPromptParser.parse(
                visibleText: $0,
                profile: route.profile,
                currentInputLine: target.currentInputLine
            )
        }
        let prompt = parsed?.prompt.flatMap { prompt -> AgentActionPrompt? in
            let tokenValue = "candidate-\(Self.stablePromptToken(prompt.signature))"
            guard let token = AgentActionToken(tokenValue) else { return nil }
            return AgentActionPrompt(
                title: prompt.summary,
                options: prompt.options.map {
                    TesseraCore.AgentPromptOption(
                        id: $0.responseMacro,
                        label: $0.label,
                        isDefault: $0.isDefault
                    )
                },
                token: token
            )
        }
        let fallback = AgentFallbackSnapshot(
            status: prompt == nil ? .unavailable : .waitingForInput,
            location: target.location.addressText,
            integrationAvailable: target.lifecycleEvent != nil,
            liveTail: parsed?.text ?? "",
            prompt: prompt,
            binding: route.binding
        )
        candidateRoutes[candidateID] = route
        await runtime.registerCandidate(
            candidateID,
            fallback: fallback,
            providerName: provider.displayName,
            title: Self.candidateTitle(for: target, provider: provider),
            hostDisplayLabel: target.location.hostName,
            lastActivity: .now,
            processIDs: target.processIDs
        )
        guard isCandidateCurrent(candidateID, route: route) else { return }
    }

    /// Diagnostics name the failure class and the host's classifier code as
    /// one slash-joined token. A code is logged only if it satisfies the read
    /// status rule (ASCII alphanumerics, at most 80), so an old host's raw
    /// error text never reaches the log. The diagnostics sanitizer redacts any
    /// bare run of exactly 22 key characters as a mosh key, and eight host
    /// codes are 22 characters long; joined to their class the run is longer
    /// (the shortest host code is four characters), so it survives.
    nonisolated static func projectionFailureReason(_ error: Error) -> String {
        switch error {
        case let projection as AgentProjectionError: return diagnosticToken([String(describing: projection)])
        case AgentIngestionError.remote(let code): return diagnosticToken(["ingestion", "remote", diagnosticCode(code)])
        case let ingestion as AgentIngestionError: return diagnosticToken(["ingestion", String(describing: ingestion)])
        case let action as AgentActionError: return diagnosticToken(["action", String(describing: action)])
        default: return "transport"
        }
    }

    /// Joins diagnostic parts with `/`. The diagnostics sanitizer redacts any
    /// run of exactly 22 key characters (`[A-Za-z0-9+/]`) as a mosh key, and
    /// `/` is in that class, so a token whose joined length lands on 22 is
    /// padded past it; every other length passes through unchanged.
    nonisolated static func diagnosticToken(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "/")
        return joined.utf8.count == 22 ? joined + "/padded" : joined
    }

    nonisolated static func diagnosticCode(_ code: String) -> String {
        guard !code.isEmpty, code.utf8.count <= 80,
              code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) })
        else { return "unclassified" }
        return code
    }

    /// The composer's current line names a live candidate, or previews a
    /// thread, only when the user typed it. A provider placeholder such as
    /// "Ask Codex to do anything", a DIM suggestion or a bare prompt glyph
    /// would otherwise become the row title.
    nonisolated static func candidateTitle(for target: AgentProbeTarget, provider: AgentProviderManifest) -> String {
        guard let line = rowPreview(for: target, provider: provider) else { return provider.displayName }
        return String(line.prefix(512))
    }

    nonisolated static func rowPreview(for target: AgentProbeTarget, provider: AgentProviderManifest) -> String? {
        guard let line = target.currentInputLine,
              !AgentComposerEvidence.isPlaceholderTitleLine(provider: provider.id.rawValue, line: line,
                  visibleText: target.visibleText, cursorRow: target.cursorRow, screen: target.screenEvidence)
        else { return nil }
        return line
    }

    func openCandidateTerminal(_ candidateID: AgentSourceCandidateID) async {
        guard let route = candidateRoutes[candidateID],
              let session = sessionRoutes[route.binding.liveSessionID],
              session.source.registrationID == route.registrationID,
              let target = await session.source.inspectInputTarget(route.location, route.binding.agentPID),
              isCandidateCurrent(candidateID, route: route),
              target.location == route.location,
              self.target(target, stillMatches: route.profile, binding: route.binding)
        else {
            presentation.reportUnavailable("The original terminal is unavailable.")
            return
        }
        onOpenExactTerminal?(route.binding)
        session.source.jump(route.location)
    }

    func answerCandidate(
        _ candidateID: AgentSourceCandidateID,
        token: AgentActionToken,
        optionID: String
    ) async {
        guard candidateActionIDs.insert(candidateID).inserted else {
            presentation.reportActionError(.actionInFlight)
            return
        }
        defer { candidateActionIDs.remove(candidateID) }
        guard let route = candidateRoutes[candidateID],
              AgentCenterV2CandidateActionPolicy.canAnswer(route.binding),
              let session = sessionRoutes[route.binding.liveSessionID],
              session.source.registrationID == route.registrationID,
              let target = await session.source.inspectInputTarget(route.location, route.binding.agentPID),
              isCandidateCurrent(candidateID, route: route),
              self.target(target, stillMatches: route.profile, binding: route.binding),
              route.binding.agentPID.map(target.processIDs.contains) ?? false,
              let visible = target.visibleText
        else {
            presentation.reportActionError(.staleBinding)
            return
        }
        let parsed = AgentPromptParser.parse(
            visibleText: visible,
            profile: route.profile,
            currentInputLine: target.currentInputLine
        )
        guard let prompt = parsed.prompt,
              token.rawValue == "candidate-\(Self.stablePromptToken(prompt.signature))",
              let option = prompt.options.first(where: { $0.responseMacro == optionID }),
              isCandidateCurrent(candidateID, route: route),
              await session.source.send(route.location, MacroEncoder.encode(option.responseMacro)),
              let after = await session.source.verifySend(route.location),
              isCandidateCurrent(candidateID, route: route),
              route.binding.agentPID.map(after.processIDs.contains) ?? false,
              let afterVisible = after.visibleText
        else {
            presentation.reportActionError(.stalePrompt)
            return
        }
        let afterParsed = AgentPromptParser.parse(
            visibleText: afterVisible,
            profile: route.profile,
            currentInputLine: after.currentInputLine
        )
        // A parse that ran out of time cannot show the prompt went away.
        guard !afterParsed.timedOut, afterParsed.prompt?.signature != prompt.signature else {
            presentation.reportActionError(.verificationFailed)
            return
        }
        scheduleSessionRefresh(sessionID: route.binding.liveSessionID)
    }

    private func isCandidateCurrent(
        _ candidateID: AgentSourceCandidateID,
        route: AppleAgentThreadRoute
    ) -> Bool {
        isEnabled
            && candidateRoutes[candidateID]?.registrationID == route.registrationID
            && candidateRoutes[candidateID]?.binding == route.binding
            && candidateRoutes[candidateID]?.location == route.location
            && sessionRoutes[route.binding.liveSessionID]?.source.registrationID == route.registrationID
    }

    private func availability(
        provider: AgentProviderManifest,
        lifecycle: AgentLifecycleEvent,
        binding: AgentTerminalBinding,
        source: AgentSessionSource
    ) -> AgentAvailability {
        let hasContent = lifecycle.transcriptRef != nil && provider.hasTranscript
        let projectionAvailable: Bool
        if hasContent {
            projectionAvailable = {
                let current: @MainActor @Sendable (AgentTerminalBinding) -> Bool = { _ in true }
                if case .available = source.projectorExecAvailability(binding, current) { return true }
                return false
            }()
        } else { projectionAvailable = false }
        return AgentAvailability(
            content: hasContent && projectionAvailable,
            status: true,
            actions: binding.capabilities.contains(.send) && !provider.actions.isEmpty,
            spawn: source.launchAgent != nil && source.supportsTmuxLaunch() && binding.capabilities.contains(.send) && provider.actions.contains(.spawn) && binding.hasCurrentTmuxTarget,
            fork: source.launchAgent != nil && source.supportsTmuxLaunch() && binding.capabilities.contains(.send) && provider.actions.contains(.fork) && binding.hasCurrentTmuxTarget,
            search: hasContent && projectionAvailable,
            reason: hasContent && !projectionAvailable ? .channelUnavailable : hasContent ? nil : .unsupported
        )
    }

    private func supportsLifecycle(
        _ event: AgentLifecycleEvent,
        provider: AgentProviderManifest
    ) -> Bool {
        guard case .hooks(let supportedVersion) = provider.lifecycle else {
            return false
        }
        return AgentLifecycleEvent.compatibleVersions.contains(event.version)
            && event.version <= supportedVersion
    }

    private func transportKind(_ location: AgentLocation) -> AgentTransportKind {
        let mosh = location.transportLabel.lowercased().contains("mosh")
        if location.paneID != nil { return mosh ? .moshTmux : .sshTmux }
        return mosh ? .mosh : .ssh
    }

    private func coreEnvelope(
        _ event: AgentLifecycleEvent,
        providerID: AgentProviderID,
        arrivalSequence: UInt64
    ) -> AgentLifecycleEnvelope? {
        guard let kind = AgentLifecycleEventKind(rawValue: event.event) else { return nil }
        return AgentLifecycleEnvelope(
            version: event.version,
            providerID: providerID,
            event: kind,
            status: coreStatus(event.state, event: event.event),
            providerSessionID: event.providerSessionID,
            agentPID: event.agentPID,
            transcriptRef: event.transcriptRef,
            agentID: event.agentID,
            agentType: event.agentType,
            rootAgentID: event.rootAgentID,
            eventSequence: arrivalSequence,
            sourceTimestampNanoseconds: event.timestampNanoseconds
        )?.withInputHint(AgentLifecycleInputHint(reason: event.reason, event: kind))
    }

    private func coreStatus(_ status: AgentStatus, event: String) -> TesseraCore.AgentStatus {
        if event == "Stop" { return .finished }
        switch status {
        case .waitingForInput: return .waitingForInput
        case .justFinished: return .finished
        case .working: return .working
        case .idle: return .idle
        case .unavailable: return .unavailable
        }
    }

    private func attention(_ event: AgentLifecycleEvent) -> TesseraCore.AgentAttention {
        if event.state == .waitingForInput { return .needsYou }
        if event.event == "Stop" { return .unreadCompletion }
        return .none
    }

    private func permissionMode(_ value: String) -> AgentPermissionMode {
        switch value.lowercased() {
        case "default", "defaultmode": return .defaultMode
        case "plan": return .plan
        case "auto", "accept-edits", "bypasspermissions": return .auto
        case "readonly", "read-only": return .readOnly
        default: return .unavailable
        }
    }

    private static func authoritativePrompt(_ prompt: AgentPrompt) -> AgentAuthoritativePrompt? {
        AgentAuthoritativePrompt(
            signature: prompt.signature,
            options: prompt.options.map {
                TesseraCore.AgentPromptOption(
                    id: $0.responseMacro,
                    label: $0.label,
                    isDefault: $0.isDefault
                )
            },
            cursorOwned: true,
            visiblyBlocking: true
        )
    }

    private static func stablePromptToken(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            .prefix(128)
            .description
    }
}
