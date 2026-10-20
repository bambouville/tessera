import Foundation

/// A scoped process inventory. Failed or truncated reads cannot prove absence.
public struct AgentOccupancyObservation: Codable, Equatable, Sendable {
    public struct Process: Codable, Equatable, Sendable {
        public let pid: Int
        public let providerID: AgentProviderID

        public init(pid: Int, providerID: AgentProviderID) {
            self.pid = pid; self.providerID = providerID
        }
    }

    public struct Pane: Codable, Equatable, Sendable {
        /// Nil names the whole session on a transport without tmux.
        public let paneID: String?
        /// False only after a definitive missing-pane response.
        public let exists: Bool
        public let complete: Bool
        public let processes: [Process]
        /// Present PIDs whose provider the inventory could not name (a Node
        /// launcher, a versioned native binary). Presence is still presence:
        /// they never prove an agent absent.
        public let unclassifiedPIDs: [Int]

        public init(paneID: String?, exists: Bool, complete: Bool, processes: [Process], unclassifiedPIDs: [Int] = []) {
            self.paneID = paneID; self.exists = exists
            self.complete = complete; self.processes = processes
            self.unclassifiedPIDs = unclassifiedPIDs
        }

        private enum CodingKeys: String, CodingKey { case paneID, exists, complete, processes, unclassifiedPIDs }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(paneID: try values.decodeIfPresent(String.self, forKey: .paneID),
                      exists: try values.decode(Bool.self, forKey: .exists),
                      complete: try values.decode(Bool.self, forKey: .complete),
                      processes: try values.decode([Process].self, forKey: .processes),
                      unclassifiedPIDs: try values.decodeIfPresent([Int].self, forKey: .unclassifiedPIDs) ?? [])
        }
    }

    public let hostID: UUID
    public let liveSessionID: UUID
    public let carrierGeneration: UInt64
    public let transport: AgentTransportKind
    public let tmuxSession: String?
    public let panes: [Pane]
    /// Present only after a complete, successful list of every session pane.
    public let allPaneIDs: [String]?

    public init(hostID: UUID, liveSessionID: UUID, carrierGeneration: UInt64,
                transport: AgentTransportKind, tmuxSession: String? = nil,
                panes: [Pane], allPaneIDs: [String]? = nil) {
        self.hostID = hostID; self.liveSessionID = liveSessionID
        self.carrierGeneration = carrierGeneration; self.transport = transport
        self.tmuxSession = tmuxSession; self.panes = panes; self.allPaneIDs = allPaneIDs
    }
}

public enum AgentOccupancyPolicy {
    /// Callers supply live routes only. A pid-less binding names no process
    /// to retire; an observe-only one that names a PID still retires with it.
    /// Every carrier scope field must match.
    /// A complete pane proves PID/provider absence; a complete pane list
    /// proves a missing pane. Anything unknown leaves its route alone,
    /// including a present PID whose provider the inventory could not name.
    public static func retirements(live: [(AgentThreadID, AgentTerminalBinding)],
                                   observation: AgentOccupancyObservation) -> [AgentThreadID] {
        live.compactMap { id, binding in
            guard let pid = binding.agentPID,
                  id.hostID == observation.hostID,
                  binding.liveSessionID == observation.liveSessionID,
                  binding.carrierGeneration == observation.carrierGeneration,
                  binding.transport == observation.transport,
                  binding.tmuxSession == observation.tmuxSession else { return nil }
            let panes = observation.panes.filter { $0.paneID == binding.paneID }
            if !panes.isEmpty {
                // Conflicting duplicate observations cannot establish absence.
                return panes.allSatisfy { pane in
                    !pane.exists || pane.complete && !pane.unclassifiedPIDs.contains(pid) && !pane.processes.contains {
                        $0.pid == pid && $0.providerID == id.providerID
                    }
                } ? id : nil
            }
            guard let paneID = binding.paneID, let allPaneIDs = observation.allPaneIDs,
                  !allPaneIDs.contains(paneID) else { return nil }
            return id
        }
    }
}

/// A live conversation keeps its process until that route is proved absent.
public enum AgentRegistration: Equatable, Sendable {
    case registered
    case liveElsewhere(current: AgentTerminalBinding)
}
