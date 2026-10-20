import Foundation

// Options: options.c, options-table.c and the scope rules of cmd-set-option.c.
// User options (`@name`) take the scope the flags give them; table options
// take the scope the table gives them. Sessions in a group never share
// options: each session has its own `options_create(global_s_options)`
// (cmd-new-session.c:262).

enum OptionScope {
    case server, session, window, pane
}

enum OptionKind {
    case choice([String])
    case flag
    case string
    case number
}

struct OptionEntry {
    let name: String
    let scope: OptionScope
    let kind: OptionKind
    let defaultValue: String
}

/// The subset of options-table.c the model implements. Any other table
/// option is valid tmux input the model does not implement (unsupported).
enum OptionTable {
    static func entries(for version: TmuxVersion) -> [OptionEntry] {
        entries.map { entry in
            // destroy-unattached is a flag in 3.2 and 3.3a (3.2
            // options-table.c:401-404, 3.3a :442-445) and a choice from 3.4
            // (options-table.c:87-89, 488-492; 3.6a :600-604).
            guard entry.name == "destroy-unattached", version >= .v3_4 else { return entry }
            return OptionEntry(name: entry.name, scope: entry.scope,
                               kind: .choice(["off", "on", "keep-last", "keep-group"]), defaultValue: "off")
        }
    }

    private static let entries: [OptionEntry] = [
        // options-table.c "window-size", default WINDOW_SIZE_LATEST (options-table.c:1170).
        OptionEntry(name: "window-size", scope: .window, kind: .choice(WindowSizePolicy.allCases.map(\.rawValue)), defaultValue: "latest"),
        OptionEntry(name: "aggressive-resize", scope: .window, kind: .flag, defaultValue: "off"),
        OptionEntry(name: "automatic-rename", scope: .window, kind: .flag, defaultValue: "on"),
        OptionEntry(name: "status", scope: .session, kind: .choice(["off", "on", "2", "3", "4", "5"]), defaultValue: "on"),
        // options-table.c "default-size" default "80x24" (options-table.c:484).
        OptionEntry(name: "default-size", scope: .session, kind: .string, defaultValue: "80x24"),
        OptionEntry(name: "mouse", scope: .session, kind: .flag, defaultValue: "off"),
        OptionEntry(name: "destroy-unattached", scope: .session, kind: .flag, defaultValue: "off"),
        OptionEntry(name: "base-index", scope: .session, kind: .number, defaultValue: "0"),
        OptionEntry(name: "focus-events", scope: .server, kind: .flag, defaultValue: "off"),
        OptionEntry(name: "exit-empty", scope: .server, kind: .flag, defaultValue: "on"),
    ]

    static func entry(_ name: String, version: TmuxVersion) -> OptionEntry? {
        entries(for: version).first { $0.name == name }
    }

    enum Match: Equatable {
        case found(String)
        case ambiguous
        case invalid
    }

    /// options_match (options.c:636-676) over the release's whole table
    /// (OptionNames): `@` names pass; old spellings are mapped first
    /// (options_map_name, options.c:98-108); then the table is walked in
    /// order, an exact name ends the walk, and a second prefix match before
    /// it is ambiguous.
    static func match(_ argument: String, version: TmuxVersion) -> Match {
        if argument.hasPrefix("@") { return .found(argument) }
        guard !argument.isEmpty else { return .invalid }
        let name = OptionNames.otherNames(version)[argument] ?? argument
        var found: String?
        for candidate in OptionNames.table(version) {
            if candidate == name { return .found(candidate) }
            if candidate.hasPrefix(name) {
                if found != nil { return .ambiguous }
                found = candidate
            }
        }
        return found.map { .found($0) } ?? .invalid
    }

    static func installDefaults(into model: TmuxServerModel) {
        for entry in entries(for: model.version) {
            switch entry.scope {
            case .server: model.serverOptions[entry.name] = entry.defaultValue
            case .session: model.globalSessionOptions[entry.name] = entry.defaultValue
            case .window, .pane: model.globalWindowOptions[entry.name] = entry.defaultValue
            }
        }
    }
}

/// options_scope_from_name's result: the options to use, or the cause.
enum ScopeResult {
    case success(OptionTarget)
    case failure(String)
}

/// Where an option write or read lands.
enum OptionTarget: Equatable {
    case server
    case globalSession
    case globalWindow
    case session(Int)
    case window(Int)
    case pane(Int)
}

extension TmuxServerModel {
    func flagOption(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["on", "yes", "1"].contains(value.lowercased())
    }

    /// options_get on a session: its own value, then global_s_options.
    func sessionOptionValue(_ session: SessionState, _ name: String) -> String? {
        session.options[name] ?? globalSessionOptions[name]
    }

    /// options_get on a window: its own value, then global_w_options.
    func windowOptionValue(_ window: WindowState, _ name: String) -> String? {
        window.options[name] ?? globalWindowOptions[name]
    }

    func store(_ target: OptionTarget) -> [String: String] {
        switch target {
        case .server: return serverOptions
        case .globalSession: return globalSessionOptions
        case .globalWindow: return globalWindowOptions
        case .session(let id): return sessionState(id).options
        case .window(let id): return windowState(id).options
        case .pane(let id): return windowState(id).paneOptions
        }
    }

    func setStored(_ target: OptionTarget, _ name: String, _ value: String?) {
        switch target {
        case .server: serverOptions[name] = value
        case .globalSession: globalSessionOptions[name] = value
        case .globalWindow: globalWindowOptions[name] = value
        case .session(let id): sessionState(id).options[name] = value
        case .window(let id): windowState(id).options[name] = value
        case .pane(let id): windowState(id).paneOptions[name] = value
        }
    }

    /// options_scope_from_flags (options.c:855-907), used for `@` options:
    /// `-s` server, `-p` pane, `-w` (or set-window-option) window, otherwise
    /// the target *session*. An untargeted set from a client lands on that
    /// client's own session (the target defaults to the client's current
    /// state, cmd-find.c:974-991).
    func scopeFromFlags(global: Bool, server: Bool, pane: Bool, window: Bool, state: FindState, explicitTarget: String?) -> ScopeResult {
        if server { return .success(.server) }
        if pane {
            guard let windowID = state.window else {
                return .failure(explicitTarget.map { "no such pane: \($0)" } ?? "no current pane")
            }
            return .success(.pane(windowID))
        }
        if window {
            if global { return .success(.globalWindow) }
            guard let windowID = state.window else {
                return .failure(explicitTarget.map { "no such window: \($0)" } ?? "no current window")
            }
            return .success(.window(windowID))
        }
        if global { return .success(.globalSession) }
        guard let sessionID = state.session else {
            return .failure(explicitTarget.map { "no such session: \($0)" } ?? "no current session")
        }
        return .success(.session(sessionID))
    }

    /// options_scope_from_name (options.c:784-852): table options use the
    /// table's scope; `@` options defer to scopeFromFlags.
    func scopeFromName(_ name: String, global: Bool, server: Bool, pane: Bool, window: Bool, state: FindState, explicitTarget: String?) -> ScopeResult {
        if name.hasPrefix("@") {
            return scopeFromFlags(global: global, server: server, pane: pane, window: window, state: state, explicitTarget: explicitTarget)
        }
        guard let entry = optionEntry(name) else { return .failure("unknown option: \(name)") }
        switch entry.scope {
        case .server:
            return .success(.server)
        case .session:
            if global { return .success(.globalSession) }
            guard let sessionID = state.session else {
                return .failure(explicitTarget.map { "no such session: \($0)" } ?? "no current session")
            }
            return .success(.session(sessionID))
        case .window, .pane:
            if pane, entry.scope == .pane {
                guard let windowID = state.window else {
                    return .failure(explicitTarget.map { "no such pane: \($0)" } ?? "no current pane")
                }
                return .success(.pane(windowID))
            }
            if global { return .success(.globalWindow) }
            guard let windowID = state.window else {
                return .failure(explicitTarget.map { "no such window: \($0)" } ?? "no current window")
            }
            return .success(.window(windowID))
        }
    }

    /// options_push_changes (options.c:1103-1168): after *every* successful
    /// set (user options included) tmux runs a deferred `recalculate_sizes()`
    /// and redraws every attached client (options.c:1163-1167).
    func pushOptionChanges(_ name: String) {
        optionPushes += 1
        recalculateSizes()
        for client in clients where client.sessionID != nil {
            redrawClient(client)
        }
    }

    /// format_find's option lookup (format.c:3573-3583): global server
    /// options, then the pane's options (whose parents are the window's and
    /// global window options), the window's, the global window options, the
    /// session's and the global session options. A window value therefore
    /// hides any session value of the same name (W1).
    func formatOption(_ name: String, session: SessionState?, window: WindowState?) -> String? {
        if let value = serverOptions[name] { return value }
        if let window {
            if let value = window.paneOptions[name] ?? window.options[name] ?? globalWindowOptions[name] { return value }
        }
        if let value = globalWindowOptions[name] { return value }
        if let session, let value = session.options[name] { return value }
        return globalSessionOptions[name]
    }
}
