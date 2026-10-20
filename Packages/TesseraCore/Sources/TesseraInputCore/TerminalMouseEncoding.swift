public enum TerminalMouseEncoding: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case none
    case x10
    case sgr
}

public enum TerminalMouseTrackingMode: String, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case off
    case buttonPress
    case buttonDrag
    case anyEvent
}

public enum TerminalMouseButton: Int, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case primary = 0
    case middle = 1
    case secondary = 2
}

public enum TerminalMouseButtonAction: String, Equatable, Hashable, Codable, Sendable {
    case press
    case release
}

public enum TerminalWheelDirection: Int, CaseIterable, Equatable, Hashable, Codable, Sendable {
    case up = 0
    case down = 1
    case left = 2
    case right = 3
}

public enum TerminalMouseEvent: Equatable, Sendable {
    case button(
        TerminalMouseButton,
        action: TerminalMouseButtonAction,
        column: Int,
        row: Int,
        modifiers: TerminalModifiers
    )
    case motion(
        button: TerminalMouseButton?,
        column: Int,
        row: Int,
        modifiers: TerminalModifiers
    )
    case wheel(
        TerminalWheelDirection,
        column: Int,
        row: Int,
        modifiers: TerminalModifiers
    )
}

/// Encodes neutral pointer events using xterm's legacy X10 or SGR wire form.
public enum TerminalMouseSequenceEncoder {
    public static func encode(
        _ event: TerminalMouseEvent,
        using encoding: TerminalMouseEncoding
    ) -> [UInt8] {
        guard encoding != .none else { return [] }

        let descriptor = descriptor(for: event, encoding: encoding)
        switch encoding {
        case .none:
            return []
        case .x10:
            let column = clamp(descriptor.column, to: 1...223)
            let row = clamp(descriptor.row, to: 1...223)
            return [
                0x1B, 0x5B, 0x4D,
                UInt8(descriptor.buttonFlags + 32),
                UInt8(column + 32),
                UInt8(row + 32),
            ]
        case .sgr:
            let column = clamp(descriptor.column, to: 1...9_999)
            let row = clamp(descriptor.row, to: 1...9_999)
            let final = descriptor.isRelease ? "m" : "M"
            return Array("\u{1B}[<\(descriptor.buttonFlags);\(column);\(row)\(final)".utf8)
        }
    }

    private struct Descriptor {
        let buttonFlags: Int
        let column: Int
        let row: Int
        let isRelease: Bool
    }

    private static func descriptor(
        for event: TerminalMouseEvent,
        encoding: TerminalMouseEncoding
    ) -> Descriptor {
        switch event {
        case .button(let button, let action, let column, let row, let modifiers):
            let base: Int
            if action == .release, encoding == .x10 {
                base = 3
            } else {
                base = button.rawValue
            }
            return Descriptor(
                buttonFlags: base + modifiers.xtermMouseFlags,
                column: column,
                row: row,
                isRelease: action == .release
            )
        case .motion(let button, let column, let row, let modifiers):
            return Descriptor(
                buttonFlags: (button?.rawValue ?? 3) + 32 + modifiers.xtermMouseFlags,
                column: column,
                row: row,
                isRelease: false
            )
        case .wheel(let direction, let column, let row, let modifiers):
            return Descriptor(
                buttonFlags: 64 + direction.rawValue + modifiers.xtermMouseFlags,
                column: column,
                row: row,
                isRelease: false
            )
        }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

public struct TerminalInputMode: Equatable, Hashable, Codable, Sendable {
    public var applicationCursorKeys: Bool
    public var alternateScreen: Bool
    public var mouseTracking: TerminalMouseTrackingMode
    public var mouseEncoding: TerminalMouseEncoding

    public init(
        applicationCursorKeys: Bool = false,
        alternateScreen: Bool = false,
        mouseTracking: TerminalMouseTrackingMode = .off,
        mouseEncoding: TerminalMouseEncoding = .none
    ) {
        self.applicationCursorKeys = applicationCursorKeys
        self.alternateScreen = alternateScreen
        self.mouseTracking = mouseTracking
        self.mouseEncoding = mouseEncoding
    }
}

/// Reset effects a platform adapter must apply when terminal modes change.
public struct TerminalInputReset: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let keySequenceState = TerminalInputReset(rawValue: 1 << 0)
    public static let pointerState = TerminalInputReset(rawValue: 1 << 1)
    public static let scrollAccumulator = TerminalInputReset(rawValue: 1 << 2)
}

/// Tracks state that must not leak across terminal-mode epochs.
public struct TerminalInputStateMachine: Sendable {
    public private(set) var mode: TerminalInputMode
    public private(set) var pressedButtons: Set<TerminalMouseButton>

    public init(mode: TerminalInputMode = .init()) {
        self.mode = mode
        pressedButtons = []
    }

    @discardableResult
    public mutating func transition(to newMode: TerminalInputMode) -> TerminalInputReset {
        guard newMode != mode else { return [] }

        var resets: TerminalInputReset = []
        if newMode.applicationCursorKeys != mode.applicationCursorKeys {
            resets.insert(.keySequenceState)
        }
        if newMode.alternateScreen != mode.alternateScreen
            || newMode.mouseTracking != mode.mouseTracking
            || newMode.mouseEncoding != mode.mouseEncoding {
            resets.insert(.pointerState)
            resets.insert(.scrollAccumulator)
            pressedButtons.removeAll(keepingCapacity: true)
        }
        mode = newMode
        return resets
    }

    public mutating func note(_ event: TerminalMouseEvent) {
        switch event {
        case .button(let button, let action, _, _, _):
            switch action {
            case .press: pressedButtons.insert(button)
            case .release: pressedButtons.remove(button)
            }
        case .motion, .wheel:
            break
        }
    }

    @discardableResult
    public mutating func reset() -> TerminalInputReset {
        pressedButtons.removeAll(keepingCapacity: true)
        return [.keySequenceState, .pointerState, .scrollAccumulator]
    }
}
