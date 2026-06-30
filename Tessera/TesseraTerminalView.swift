import SwiftTerm
import UIKit

/// Container view that hosts a SwiftTerm `TerminalView` and claims the
/// tmux keyboard shortcuts via `UIKeyCommand` through its position in
/// the responder chain.
///
/// Why a container instead of a SwiftTerm subclass: SwiftTerm marks
/// `canPerformAction(_:withSender:)` as `public override` rather than
/// `open`, so an external subclass can't override it — which kills
/// the obvious approach of registering `UIKeyCommand`s directly on a
/// `TerminalView` subclass. Instead we put the commands on this
/// parent `UIView`. When `TerminalView` is first responder, UIKit
/// walks the responder chain to collect `keyCommands` and to dispatch
/// matching actions; since this container sits directly above the
/// terminal in the chain, its commands and action methods are both
/// reachable.
///
/// SwiftTerm's own `canPerformAction` returns `false` for anything
/// outside its small built-in set, so when UIKit looks for a target
/// for `tmuxNewWindow` it walks past `TerminalView` and lands on this
/// container, whose `canPerformAction` returns `true` for the tmux
/// selectors.
///
/// Why ⌘⇧W instead of ⌘W: iPadOS reserves ⌘W at the system level for
/// scene close (especially under Stage Manager). A `UIKeyCommand` for
/// ⌘W gets dispatched inconsistently and silently loses the binding
/// under multi-scene layouts. See §3.2 R3.2.2 of the plan.
///
/// Why a single `tmuxSelectWindow(_:)` for ⌘1–⌘9 rather than nine
/// separate selectors: each `UIKeyCommand` passes itself to the
/// action when the method takes an argument, so one handler can read
/// `sender.input` and pick off the digit — avoids nine near-identical
/// `@objc` trampolines.
final class TesseraTerminalContainer: UIView {

    /// The hosted SwiftTerm view. Pinned to the container's bounds
    /// via Auto Layout so it always fills the container.
    let terminalView: TerminalView

    /// Invoked when one of the tmux shortcut chords fires. The outer
    /// view sets this up to route shortcuts into the `TmuxController`.
    /// If nil (or the controller is in passthrough mode), all
    /// shortcuts are silent no-ops — matches the "⌘T before tmux has
    /// attached does nothing" expectation.
    var onTmuxShortcut: ((TesseraTmuxShortcut) -> Void)?

    /// When false, native tmux key commands are withdrawn from the
    /// responder chain so degraded mosh sessions can't dispatch stale
    /// tab actions.
    var tmuxShortcutsEnabled = true

    /// True when this surface belongs to a mounted multi-pane grid. Gates the
    /// bare ⌘[/⌘] pane-cycle and ⌘⇧Return zoom chords (which relocated the
    /// session switcher to ⌘⇧K/⌘⇧J) so they no-op on the single-pane shared
    /// terminal and in no-tmux passthrough — only a real grid pane cycles.
    var multiPaneActive = false

    /// Invoked when one of the find shortcut chords fires
    /// (⌘F open, ⌘G next, ⇧⌘G previous). The outer view routes them
    /// into the active `FindController`. Esc is NOT registered here
    /// because esc-as-0x1B must keep flowing to the terminal when the
    /// find bar is closed; the FindBar handles esc itself via SwiftUI
    /// `.onKeyPress(.escape)` while its input has first responder.
    var onFindShortcut: ((TesseraFindShortcut) -> Void)?

    /// Invoked for the session-switcher chords: ⌘K opens the quick-
    /// switch palette; ⌘⇧K/⌘⇧J step to the previous/next session (moved
    /// off the bare brackets, which now cycle panes). The owner translates
    /// these into palette / `SessionSwitcher.step` calls; nil means the
    /// chord is a no-op.
    var onSwitcherShortcut: ((TesseraSwitcherShortcut) -> Void)?

    /// Invoked when ⌘, fires — the platform-standard "open Settings"
    /// chord. The owner routes it to `selectedItem = .settings`. ⌘, is
    /// a convention, not an OS-reserved chord, so iPadOS delivers it to
    /// the app; as punctuation it's matched across the responder chain
    /// before SwiftTerm's first responder can swallow it (same path the
    /// ⌘[/⌘] switcher chords ride). nil means the chord is a no-op.
    var onOpenSettings: (() -> Void)?

    /// ID of the TerminalTheme last installed via `installColors`. Cached so
    /// `TerminalSurfaceBound.applyAppearance` only re-paints the canvas + ANSI
    /// palette when the user actually picks a different theme — avoids a full
    /// repaint on every font-size or cursor-blink tweak in updateUIView.
    var appliedThemeID: String?
    var appliedScrollbackLines: Int?

    /// Default terminal colors reported for OSC 10/11 queries and used
    /// for iTerm-style minimum contrast adjustment.
    var terminalDefaultBackgroundRGB = 0x000000
    var terminalDefaultForegroundRGB = 0xD4D4D4
    var terminalMinimumContrast = 0.30

    override init(frame: CGRect) {
        self.terminalView = TerminalView(frame: .zero)
        super.init(frame: frame)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []

        // §R4.6 find-in-scrollback. Always on regardless of tmux mode.
        // ⌘F opens the bar; ⌘G / ⇧⌘G navigate matches even when the
        // bar isn't visible (mirrors iTerm2's "find again works without
        // re-opening the find bar" convention).
        commands.append(contentsOf: [
            UIKeyCommand(input: "f",
                         modifierFlags: .command,
                         action: #selector(findOpen)),
            UIKeyCommand(input: "g",
                         modifierFlags: .command,
                         action: #selector(findNextMatch)),
            UIKeyCommand(input: "g",
                         modifierFlags: [.command, .shift],
                         action: #selector(findPreviousMatch)),
        ])

        // Session-switcher chords. Always on — the user expects these
        // whether they're in tmux mode or passthrough.
        //   ⌘K  → open the quick-switch palette
        //   ⌘⇧K → switch to the previous session (up the sidebar list)
        //   ⌘⇧J → switch to the next session (down the sidebar list)
        // The bare ⌘[/⌘] brackets were RELOCATED off session switching so
        // the cheap bracket chords can drive in-window pane cycling (iTerm2
        // parity — pane switching is the high-frequency action). See the
        // tmux block below for the ⌘[/⌘] pane-cycle bindings.
        //
        // These are UIKeyCommands rather than pressesBegan hooks: when a
        // SwiftTerm TerminalView holds first responder it consumes raw
        // key presses before they propagate up the chain, but for
        // *letter/punctuation* keys UIKit matches keyCommands across the
        // whole responder chain *before* delivering the press, so a
        // command registered here wins — the same path the tmux ⌘⇧[ /
        // ⌘⇧] window chords ride.
        //
        // Three earlier chords failed and are documented here so they
        // don't get re-tried: ⌃Tab (iPadOS's focus engine claims
        // Tab-family keys and swallows it before the chain sees it);
        // ⌘↑/⌘↓ (arrow keys are consumed by SwiftTerm's UITextInput
        // first responder and never reach an *ancestor's* keyCommands —
        // `wantsPriorityOverSystemBehavior` can't help a command that's
        // never consulted); and ⌘⌥[ / ⌘⌥] (Option remaps "[" to a
        // different glyph, so a command registered for input "[" with
        // `.alternate` never matches — confirmed on-device: the selector
        // never fired). Plain ⌘⇧+letter avoids all three: Shift doesn't
        // remap the base char, so ⌘⇧J/⌘⇧K match like the ⌘⇧[ window chords.
        // See SessionSwitcher.swift.
        commands.append(
            UIKeyCommand(input: "k",
                         modifierFlags: .command,
                         action: #selector(switcherOpenPalette))
        )
        let prevCommand = UIKeyCommand(input: "k",
                                       modifierFlags: [.command, .shift],
                                       action: #selector(switcherCyclePrevious))
        prevCommand.wantsPriorityOverSystemBehavior = true
        commands.append(prevCommand)
        let nextCommand = UIKeyCommand(input: "j",
                                       modifierFlags: [.command, .shift],
                                       action: #selector(switcherCycleNext))
        nextCommand.wantsPriorityOverSystemBehavior = true
        commands.append(nextCommand)

        // ⌘, → open Settings. Always on, like find and the switcher —
        // the user expects the standard preferences chord whether
        // they're in tmux mode or passthrough.
        commands.append(
            UIKeyCommand(input: ",",
                         modifierFlags: .command,
                         action: #selector(openSettings))
        )

        if tmuxShortcutsEnabled {
            let splitPaneHorizontalCommand = UIKeyCommand(input: "d",
                                                          modifierFlags: .command,
                                                          action: #selector(tmuxSplitPaneHorizontal))
            splitPaneHorizontalCommand.wantsPriorityOverSystemBehavior = true
            let splitPaneVerticalCommand = UIKeyCommand(input: "d",
                                                        modifierFlags: [.command, .shift],
                                                        action: #selector(tmuxSplitPaneVertical))
            splitPaneVerticalCommand.wantsPriorityOverSystemBehavior = true

            // Bare ⌘[/⌘] cycle panes within the focused window (DFS order),
            // matching iTerm2. Gated by `multiPaneActive` in canPerformAction
            // so they no-op on the single-pane shared terminal (the session
            // switcher moved to ⌘⇧K/⌘⇧J). ⌘⇧Return toggles zoom on the
            // focused pane.
            let paneCyclePreviousCommand = UIKeyCommand(input: "[",
                                                        modifierFlags: .command,
                                                        action: #selector(tmuxPaneCyclePrevious))
            paneCyclePreviousCommand.wantsPriorityOverSystemBehavior = true
            let paneCycleNextCommand = UIKeyCommand(input: "]",
                                                    modifierFlags: .command,
                                                    action: #selector(tmuxPaneCycleNext))
            paneCycleNextCommand.wantsPriorityOverSystemBehavior = true
            let zoomPaneCommand = UIKeyCommand(input: "\r",
                                               modifierFlags: [.command, .shift],
                                               action: #selector(tmuxZoomPane))
            zoomPaneCommand.wantsPriorityOverSystemBehavior = true

            commands.append(contentsOf: [
                UIKeyCommand(input: "t",
                             modifierFlags: .command,
                             action: #selector(tmuxNewWindow)),
                UIKeyCommand(input: "w",
                             modifierFlags: [.command, .shift],
                             action: #selector(tmuxKillWindow)),
                UIKeyCommand(input: "[",
                             modifierFlags: [.command, .shift],
                             action: #selector(tmuxPreviousWindow)),
                UIKeyCommand(input: "]",
                             modifierFlags: [.command, .shift],
                             action: #selector(tmuxNextWindow)),
                splitPaneHorizontalCommand,
                splitPaneVerticalCommand,
                paneCyclePreviousCommand,
                paneCycleNextCommand,
                zoomPaneCommand,
                UIKeyCommand(input: "1", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "2", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "3", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "4", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "5", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "6", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "7", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "8", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
                UIKeyCommand(input: "9", modifierFlags: .command,
                             action: #selector(tmuxSelectWindow(_:))),
            ])
        }

        return commands
    }

    override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool {
        switch action {
        case #selector(tmuxNewWindow),
             #selector(tmuxKillWindow),
             #selector(tmuxPreviousWindow),
             #selector(tmuxNextWindow),
             #selector(tmuxSplitPaneHorizontal),
             #selector(tmuxSplitPaneVertical),
             #selector(tmuxSelectWindow(_:)):
            return tmuxShortcutsEnabled
        case #selector(tmuxPaneCyclePrevious),
             #selector(tmuxPaneCycleNext),
             #selector(tmuxZoomPane):
            // Pane-only chords: live only on a mounted grid surface, so the
            // bare ⌘[/⌘] / ⌘⇧Return no-op on the single-pane terminal and in
            // no-tmux passthrough (where they fall through to nothing).
            return tmuxShortcutsEnabled && multiPaneActive
        case #selector(findOpen),
             #selector(findNextMatch),
             #selector(findPreviousMatch):
            return onFindShortcut != nil
        case #selector(switcherOpenPalette),
             #selector(switcherCyclePrevious),
             #selector(switcherCycleNext):
            return onSwitcherShortcut != nil
        case #selector(openSettings):
            return onOpenSettings != nil
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc private func tmuxNewWindow() {
        onTmuxShortcut?(.newWindow)
    }

    @objc private func tmuxKillWindow() {
        onTmuxShortcut?(.killCurrentWindow)
    }

    @objc private func tmuxPreviousWindow() {
        onTmuxShortcut?(.previousWindow)
    }

    @objc private func tmuxNextWindow() {
        onTmuxShortcut?(.nextWindow)
    }

    @objc private func tmuxSplitPaneHorizontal() {
        onTmuxShortcut?(.splitPaneHorizontal)
    }

    @objc private func tmuxSplitPaneVertical() {
        onTmuxShortcut?(.splitPaneVertical)
    }

    @objc private func tmuxPaneCyclePrevious() {
        onTmuxShortcut?(.cyclePanePrevious)
    }

    @objc private func tmuxPaneCycleNext() {
        onTmuxShortcut?(.cyclePaneNext)
    }

    @objc private func tmuxZoomPane() {
        onTmuxShortcut?(.zoomPane)
    }

    @objc private func tmuxSelectWindow(_ sender: UIKeyCommand) {
        // sender.input carries the digit that fired the command. We
        // only register "1".."9" so the guards are defensive, not
        // load-bearing, but cheap.
        guard let input = sender.input,
              let n = Int(input),
              (1...9).contains(n)
        else { return }
        onTmuxShortcut?(.selectWindow(position: n))
    }

    @objc private func findOpen() {
        onFindShortcut?(.open)
    }

    @objc private func findNextMatch() {
        onFindShortcut?(.next)
    }

    @objc private func findPreviousMatch() {
        onFindShortcut?(.previous)
    }

    @objc private func switcherOpenPalette() {
        onSwitcherShortcut?(.openPalette)
    }

    @objc private func switcherCyclePrevious() {
        onSwitcherShortcut?(.cyclePrevious)
    }

    @objc private func switcherCycleNext() {
        onSwitcherShortcut?(.cycleNext)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

}

/// Applies an iTerm-style minimum contrast floor to truecolor foreground SGR.
/// OSC 10/11 reporting should give applications the right colors up front;
/// this keeps already-emitted low-contrast truecolor text readable.
struct TerminalOutputContrastFilter {
    private var pendingControlBytes: [UInt8] = []
    private var state = RenderState()

    mutating func process(
        _ bytes: ArraySlice<UInt8>,
        defaultBackgroundRGB: Int,
        defaultForegroundRGB: Int,
        minimumContrast: Double
    ) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }

        var input = pendingControlBytes
        input.append(contentsOf: bytes)
        pendingControlBytes.removeAll(keepingCapacity: true)

        let defaultBackground = TerminalRGB(rgb: defaultBackgroundRGB)
        let defaultForeground = TerminalRGB(rgb: defaultForegroundRGB)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)

        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x1B {
                guard index + 1 < input.count else {
                    pendingControlBytes = Array(input[index...])
                    break
                }

                let next = input[index + 1]
                if next == 0x5B {
                    guard let finalIndex = Self.csiFinalIndex(in: input, startingAt: index + 2) else {
                        pendingControlBytes = Array(input[index...])
                        break
                    }
                    output.append(contentsOf: input[index...(index + 1)])
                    if input[finalIndex] == 0x6D {
                        output.append(contentsOf: rewriteSGRPayload(
                            input[(index + 2)..<finalIndex],
                            defaultBackground: defaultBackground,
                            defaultForeground: defaultForeground,
                            minimumContrast: minimumContrast
                        ))
                    } else {
                        output.append(contentsOf: input[(index + 2)..<finalIndex])
                    }
                    output.append(input[finalIndex])
                    index = finalIndex + 1
                    continue
                }

                if next == 0x5D {
                    guard let terminatorIndex = Self.oscTerminatorIndex(in: input, startingAt: index + 2) else {
                        pendingControlBytes = Array(input[index...])
                        break
                    }
                    output.append(contentsOf: input[index...terminatorIndex])
                    index = terminatorIndex + 1
                    continue
                }

                output.append(contentsOf: input[index...(index + 1)])
                index += 2
                continue
            }

            if byte == 0x9B {
                guard let finalIndex = Self.csiFinalIndex(in: input, startingAt: index + 1) else {
                    pendingControlBytes = Array(input[index...])
                    break
                }
                output.append(byte)
                if input[finalIndex] == 0x6D {
                    output.append(contentsOf: rewriteSGRPayload(
                        input[(index + 1)..<finalIndex],
                        defaultBackground: defaultBackground,
                        defaultForeground: defaultForeground,
                        minimumContrast: minimumContrast
                    ))
                } else {
                    output.append(contentsOf: input[(index + 1)..<finalIndex])
                }
                output.append(input[finalIndex])
                index = finalIndex + 1
                continue
            }

            output.append(byte)
            index += 1
        }

        return output
    }

    private mutating func rewriteSGRPayload(
        _ payload: ArraySlice<UInt8>,
        defaultBackground: TerminalRGB,
        defaultForeground: TerminalRGB,
        minimumContrast: Double
    ) -> [UInt8] {
        guard var parameters = Self.sgrParameters(payload) else {
            return Array(payload)
        }

        let backgroundForForeground = state.backgroundAfterApplying(parameters)
            ?? defaultBackground
        var didRewrite = false
        var index = 0

        while index < parameters.count {
            let parameter = parameters[index]
            switch parameter {
            case 0:
                state.background = nil
            case 40...47, 100...107, 49:
                state.background = nil
            case 38, 48:
                let isForeground = parameter == 38
                guard index + 1 < parameters.count else { break }
                let mode = parameters[index + 1]
                if mode == 2, index + 4 < parameters.count {
                    let rgb = TerminalRGB(
                        red: parameters[index + 2],
                        green: parameters[index + 3],
                        blue: parameters[index + 4]
                    )
                    if isForeground {
                        let adjusted = Self.adjustedForeground(
                            rgb,
                            background: backgroundForForeground,
                            defaultForeground: defaultForeground,
                            minimumContrast: minimumContrast
                        )
                        if adjusted != rgb {
                            parameters[index + 2] = adjusted.red
                            parameters[index + 3] = adjusted.green
                            parameters[index + 4] = adjusted.blue
                            didRewrite = true
                        }
                    } else {
                        state.background = rgb
                    }
                    index += 4
                } else if mode == 5, index + 2 < parameters.count {
                    if !isForeground {
                        state.background = nil
                    }
                    index += 2
                } else {
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        guard didRewrite else { return Array(payload) }
        return Array(parameters.map(String.init).joined(separator: ";").utf8)
    }

    private static func adjustedForeground(
        _ foreground: TerminalRGB,
        background: TerminalRGB,
        defaultForeground: TerminalRGB,
        minimumContrast: Double
    ) -> TerminalRGB {
        let floor = max(0.0, min(1.0, minimumContrast))
        guard floor > 0 else { return foreground }

        let signedDelta = foreground.brightness - background.brightness
        let distance = abs(signedDelta)
        guard distance < floor else { return foreground }

        var direction: Double
        if abs(signedDelta) > 0.0001 {
            direction = signedDelta > 0 ? 1.0 : -1.0
        } else {
            direction = defaultForeground.brightness >= background.brightness ? 1.0 : -1.0
        }

        var maxDistance = direction > 0 ? 1.0 - background.brightness : background.brightness
        if maxDistance < floor {
            direction = -direction
            maxDistance = direction > 0 ? 1.0 - background.brightness : background.brightness
        }

        let preservedVariation = min(0.08, distance * 0.25)
        let targetDistance = min(maxDistance, floor + preservedVariation)
        let adjusted = foreground.movingBrightness(
            toward: background.brightness + direction * targetDistance
        )
        return adjusted == background ? defaultForeground : adjusted
    }

    private static func sgrParameters(_ payload: ArraySlice<UInt8>) -> [Int]? {
        let raw = String(decoding: payload, as: UTF8.self)
        guard !raw.isEmpty else { return [0] }

        var parameters: [Int] = []
        for token in raw.replacingOccurrences(of: ":", with: ";")
            .split(separator: ";", omittingEmptySubsequences: false) {
            if token.isEmpty {
                parameters.append(0)
            } else if let value = Int(token) {
                parameters.append(value)
            } else {
                return nil
            }
        }
        return parameters.isEmpty ? [0] : parameters
    }

    private static func csiFinalIndex(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if (0x40...0x7E).contains(bytes[index]) {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func oscTerminatorIndex(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x07 {
                return index
            }
            if bytes[index] == 0x1B,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x5C {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private struct RenderState {
        var background: TerminalRGB?

        func backgroundAfterApplying(_ parameters: [Int]) -> TerminalRGB? {
            var nextBackground = background
            var index = 0
            while index < parameters.count {
                switch parameters[index] {
                case 0, 40...47, 100...107, 49:
                    nextBackground = nil
                case 48:
                    guard index + 1 < parameters.count else { break }
                    let mode = parameters[index + 1]
                    if mode == 2, index + 4 < parameters.count {
                        nextBackground = TerminalRGB(
                            red: parameters[index + 2],
                            green: parameters[index + 3],
                            blue: parameters[index + 4]
                        )
                        index += 4
                    } else if mode == 5, index + 2 < parameters.count {
                        nextBackground = nil
                        index += 2
                    } else {
                        index += 1
                    }
                default:
                    break
                }
                index += 1
            }
            return nextBackground
        }
    }

    private struct TerminalRGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int

        init(red: Int, green: Int, blue: Int) {
            self.red = Self.clamped(red)
            self.green = Self.clamped(green)
            self.blue = Self.clamped(blue)
        }

        init(rgb: Int) {
            self.init(
                red: (rgb >> 16) & 0xFF,
                green: (rgb >> 8) & 0xFF,
                blue: rgb & 0xFF
            )
        }

        var brightness: Double {
            (0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue)) / 255.0
        }

        func movingBrightness(toward targetBrightness: Double) -> TerminalRGB {
            let current = brightness
            guard abs(targetBrightness - current) > 0.0001 else { return self }

            let target = max(0.0, min(1.0, targetBrightness))
            if target > current {
                let amount = (target - current) / max(0.0001, 1.0 - current)
                return mixed(toward: TerminalRGB(red: 255, green: 255, blue: 255), amount: amount)
            } else {
                let amount = (current - target) / max(0.0001, current)
                return mixed(toward: TerminalRGB(red: 0, green: 0, blue: 0), amount: amount)
            }
        }

        private func mixed(toward target: TerminalRGB, amount rawAmount: Double) -> TerminalRGB {
            let amount = max(0.0, min(1.0, rawAmount))
            return TerminalRGB(
                red: Int((Double(red) + Double(target.red - red) * amount).rounded()),
                green: Int((Double(green) + Double(target.green - green) * amount).rounded()),
                blue: Int((Double(blue) + Double(target.blue - blue) * amount).rounded())
            )
        }

        private static func clamped(_ value: Int) -> Int {
            max(0, min(255, value))
        }
    }
}

enum TerminalOSCColorResponseRewriter {
    struct Result {
        let bytes: [UInt8]
        let isColorQueryResponse: Bool
    }

    static func rewriteColorQueryResponse(
        _ data: ArraySlice<UInt8>,
        defaultForegroundRGB: Int,
        defaultBackgroundRGB: Int
    ) -> Result {
        let bytes = Array(data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var didRewrite = false
        var index = 0

        while index < bytes.count {
            guard let sequence = oscSequence(in: bytes, startingAt: index) else {
                output.append(bytes[index])
                index += 1
                continue
            }

            if sequence.start > index {
                output.append(contentsOf: bytes[index..<sequence.start])
            }

            if let rewritten = rewriteSingleOSCResponse(
                bytes[sequence.payload],
                defaultForegroundRGB: defaultForegroundRGB,
                defaultBackgroundRGB: defaultBackgroundRGB
            ) {
                output.append(contentsOf: rewritten)
                didRewrite = true
            } else {
                output.append(contentsOf: bytes[sequence.start..<sequence.end])
            }
            index = sequence.end
        }

        guard didRewrite else {
            return Result(bytes: bytes, isColorQueryResponse: false)
        }
        return Result(bytes: output, isColorQueryResponse: true)
    }

    private static func rewriteSingleOSCResponse(
        _ payloadBytes: ArraySlice<UInt8>,
        defaultForegroundRGB: Int,
        defaultBackgroundRGB: Int
    ) -> [UInt8]? {
        guard let payload = String(bytes: payloadBytes, encoding: .ascii),
              let separator = payload.firstIndex(of: ";"),
              payload[payload.index(after: separator)...].hasPrefix("rgb:")
        else { return nil }

        switch payload[..<separator] {
        case "10":
            return oscResponse(code: 10, rgb: defaultForegroundRGB)
        case "11":
            return oscResponse(code: 11, rgb: defaultBackgroundRGB)
        default:
            return nil
        }
    }

    private struct OSCSequence {
        let start: Int
        let payload: Range<Int>
        let end: Int
    }

    private static func oscSequence(in bytes: [UInt8], startingAt start: Int) -> OSCSequence? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x9D
                || (bytes[index] == 0x1B
                    && index + 1 < bytes.count
                    && bytes[index + 1] == 0x5D) {
                break
            }
            index += 1
        }
        guard index < bytes.count else { return nil }

        let payloadStart: Int
        if bytes[index] == 0x1B {
            payloadStart = index + 2
        } else {
            payloadStart = index + 1
        }

        var terminator = payloadStart
        while terminator < bytes.count {
            if bytes[terminator] == 0x07 || bytes[terminator] == 0x9C {
                return OSCSequence(
                    start: index,
                    payload: payloadStart..<terminator,
                    end: terminator + 1
                )
            }
            if bytes[terminator] == 0x1B,
               terminator + 1 < bytes.count,
               bytes[terminator + 1] == 0x5C {
                return OSCSequence(
                    start: index,
                    payload: payloadStart..<terminator,
                    end: terminator + 2
                )
            }
            terminator += 1
        }
        return nil
    }

    private static func oscResponse(code: Int, rgb: Int) -> [UInt8] {
        Array("\u{1B}]\(code);\(xColor(rgb: rgb))\u{1B}\\".utf8)
    }

    private static func xColor(rgb: Int) -> String {
        let red = (rgb >> 16) & 0xFF
        let green = (rgb >> 8) & 0xFF
        let blue = rgb & 0xFF
        return String(
            format: "rgb:%02x%02x/%02x%02x/%02x%02x",
            red, red,
            green, green,
            blue, blue
        )
    }
}

@MainActor
final class TerminalOSCColorQueryResponder {
    private var states: [String: StreamState] = [:]

    func responses(
        for data: ArraySlice<UInt8>,
        streamID: String,
        defaultForegroundRGB: Int,
        defaultBackgroundRGB: Int
    ) -> [UInt8] {
        var state = states[streamID] ?? StreamState()
        let response = state.responses(
            for: data,
            defaultForegroundRGB: defaultForegroundRGB,
            defaultBackgroundRGB: defaultBackgroundRGB
        )
        states[streamID] = state
        return response
    }

    private struct StreamState {
        private var pendingControlBytes: [UInt8] = []

        mutating func responses(
            for data: ArraySlice<UInt8>,
            defaultForegroundRGB: Int,
            defaultBackgroundRGB: Int
        ) -> [UInt8] {
            var bytes = pendingControlBytes
            bytes.append(contentsOf: data)
            pendingControlBytes.removeAll(keepingCapacity: true)

            var response: [UInt8] = []
            var index = 0
            while index < bytes.count {
                guard let sequence = Self.oscSequence(in: bytes, startingAt: index) else {
                    let tail = bytes[index...]
                    if let oscStart = Self.incompleteOSCStart(in: tail) {
                        pendingControlBytes = Array(bytes[oscStart...])
                    } else if Self.isIncompleteControlTail(tail) {
                        pendingControlBytes = Array(tail)
                    }
                    break
                }

                if sequence.start > index,
                   Self.isIncompleteControlTail(bytes[index..<sequence.start]) {
                    pendingControlBytes = Array(bytes[index..<sequence.start])
                    break
                }

                let payload = String(decoding: bytes[sequence.payload], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch payload {
                case "10;?":
                    response.append(contentsOf: Self.oscResponse(
                        code: 10,
                        rgb: defaultForegroundRGB
                    ))
                case "11;?":
                    response.append(contentsOf: Self.oscResponse(
                        code: 11,
                        rgb: defaultBackgroundRGB
                    ))
                default:
                    break
                }
                index = sequence.end
            }
            return response
        }

        private struct OSCSequence {
            let start: Int
            let payload: Range<Int>
            let end: Int
        }

        private static func oscSequence(in bytes: [UInt8], startingAt start: Int) -> OSCSequence? {
            var index = start
            while index < bytes.count {
                if bytes[index] == 0x9D
                    || (bytes[index] == 0x1B
                        && index + 1 < bytes.count
                        && bytes[index + 1] == 0x5D) {
                    break
                }
                index += 1
            }
            guard index < bytes.count else { return nil }

            let payloadStart = bytes[index] == 0x1B ? index + 2 : index + 1
            var terminator = payloadStart
            while terminator < bytes.count {
                if bytes[terminator] == 0x07 || bytes[terminator] == 0x9C {
                    return OSCSequence(
                        start: index,
                        payload: payloadStart..<terminator,
                        end: terminator + 1
                    )
                }
                if bytes[terminator] == 0x1B,
                   terminator + 1 < bytes.count,
                   bytes[terminator + 1] == 0x5C {
                    return OSCSequence(
                        start: index,
                        payload: payloadStart..<terminator,
                        end: terminator + 2
                    )
                }
                terminator += 1
            }
            return nil
        }

        private static func incompleteOSCStart(in bytes: ArraySlice<UInt8>) -> Int? {
            var index = bytes.startIndex
            while index < bytes.endIndex {
                if bytes[index] == 0x9D {
                    return index
                }
                if bytes[index] == 0x1B,
                   index + 1 < bytes.endIndex,
                   bytes[index + 1] == 0x5D {
                    return index
                }
                index += 1
            }
            return nil
        }

        private static func isIncompleteControlTail(_ bytes: ArraySlice<UInt8>) -> Bool {
            guard !bytes.isEmpty else { return false }
            if bytes.last == 0x1B { return true }
            if bytes.count >= 2 {
                let tail = Array(bytes.suffix(2))
                return tail[0] == 0x1B && tail[1] == 0x5D
            }
            return false
        }

        private static func oscResponse(code: Int, rgb: Int) -> [UInt8] {
            Array("\u{1B}]\(code);\(xColor(rgb: rgb))\u{1B}\\".utf8)
        }

        private static func xColor(rgb: Int) -> String {
            let red = (rgb >> 16) & 0xFF
            let green = (rgb >> 8) & 0xFF
            let blue = rgb & 0xFF
            return String(
                format: "rgb:%02x%02x/%02x%02x/%02x%02x",
                red, red,
                green, green,
                blue, blue
            )
        }
    }
}

/// Discriminator for tmux keyboard shortcuts fired from the terminal
/// container. The view stays ignorant of the `TmuxController` API —
/// the owner translates these cases into control-mode commands.
enum TesseraTmuxShortcut {
    case newWindow
    case killCurrentWindow
    case previousWindow
    case nextWindow
    case splitPaneHorizontal
    case splitPaneVertical
    case cyclePaneNext
    case cyclePanePrevious
    case zoomPane
    case selectWindow(position: Int)
}

/// Discriminator for find-in-scrollback shortcuts (§R4.6). The
/// container stays ignorant of FindController — the owner forwards
/// each case into `controller.open()` / `next()` / `previous()`.
enum TesseraFindShortcut {
    case open
    case next
    case previous
}

/// Discriminator for session-switcher chords. `openPalette` is the
/// ⌘K quick switcher; `cyclePrevious` (⌘⇧K) and `cycleNext` (⌘⇧J) step
/// to the neighbouring session in sidebar order. Each press is an
/// immediate switch — no hold-to-cycle, no settle timer. The owner
/// resolves the target via `SessionSwitcher.step`. (The bare ⌘[/⌘]
/// brackets were reassigned to in-window pane cycling.)
enum TesseraSwitcherShortcut {
    case openPalette
    case cyclePrevious
    case cycleNext
}

/// Terminal-special hardware keys routed directly by the app instead
/// of allowing SwiftTerm to interpret them as local UI actions.
enum TesseraTerminalHardwareKey {
    case pageUp
    case pageDown

    var escapeSequence: [UInt8] {
        switch self {
        case .pageUp:
            return [0x1B, 0x5B, 0x35, 0x7E]
        case .pageDown:
            return [0x1B, 0x5B, 0x36, 0x7E]
        }
    }
}

/// Converts SwiftTerm's enhanced keyboard encodings back to the legacy bytes
/// readline-oriented shells expect when we are at the shell prompt.
enum TerminalInputNormalizer {
    static func normalizeNormalBufferInput(_ data: ArraySlice<UInt8>) -> [UInt8] {
        normalizeCompleteInput(Array(data))
    }

    static func normalizeNormalBufferInput(
        _ data: ArraySlice<UInt8>,
        pending: inout [UInt8]
    ) -> [UInt8] {
        var bytes = pending
        bytes.append(contentsOf: data)
        pending.removeAll(keepingCapacity: true)

        var output: [UInt8] = []
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x1B,
                  index + 1 < bytes.count,
                  bytes[index + 1] == 0x5B
            else {
                output.append(bytes[index])
                index += 1
                continue
            }

            guard let finalIndex = completeCSIEndIndex(in: bytes, startingAt: index) else {
                if isIncompleteCSIPrefix(ArraySlice(bytes[index..<bytes.count])) {
                    pending.append(contentsOf: bytes[index..<bytes.count])
                    break
                }

                output.append(bytes[index])
                index += 1
                continue
            }

            let sequence = ArraySlice(bytes[index...finalIndex])
            output.append(contentsOf: normalizeCompleteInput(sequence))
            index = finalIndex + 1
        }

        return output
    }

    private static func normalizeCompleteInput(_ data: ArraySlice<UInt8>) -> [UInt8] {
        legacyControlBytes(forExactCSIu: data)
            ?? legacyOptionArrowBytes(forExactCSI: data)
            ?? legacyOptionBackspaceBytes(forExactCSIu: data)
            ?? Array(data)
    }

    private static func normalizeCompleteInput(_ bytes: [UInt8]) -> [UInt8] {
        normalizeCompleteInput(bytes[...])
    }

    private static func legacyControlBytes(forExactCSIu data: ArraySlice<UInt8>) -> [UInt8]? {
        guard let sequence = parseExactCSI(data),
              sequence.final == 0x75
        else { return nil }

        guard let keyCode = sequence.leadingNumber,
              let modifier = sequence.modifier
        else { return nil }

        let rawModifiers = modifier.value - 1
        let ctrlBit = 1 << 2
        let nonLegacyModifierBits = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 4) | (1 << 5)
        guard rawModifiers & ctrlBit != 0,
              rawModifiers & nonLegacyModifierBits == 0
        else { return nil }

        let eventType = parseEventType(in: sequence.body, afterModifierFieldEndingAt: modifier.endIndex)
        if eventType == 3 {
            return []
        }
        guard eventType == nil || eventType == 1 || eventType == 2 else { return nil }
        guard let byte = legacyControlByte(for: keyCode) else { return nil }
        return [byte]
    }

    private static func legacyOptionArrowBytes(forExactCSI data: ArraySlice<UInt8>) -> [UInt8]? {
        guard let sequence = parseExactCSI(data),
              sequence.final == 0x44 || sequence.final == 0x43,
              sequence.leadingNumber == 1,
              let modifier = sequence.modifier,
              modifier.value == 3
        else { return nil }

        let eventType = parseEventType(in: sequence.body, afterModifierFieldEndingAt: modifier.endIndex)
        if eventType == 3 {
            return []
        }
        guard eventType == nil || eventType == 1 || eventType == 2 else { return nil }

        // readline's default macOS-compatible word movement bindings.
        return sequence.final == 0x44 ? [0x1B, 0x62] : [0x1B, 0x66]
    }

    private static func legacyOptionBackspaceBytes(forExactCSIu data: ArraySlice<UInt8>) -> [UInt8]? {
        guard let sequence = parseExactCSI(data),
              sequence.final == 0x75,
              sequence.leadingNumber == 127 || sequence.leadingNumber == 8,
              let modifier = sequence.modifier,
              modifier.value == 3
        else { return nil }

        let eventType = parseEventType(in: sequence.body, afterModifierFieldEndingAt: modifier.endIndex)
        if eventType == 3 {
            return []
        }
        guard eventType == nil || eventType == 1 || eventType == 2 else { return nil }

        return [0x1B, 0x7F]
    }

    private struct CSISequence {
        let body: ArraySlice<UInt8>
        let final: UInt8

        var leadingNumber: Int? {
            guard let firstSeparator = body.firstIndex(where: { $0 == 0x3B || $0 == 0x3A }) else {
                return TerminalInputNormalizer.parseLeadingInt(body)
            }
            return TerminalInputNormalizer.parseLeadingInt(body[body.startIndex..<firstSeparator])
        }

        var modifier: (value: Int, endIndex: Int)? {
            guard let semicolon = body.firstIndex(of: 0x3B) else { return nil }

            let modifierStart = semicolon + 1
            guard modifierStart < body.endIndex else { return nil }
            let modifierFieldEnd = body[modifierStart..<body.endIndex].firstIndex { $0 == 0x3A || $0 == 0x3B }
                ?? body.endIndex
            guard let value = TerminalInputNormalizer.parseLeadingInt(body[modifierStart..<modifierFieldEnd]),
                  value > 0
            else { return nil }

            return (value, modifierFieldEnd)
        }
    }

    private static func parseExactCSI(_ data: ArraySlice<UInt8>) -> CSISequence? {
        let bytes = Array(data)
        guard bytes.count >= 3,
              bytes[0] == 0x1B,
              bytes[1] == 0x5B,
              let final = bytes.last,
              isCSIFinalByte(final)
        else { return nil }

        return CSISequence(
            body: bytes[2..<(bytes.count - 1)],
            final: final
        )
    }

    private static func completeCSIEndIndex(in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard start + 1 < bytes.count,
              bytes[start] == 0x1B,
              bytes[start + 1] == 0x5B
        else { return nil }

        var index = start + 2
        while index < bytes.count {
            let byte = bytes[index]
            if isCSIFinalByte(byte) {
                return index
            }
            if !isCSIParameterOrIntermediateByte(byte) {
                return nil
            }
            index += 1
        }

        return nil
    }

    private static func isIncompleteCSIPrefix(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 2,
              bytes[bytes.startIndex] == 0x1B,
              bytes[bytes.startIndex + 1] == 0x5B
        else { return false }

        for byte in bytes.dropFirst(2) {
            if !isCSIParameterOrIntermediateByte(byte) {
                return false
            }
        }
        return true
    }

    private static func isCSIFinalByte(_ byte: UInt8) -> Bool {
        byte >= 0x40 && byte <= 0x7E
    }

    private static func isCSIParameterOrIntermediateByte(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x3F
    }

    private static func parseLeadingInt(_ bytes: ArraySlice<UInt8>) -> Int? {
        var value = 0
        var sawDigit = false

        for byte in bytes {
            guard byte >= 0x30, byte <= 0x39 else { break }
            sawDigit = true
            value = value * 10 + Int(byte - 0x30)
        }

        return sawDigit ? value : nil
    }

    private static func parseEventType(
        in body: ArraySlice<UInt8>,
        afterModifierFieldEndingAt index: Int
    ) -> Int? {
        guard index < body.endIndex,
              body[index] == 0x3A
        else { return nil }

        let eventStart = index + 1
        guard eventStart < body.endIndex else { return nil }
        let eventEnd = body[eventStart..<body.endIndex].firstIndex(of: 0x3B) ?? body.endIndex
        return parseLeadingInt(body[eventStart..<eventEnd])
    }

    private static func legacyControlByte(for keyCode: Int) -> UInt8? {
        switch keyCode {
        case 0, 32, 50, 64:
            return 0x00
        case 9:
            return 0x09
        case 13:
            return 0x0D
        case 27, 51, 91:
            return 0x1B
        case 52, 92:
            return 0x1C
        case 53, 93:
            return 0x1D
        case 54, 94, 126:
            return 0x1E
        case 47, 55, 95:
            return 0x1F
        case 56, 63, 127:
            return 0x7F
        case 65...90:
            return UInt8(keyCode - 64)
        case 97...122:
            return UInt8(keyCode - 96)
        default:
            return nil
        }
    }
}
