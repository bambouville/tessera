import Foundation

/// Produces the smallest safe tmux command sequence for one window move.
public enum TmuxWindowReorderPlanner {
    public struct Plan: Equatable, Sendable, Codable {
        public let commands: [String]
        public let expectedOrder: [WindowId]

        public init(commands: [String], expectedOrder: [WindowId]) {
            self.commands = commands
            self.expectedOrder = expectedOrder
        }
    }

    public static func plan(
        order: [WindowId],
        moving: WindowId,
        to destination: Int,
        capabilities: TmuxWindowCapabilities,
        sessionID: SessionId? = nil,
        activeWindowID: WindowId? = nil,
        highestIndex: Int? = nil
    ) -> Plan? {
        guard !order.isEmpty,
              order.count <= 512,
              Set(order).count == order.count,
              order.contains(moving),
              order.indices.contains(destination),
              activeWindowID.map(order.contains) ?? true,
              sessionID.map({ $0.rawValue >= 0 }) ?? true,
              highestIndex.map({ (0...1_000_000).contains($0) }) ?? true,
              order.allSatisfy({ $0.rawValue >= 0 })
        else { return nil }

        guard let source = order.firstIndex(of: moving) else { return nil }
        if source == destination {
            return Plan(commands: [], expectedOrder: order)
        }

        var expectedOrder = order
        expectedOrder.remove(at: source)
        expectedOrder.insert(moving, at: destination)

        var commands: [String]
        if !capabilities.supportsMoveBefore {
            // Before 3.2, -a inserts after the destination session's CURRENT
            // window, ignoring the window part of -t. Adjacent detached swaps
            // implement the same stable insertion without that version trap.
            let step = source < destination ? 1 : -1
            commands = stride(from: source + step, through: destination, by: step).map {
                TmuxWindowCommands.swapWindows(moving, order[$0], sessionID: sessionID)
            }
        } else if destination == 0 {
            commands = [TmuxWindowCommands.moveWindow(moving, before: expectedOrder[1], sessionID: sessionID)]
        } else {
            commands = [TmuxWindowCommands.moveWindow(moving, after: expectedOrder[destination - 1], sessionID: sessionID)]
        }

        if let activeWindowID {
            commands.append(TmuxWindowCommands.selectWindow(activeWindowID, sessionID: sessionID))
        }
        return Plan(commands: commands, expectedOrder: expectedOrder)
    }
}
