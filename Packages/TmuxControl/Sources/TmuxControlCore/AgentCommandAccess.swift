/// Which Agent Center tmux commands leave grid authority unchanged (S5′, D13).
///
/// Reads and proved pane-targeted replies stay allowed while another device
/// holds the grid. A launch's `set-buffer`, `new-window -d`, `split-window -d`
/// adds to or splits the grid that device is using, so it waits on the
/// authority gate like the screen's own window commands. `delete-buffer`
/// only removes Tessera's own launch buffer, so a refused launch can still clean up.
public enum TmuxAgentCommandAccess {
    public static let readOnlyVerbs: Set<String> = [
        "display-message", "display", "capture-pane", "capturep", "show-options", "show",
        "list-panes", "list-windows", "list-sessions", "list-clients", "delete-buffer",
    ]

    /// Whether `command`'s verb, its first space-separated word, only reads.
    public static func isReadOnly(_ command: String) -> Bool {
        let verb = command.drop(while: \.isWhitespace).prefix { $0 != " " }
        return readOnlyVerbs.contains(String(verb))
    }

    /// Whether `command` only reads or sends exact bytes or one named key to
    /// a proved pane. tmux's `send-keys` does not select a window or pane,
    /// resize a client, or move `window-size latest`: latest moves on attach,
    /// tty input, non-control-client resize, lost-client reassignment or
    /// `select-window`. Other flags and targets must still pass the gate.
    public static func isAuthorityNeutral(_ command: String) -> Bool {
        if isReadOnly(command) { return true }
        guard !command.contains(where: { $0 == ";" || $0 == "\n" || $0 == "\r" }) else { return false }
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.count >= 4, tokens[0] == "send-keys", tokens[1] == "-t",
              tokens[2].first == "%", tokens[2].utf8.count > 1,
              tokens[2].utf8.dropFirst().allSatisfy({ (48...57).contains($0) })
        else { return false }
        if tokens[3] == "-H" {
            return tokens.count > 4 && tokens.dropFirst(4).allSatisfy { token in
                token.utf8.count == 2 && token.utf8.allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }
            }
        }
        return tokens.count == 4 && ["Enter", "Escape", "Tab", "BTab", "Up", "Down", "Left", "Right", "S-Left", "C-]"].contains(tokens[3])
    }
}
