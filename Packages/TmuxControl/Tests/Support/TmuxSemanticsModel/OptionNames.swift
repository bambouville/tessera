// Generated from each release's options-table.c: the names of options_table[]
// in table order (hooks included, as OPTIONS_TABLE_*HOOK entries are table
// entries) and options_other_names[]. options_match walks this order
// (options.c:636-676), so the order decides exact-versus-ambiguous results.

enum OptionNames {
    static func table(_ version: TmuxVersion) -> [String] {
        switch version {
        case .v3_2: v3_2
        case .v3_3a: v3_3a
        case .v3_4: v3_4
        case .v3_6a: v3_6a
        }
    }

    /// options_other_names (options_map_name, options.c:98-108).
    static func otherNames(_ version: TmuxVersion) -> [String: String] {
        switch version {
        case .v3_2: ["display-panes-color": "display-panes-colour", "display-panes-active-color": "display-panes-active-colour", "clock-mode-color": "clock-mode-colour"]
        case .v3_3a: ["display-panes-color": "display-panes-colour", "display-panes-active-color": "display-panes-active-colour", "clock-mode-color": "clock-mode-colour", "cursor-color": "cursor-colour", "pane-colors": "pane-colours"]
        case .v3_4: ["display-panes-color": "display-panes-colour", "display-panes-active-color": "display-panes-active-colour", "clock-mode-color": "clock-mode-colour", "cursor-color": "cursor-colour", "pane-colors": "pane-colours"]
        case .v3_6a: ["display-panes-color": "display-panes-colour", "display-panes-active-color": "display-panes-active-colour", "clock-mode-color": "clock-mode-colour", "cursor-color": "cursor-colour", "prompt-cursor-color": "prompt-cursor-colour", "pane-colors": "pane-colours"]
        }
    }

    /// 3.2 options-table.c:188-1151 (165 entries).
    static let v3_2: [String] = [
        "backspace", "buffer-limit", "command-alias", "copy-command", "default-terminal", "editor",
        "escape-time", "exit-empty", "exit-unattached", "extended-keys", "focus-events", "history-file",
        "message-limit", "set-clipboard", "terminal-overrides", "terminal-features", "user-keys",
        "activity-action", "assume-paste-time", "base-index", "bell-action", "default-command",
        "default-shell", "default-size", "destroy-unattached", "detach-on-destroy",
        "display-panes-active-colour", "display-panes-colour", "display-panes-time", "display-time",
        "history-limit", "key-table", "lock-after-time", "lock-command", "message-command-style",
        "message-style", "mouse", "prefix", "prefix2", "renumber-windows", "repeat-time", "set-titles",
        "set-titles-string", "silence-action", "status", "status-bg", "status-fg", "status-format",
        "status-interval", "status-justify", "status-keys", "status-left", "status-left-length",
        "status-left-style", "status-position", "status-right", "status-right-length", "status-right-style",
        "status-style", "update-environment", "visual-activity", "visual-bell", "visual-silence",
        "word-separators", "aggressive-resize", "allow-rename", "alternate-screen", "automatic-rename",
        "automatic-rename-format", "clock-mode-colour", "clock-mode-style", "copy-mode-match-style",
        "copy-mode-current-match-style", "copy-mode-mark-style", "main-pane-height", "main-pane-width",
        "mode-keys", "mode-style", "monitor-activity", "monitor-bell", "monitor-silence",
        "other-pane-height", "other-pane-width", "pane-active-border-style", "pane-base-index",
        "pane-border-format", "pane-border-lines", "pane-border-status", "pane-border-style",
        "remain-on-exit", "synchronize-panes", "window-active-style", "window-size", "window-style",
        "window-status-activity-style", "window-status-bell-style", "window-status-current-format",
        "window-status-current-style", "window-status-format", "window-status-last-style",
        "window-status-separator", "window-status-style", "wrap-search", "xterm-keys", "after-bind-key",
        "after-capture-pane", "after-copy-mode", "after-display-message", "after-display-panes",
        "after-kill-pane", "after-list-buffers", "after-list-clients", "after-list-keys", "after-list-panes",
        "after-list-sessions", "after-list-windows", "after-load-buffer", "after-lock-server",
        "after-new-session", "after-new-window", "after-paste-buffer", "after-pipe-pane", "after-queue",
        "after-refresh-client", "after-rename-session", "after-rename-window", "after-resize-pane",
        "after-resize-window", "after-save-buffer", "after-select-layout", "after-select-pane",
        "after-select-window", "after-send-keys", "after-set-buffer", "after-set-environment",
        "after-set-hook", "after-set-option", "after-show-environment", "after-show-messages",
        "after-show-options", "after-split-window", "after-unbind-key", "alert-activity", "alert-bell",
        "alert-silence", "client-attached", "client-detached", "client-resized", "client-session-changed",
        "pane-died", "pane-exited", "pane-focus-in", "pane-focus-out", "pane-mode-changed",
        "pane-set-clipboard", "pane-title-changed", "session-closed", "session-created", "session-renamed",
        "session-window-changed", "window-layout-changed", "window-linked", "window-pane-changed",
        "window-renamed", "window-unlinked",
    ]

    /// 3.3a options-table.c:203-1281 (181 entries).
    static let v3_3a: [String] = [
        "backspace", "buffer-limit", "command-alias", "copy-command", "cursor-colour", "cursor-style",
        "default-terminal", "editor", "escape-time", "exit-empty", "exit-unattached", "extended-keys",
        "focus-events", "history-file", "message-limit", "prompt-history-limit", "set-clipboard",
        "terminal-overrides", "terminal-features", "user-keys", "activity-action", "assume-paste-time",
        "base-index", "bell-action", "default-command", "default-shell", "default-size",
        "destroy-unattached", "detach-on-destroy", "display-panes-active-colour", "display-panes-colour",
        "display-panes-time", "display-time", "history-limit", "key-table", "lock-after-time",
        "lock-command", "message-command-style", "message-style", "mouse", "prefix", "prefix2",
        "renumber-windows", "repeat-time", "set-titles", "set-titles-string", "silence-action", "status",
        "status-bg", "status-fg", "status-format", "status-interval", "status-justify", "status-keys",
        "status-left", "status-left-length", "status-left-style", "status-position", "status-right",
        "status-right-length", "status-right-style", "status-style", "update-environment", "visual-activity",
        "visual-bell", "visual-silence", "word-separators", "aggressive-resize", "allow-passthrough",
        "allow-rename", "alternate-screen", "automatic-rename", "automatic-rename-format",
        "clock-mode-colour", "clock-mode-style", "copy-mode-match-style", "copy-mode-current-match-style",
        "copy-mode-mark-style", "fill-character", "main-pane-height", "main-pane-width", "mode-keys",
        "mode-style", "monitor-activity", "monitor-bell", "monitor-silence", "other-pane-height",
        "other-pane-width", "pane-active-border-style", "pane-base-index", "pane-border-format",
        "pane-border-indicators", "pane-border-lines", "pane-border-status", "pane-border-style",
        "pane-colours", "popup-style", "popup-border-style", "popup-border-lines", "remain-on-exit",
        "remain-on-exit-format", "scroll-on-clear", "synchronize-panes", "window-active-style",
        "window-size", "window-style", "window-status-activity-style", "window-status-bell-style",
        "window-status-current-format", "window-status-current-style", "window-status-format",
        "window-status-last-style", "window-status-separator", "window-status-style", "wrap-search",
        "xterm-keys", "after-bind-key", "after-capture-pane", "after-copy-mode", "after-display-message",
        "after-display-panes", "after-kill-pane", "after-list-buffers", "after-list-clients",
        "after-list-keys", "after-list-panes", "after-list-sessions", "after-list-windows",
        "after-load-buffer", "after-lock-server", "after-new-session", "after-new-window",
        "after-paste-buffer", "after-pipe-pane", "after-queue", "after-refresh-client",
        "after-rename-session", "after-rename-window", "after-resize-pane", "after-resize-window",
        "after-save-buffer", "after-select-layout", "after-select-pane", "after-select-window",
        "after-send-keys", "after-set-buffer", "after-set-environment", "after-set-hook", "after-set-option",
        "after-show-environment", "after-show-messages", "after-show-options", "after-split-window",
        "after-unbind-key", "alert-activity", "alert-bell", "alert-silence", "client-active",
        "client-attached", "client-detached", "client-focus-in", "client-focus-out", "client-resized",
        "client-session-changed", "pane-died", "pane-exited", "pane-focus-in", "pane-focus-out",
        "pane-mode-changed", "pane-set-clipboard", "pane-title-changed", "session-closed", "session-created",
        "session-renamed", "session-window-changed", "window-layout-changed", "window-linked",
        "window-pane-changed", "window-renamed", "window-resized", "window-unlinked",
    ]

    /// 3.4 options-table.c:212-1339 (186 entries).
    static let v3_4: [String] = [
        "backspace", "buffer-limit", "command-alias", "copy-command", "cursor-colour", "cursor-style",
        "default-terminal", "editor", "escape-time", "exit-empty", "exit-unattached", "extended-keys",
        "focus-events", "history-file", "menu-style", "menu-selected-style", "menu-border-style",
        "menu-border-lines", "message-limit", "prompt-history-limit", "set-clipboard", "terminal-overrides",
        "terminal-features", "user-keys", "activity-action", "assume-paste-time", "base-index",
        "bell-action", "default-command", "default-shell", "default-size", "destroy-unattached",
        "detach-on-destroy", "display-panes-active-colour", "display-panes-colour", "display-panes-time",
        "display-time", "history-limit", "key-table", "lock-after-time", "lock-command",
        "message-command-style", "message-line", "message-style", "mouse", "prefix", "prefix2",
        "renumber-windows", "repeat-time", "set-titles", "set-titles-string", "silence-action", "status",
        "status-bg", "status-fg", "status-format", "status-interval", "status-justify", "status-keys",
        "status-left", "status-left-length", "status-left-style", "status-position", "status-right",
        "status-right-length", "status-right-style", "status-style", "update-environment", "visual-activity",
        "visual-bell", "visual-silence", "word-separators", "aggressive-resize", "allow-passthrough",
        "allow-rename", "alternate-screen", "automatic-rename", "automatic-rename-format",
        "clock-mode-colour", "clock-mode-style", "copy-mode-match-style", "copy-mode-current-match-style",
        "copy-mode-mark-style", "fill-character", "main-pane-height", "main-pane-width", "mode-keys",
        "mode-style", "monitor-activity", "monitor-bell", "monitor-silence", "other-pane-height",
        "other-pane-width", "pane-active-border-style", "pane-base-index", "pane-border-format",
        "pane-border-indicators", "pane-border-lines", "pane-border-status", "pane-border-style",
        "pane-colours", "popup-style", "popup-border-style", "popup-border-lines", "remain-on-exit",
        "remain-on-exit-format", "scroll-on-clear", "synchronize-panes", "window-active-style",
        "window-size", "window-style", "window-status-activity-style", "window-status-bell-style",
        "window-status-current-format", "window-status-current-style", "window-status-format",
        "window-status-last-style", "window-status-separator", "window-status-style", "wrap-search",
        "xterm-keys", "after-bind-key", "after-capture-pane", "after-copy-mode", "after-display-message",
        "after-display-panes", "after-kill-pane", "after-list-buffers", "after-list-clients",
        "after-list-keys", "after-list-panes", "after-list-sessions", "after-list-windows",
        "after-load-buffer", "after-lock-server", "after-new-session", "after-new-window",
        "after-paste-buffer", "after-pipe-pane", "after-queue", "after-refresh-client",
        "after-rename-session", "after-rename-window", "after-resize-pane", "after-resize-window",
        "after-save-buffer", "after-select-layout", "after-select-pane", "after-select-window",
        "after-send-keys", "after-set-buffer", "after-set-environment", "after-set-hook", "after-set-option",
        "after-show-environment", "after-show-messages", "after-show-options", "after-split-window",
        "after-unbind-key", "alert-activity", "alert-bell", "alert-silence", "client-active",
        "client-attached", "client-detached", "client-focus-in", "client-focus-out", "client-resized",
        "client-session-changed", "pane-died", "pane-exited", "pane-focus-in", "pane-focus-out",
        "pane-mode-changed", "pane-set-clipboard", "pane-title-changed", "session-closed", "session-created",
        "session-renamed", "session-window-changed", "window-layout-changed", "window-linked",
        "window-pane-changed", "window-renamed", "window-resized", "window-unlinked",
    ]

    /// 3.6a options-table.c:272-1592 (210 entries).
    static let v3_6a: [String] = [
        "backspace", "buffer-limit", "command-alias", "codepoint-widths", "copy-command", "cursor-colour",
        "cursor-style", "default-client-command", "default-terminal", "editor", "escape-time", "exit-empty",
        "exit-unattached", "extended-keys", "extended-keys-format", "focus-events", "history-file",
        "input-buffer-size", "menu-style", "menu-selected-style", "menu-border-style", "menu-border-lines",
        "message-limit", "prefix-timeout", "prompt-history-limit", "set-clipboard", "terminal-overrides",
        "terminal-features", "user-keys", "variation-selector-always-wide", "activity-action",
        "assume-paste-time", "base-index", "bell-action", "default-command", "default-shell", "default-size",
        "destroy-unattached", "detach-on-destroy", "display-panes-active-colour", "display-panes-colour",
        "display-panes-time", "display-time", "history-limit", "initial-repeat-time", "key-table",
        "lock-after-time", "lock-command", "message-command-style", "message-line", "message-style", "mouse",
        "prefix", "prefix2", "renumber-windows", "repeat-time", "set-titles", "set-titles-string",
        "silence-action", "status", "status-bg", "status-fg", "status-format", "status-interval",
        "status-justify", "status-keys", "status-left", "status-left-length", "status-left-style",
        "status-position", "status-right", "status-right-length", "status-right-style", "status-style",
        "pane-status-current-style", "pane-status-style", "prompt-cursor-colour", "prompt-cursor-style",
        "session-status-current-style", "session-status-style", "update-environment", "visual-activity",
        "visual-bell", "visual-silence", "word-separators", "aggressive-resize", "allow-passthrough",
        "allow-rename", "allow-set-title", "alternate-screen", "automatic-rename", "automatic-rename-format",
        "clock-mode-colour", "clock-mode-style", "copy-mode-match-style", "copy-mode-current-match-style",
        "copy-mode-mark-style", "copy-mode-position-format", "copy-mode-position-style",
        "copy-mode-selection-style", "fill-character", "main-pane-height", "main-pane-width", "mode-keys",
        "mode-style", "monitor-activity", "monitor-bell", "monitor-silence", "other-pane-height",
        "other-pane-width", "pane-active-border-style", "pane-base-index", "pane-border-format",
        "pane-border-indicators", "pane-border-lines", "pane-border-status", "pane-border-style",
        "pane-colours", "pane-scrollbars", "pane-scrollbars-style", "pane-scrollbars-position",
        "popup-style", "popup-border-style", "popup-border-lines", "remain-on-exit", "remain-on-exit-format",
        "scroll-on-clear", "synchronize-panes", "tiled-layout-max-columns", "window-active-style",
        "window-size", "window-style", "window-status-activity-style", "window-status-bell-style",
        "window-status-current-format", "window-status-current-style", "window-status-format",
        "window-status-last-style", "window-status-separator", "window-status-style", "wrap-search",
        "xterm-keys", "after-bind-key", "after-capture-pane", "after-copy-mode", "after-display-message",
        "after-display-panes", "after-kill-pane", "after-list-buffers", "after-list-clients",
        "after-list-keys", "after-list-panes", "after-list-sessions", "after-list-windows",
        "after-load-buffer", "after-lock-server", "after-new-session", "after-new-window",
        "after-paste-buffer", "after-pipe-pane", "after-queue", "after-refresh-client",
        "after-rename-session", "after-rename-window", "after-resize-pane", "after-resize-window",
        "after-save-buffer", "after-select-layout", "after-select-pane", "after-select-window",
        "after-send-keys", "after-set-buffer", "after-set-environment", "after-set-hook", "after-set-option",
        "after-show-environment", "after-show-messages", "after-show-options", "after-split-window",
        "after-unbind-key", "alert-activity", "alert-bell", "alert-silence", "client-active",
        "client-attached", "client-detached", "client-focus-in", "client-focus-out", "client-resized",
        "client-session-changed", "client-light-theme", "client-dark-theme", "command-error", "pane-died",
        "pane-exited", "pane-focus-in", "pane-focus-out", "pane-mode-changed", "pane-set-clipboard",
        "pane-title-changed", "session-closed", "session-created", "session-renamed",
        "session-window-changed", "window-layout-changed", "window-linked", "window-pane-changed",
        "window-renamed", "window-resized", "window-unlinked",
    ]
}
