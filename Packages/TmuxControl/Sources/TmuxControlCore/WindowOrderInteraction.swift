import Foundation

/// Relative intent is resolved when a command executes, never when its menu opens.
public enum TmuxWindowMoveIntent: String, CaseIterable, Codable, Sendable {
    case previous, next, start, end

    public func destination(in order: [WindowId], moving id: WindowId) -> Int? {
        guard let index = order.firstIndex(of: id), order.count > 1 else { return nil }
        let destination: Int
        switch self {
        case .previous: destination = index - 1
        case .next: destination = index + 1
        case .start: destination = 0
        case .end: destination = order.count - 1
        }
        return order.indices.contains(destination) && destination != index ? destination : nil
    }
}

public enum TmuxWindowMove: Equatable, Codable, Sendable {
    case position(Int)
    case relative(TmuxWindowMoveIntent)

    public func destination(in order: [WindowId], moving id: WindowId) -> Int? {
        switch self {
        case .position(let index): return order.contains(id) && order.indices.contains(index) ? index : nil
        case .relative(let intent): return intent.destination(in: order, moving: id)
        }
    }
}

/// Axis-independent gesture state. Adapters pass coordinates along their axis
/// in one coordinate space; no native view, timer or server state lives here.
public struct TmuxWindowDragState: Equatable, Sendable {
    public private(set) var id: WindowId?
    public private(set) var previewOrder: [WindowId]?
    public private(set) var isDragging = false
    public private(set) var baseline: [WindowId] = []
    private var startPointer = 0.0
    private var startFrame = 0.0
    private var translation = 0.0

    public init() {}

    @discardableResult
    public mutating func begin(id: WindowId, order: [WindowId], pointer: Double,
                               frameStart: Double, enabled: Bool) -> Bool {
        cancel()
        guard enabled, order.contains(id), Set(order).count == order.count else { return false }
        self.id = id
        baseline = order
        startPointer = pointer
        startFrame = frameStart
        return true
    }

    @discardableResult
    public mutating func update(pointer: Double, midpoints: [WindowId: Double], enabled: Bool) -> Bool {
        guard enabled else { cancel(); return false }
        guard let id else { return false }
        translation = pointer - startPointer
        guard isDragging || abs(translation) > 8 else { return false }
        isDragging = true
        let previous = previewOrder ?? baseline
        var remaining = previous.filter { $0 != id }
        // Incomplete layout must not guess a distant destination.
        guard remaining.allSatisfy({ midpoints[$0] != nil }) else { return false }
        let destination = remaining.firstIndex { pointer < midpoints[$0]! } ?? remaining.count
        remaining.insert(id, at: destination)
        previewOrder = remaining
        return remaining != previous
    }

    public func offset(currentFrameStart: Double) -> Double {
        isDragging ? translation + startFrame - currentFrameStart : 0
    }

    public mutating func finish(cancelled: Bool) -> Int? {
        defer { cancel() }
        guard !cancelled, isDragging, let id,
              let destination = previewOrder?.firstIndex(of: id),
              destination != baseline.firstIndex(of: id) else { return nil }
        return destination
    }

    public mutating func cancel() { self = Self() }
}
