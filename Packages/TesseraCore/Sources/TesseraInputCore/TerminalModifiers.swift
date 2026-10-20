/// Platform-neutral modifier names. Adapters translate UIKit, AppKit, Android,
/// or on-screen modifier state into this type before terminal encoding.
public enum TerminalModifier: String, CaseIterable, Codable, Sendable {
    case control
    case alternate
    case shift
    case command
}

/// Normalized modifier state shared by physical- and software-keyboard paths.
///
/// Command remains representable because Apple adapters use it for app
/// shortcuts, but it is deliberately excluded from terminal wire modifiers.
public struct TerminalModifiers: Equatable, Hashable, Codable, Sendable {
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    public var cmd: Bool

    public init(
        ctrl: Bool = false,
        alt: Bool = false,
        shift: Bool = false,
        cmd: Bool = false
    ) {
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.cmd = cmd
    }

    public init<S: Sequence>(_ modifiers: S) where S.Element == TerminalModifier {
        self.init()
        for modifier in modifiers {
            switch modifier {
            case .control: ctrl = true
            case .alternate: alt = true
            case .shift: shift = true
            case .command: cmd = true
            }
        }
    }

    public static let none = TerminalModifiers()

    /// Modifiers which are meaningful to terminal protocols.
    public var terminalOnly: TerminalModifiers {
        TerminalModifiers(
            ctrl: ctrl,
            alt: alt,
            shift: shift
        )
    }

    public var control: Bool {
        get { ctrl }
        set { ctrl = newValue }
    }

    public var alternate: Bool {
        get { alt }
        set { alt = newValue }
    }

    public var command: Bool {
        get { cmd }
        set { cmd = newValue }
    }

    public var hasTerminalModifier: Bool {
        ctrl || alt || shift
    }

    public var isAnyArmed: Bool {
        hasTerminalModifier || cmd
    }

    /// Xterm's 1-based modifier parameter: 1 + Shift + 2*Alt + 4*Control.
    /// Command never changes this value.
    public var xtermParameter: Int {
        1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
    }

    /// Xterm mouse modifier bits added to a button or wheel code.
    public var xtermMouseFlags: Int {
        (shift ? 4 : 0) + (alt ? 8 : 0) + (ctrl ? 16 : 0)
    }
}
