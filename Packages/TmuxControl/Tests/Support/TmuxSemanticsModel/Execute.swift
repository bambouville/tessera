import Foundation

// Command execution: cmdq_fire_command (cmd-queue.c:596-672) and the exec
// functions of the modelled commands.

/// `struct cmdq_item` for a command while it runs.
final class CommandItem {
    let command: ParsedCommand
    let client: ClientState
    let state: CommandState
    var targetClient: ClientState?
    var target = FindState()

    init(command: ParsedCommand, client: ClientState, state: CommandState) {
        self.command = command
        self.client = client
        self.state = state
    }
}

enum CommandResult {
    case normal
    case error
}

extension TmuxServerModel {
    /// cmdq_fire_command (cmd-queue.c:596-672): `%begin`, the target client
    /// and target lookups, the exec, then `%end` or `%error`. Guard lines go
    /// only to a control client and carry flags 1 only for commands that came
    /// from control-mode input (cmd-queue.c:618; cmdq_guard,
    /// cmd-queue.c:816-824). Returns true when the command failed.
    func fireCommand(_ command: ParsedCommand, client: ClientState, state: CommandState, time: Int64, number: Int) -> Bool {
        let flags = state.control ? 1 : 0
        let item = CommandItem(command: command, client: client, state: state)
        write(client, "%begin \(time) \(number) \(flags)")
        let result = prepareAndExecute(item)
        switch result {
        case .normal: write(client, "%end \(time) \(number) \(flags)")
        case .error: write(client, "%error \(time) \(number) \(flags)")
        }
        return result == .error
    }

    private func prepareAndExecute(_ item: CommandItem) -> CommandResult {
        let spec = item.command.spec
        // cmd-queue.c:624-640.
        switch spec.client {
        case .current:
            item.targetClient = findClient(nil, issuer: item.client)
        case .tFlag(let quiet), .cFlag(let quiet):
            let flag: Character
            if case .tFlag = spec.client { flag = "t" } else { flag = "c" }
            let name = item.command.value(flag)
            let found = findClient(name.map(trimClientName), issuer: item.client)
            if found == nil, !quiet {
                commandError(item, name.map { "can't find client: \(trimClientName($0))" } ?? "no current client")
                return .error
            }
            item.targetClient = found
        }
        // cmdq_find_flag (cmd-queue.c:540-557) for the entry's target.
        if let target = spec.target {
            switch findTarget(item.command.value(target.flag), type: target.type, flags: target.flags, client: item.client, state: item.state) {
            case .found(let state):
                item.target = state
            case .failed(let message):
                if let message { commandError(item, message) }
                return .error
            }
        }
        switch spec.kind {
        case .attachSession: return executeAttachSession(item)
        case .selectWindow: return executeSelectWindow(item)
        case .refreshClient: return executeRefreshClient(item)
        case .resizeWindow: return executeResizeWindow(item)
        case .setOption, .setWindowOption: return executeSetOption(item)
        case .showOptions, .showWindowOptions: return executeShowOptions(item)
        case .displayMessage: return executeDisplayMessage(item)
        case .listClients: return executeListClients(item)
        }
    }

    /// cmd_find_client trims one trailing colon (cmd-find.c:1285-1288).
    private func trimClientName(_ name: String) -> String {
        name.hasSuffix(":") ? String(name.dropLast()) : name
    }

    /// cmdq_error (cmd-queue.c:853-890): a control client gets the text as a
    /// line inside its block; an unattached command client gets it on
    /// stderr; an attached terminal shows it as a status message.
    func commandError(_ item: CommandItem, _ message: String) {
        reportError(item.client, message)
    }

    /// cmdq_error's routes (cmd-queue.c:869-886): a control client gets a
    /// line, a client without a session gets stderr, and an attached terminal
    /// client gets a status message with its first letter capitalised.
    func reportError(_ client: ClientState, _ message: String) {
        if client.isControl {
            write(client, message)
        } else if client.sessionID == nil {
            client.errors.append(message)
        } else {
            client.statusMessages.append(message.prefix(1).uppercased() + message.dropFirst())
        }
    }

    /// cmdq_print → server_client_print (server-client.c:3274-3310).
    func commandPrint(_ item: CommandItem, _ message: String) {
        let client = item.client
        if client.isControl {
            write(client, message)
        } else {
            client.printed.append(message)
        }
    }

    func recordUnsupported(_ item: CommandItem, _ what: String) -> CommandResult {
        unsupported.append("\(item.command.spec.name): \(what)")
        commandError(item, "model: unsupported \(what)")
        return .error
    }

    // MARK: attach-session

    /// cmd_attach_session (cmd-attach-session.c:50-165). The target is looked
    /// up here rather than by cmdq_fire_command ("-t is special"):
    /// a session target prefers unattached sessions (cmd-attach-session.c:79-87).
    func executeAttachSession(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let client = item.client
        guard !sessions.isEmpty else {
            commandError(item, "no sessions")
            return .error
        }
        if command.has("d") || command.has("x") {
            return recordUnsupported(item, "attach-session -d/-x")
        }
        let tflag = command.value("t")
        let type: FindType
        let flags: FindFlags
        if let tflag, tflag.contains(":") || tflag.contains(".") {
            type = .pane
            flags = []
        } else {
            type = .session
            flags = .preferUnattached
        }
        let target: FindState
        switch findTarget(tflag, type: type, flags: flags, client: client, state: item.state) {
        case .found(let state): target = state
        case .failed(let message):
            if let message { commandError(item, message) }
            return .error
        }
        let session = sessionState(target.session!)
        // cmd-attach-session.c:92-100: whenever the lookup found a winlink,
        // which a session target also does (its current window), it becomes
        // current and the command list's current target.
        if let index = target.winlinkIndex {
            setCurrentWindow(session, index: index)
            item.state.current = target
        }
        if let value = command.value("f") {
            setClientFlags(client, value)
        }
        if command.has("r") {
            client.flags.formUnion([.readOnly, .ignoreSize])
        }
        let wasAttached = client.sessionID != nil
        client.lastSessionID = client.sessionID
        setSession(client, session)
        if !wasAttached {
            // notify_client("client-attached") feeds hooks only; then
            // CLIENT_ATTACHED (cmd-attach-session.c:157-158).
            client.flags.insert(.attached)
        }
        return .normal
    }

    // MARK: select-window

    /// cmd_select_window_exec (cmd-select-window.c:84-150). The *target*
    /// session switches (which for a bare `@W` is the most recently active
    /// session holding W, W2); the queue's current state follows only when
    /// the window changed (cmd-select-window.c:139-140); then
    /// `s->curw->window->latest = c` for an attached issuer
    /// (cmd-select-window.c:145-146) and a deferred `recalculate_sizes()`
    /// (cmd-select-window.c:147).
    func executeSelectWindow(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let session = sessionState(item.target.session!)
        let index = item.target.winlinkIndex!
        if command.has("n") || command.has("p") || command.has("l") {
            let result: Int
            let failure: String
            if command.has("n") {
                // session_next (session.c:413-429).
                let next = session.sortedIndexes.first { $0 > session.currentIndex } ?? session.sortedIndexes.first!
                result = setCurrentWindow(session, index: next)
                failure = "no next window"
            } else if command.has("p") {
                // session_previous (session.c:444-460).
                let previous = session.sortedIndexes.last { $0 < session.currentIndex } ?? session.sortedIndexes.last!
                result = setCurrentWindow(session, index: previous)
                failure = "no previous window"
            } else {
                // session_last (session.c:474-485).
                if let last = session.lastWindows.first {
                    result = last == session.currentIndex ? 1 : setCurrentWindow(session, index: last)
                } else {
                    result = -1
                }
                failure = "no last window"
            }
            if result != 0 {
                commandError(item, failure)
                return .error
            }
            item.state.current = findState(session: session)
            redrawSession(session)
        } else if command.has("T"), index == session.currentIndex {
            let result: Int
            if let last = session.lastWindows.first {
                result = last == session.currentIndex ? 1 : setCurrentWindow(session, index: last)
            } else {
                result = -1
            }
            if result != 0 {
                commandError(item, "no last window")
                return .error
            }
            if item.state.current?.session == session.id {
                item.state.current = findState(session: session)
            }
            redrawSession(session)
        } else if setCurrentWindow(session, index: index) == 0 {
            item.state.current = findState(session: session)
            redrawSession(session)
        }
        if item.client.sessionID != nil, let windowID = session.currentWindowID {
            windowState(windowID).latest = item.client.index
        }
        recalculateSizes()
        return .normal
    }

    // MARK: refresh-client

    /// cmd_refresh_client_exec (cmd-refresh-client.c:196-304). `-f`/`-F`
    /// apply first; then exactly one of `-A`, `-B`, `-C` runs and returns,
    /// so `-B x -C WxH` never sizes.
    func executeRefreshClient(_ item: CommandItem) -> CommandResult {
        let command = item.command
        guard let target = item.targetClient else { return .error }
        if ["c", "L", "R", "U", "D"].contains(where: { command.has($0) }) {
            if let argument = command.arguments.first {
                if let error = strtonumError(argument, minimum: 1, maximum: Int(Int32.max)) {
                    commandError(item, "adjustment \(error)")
                    return .error
                }
            }
            redrawClient(target)
            return .normal
        }
        if command.has("l") {
            return recordUnsupported(item, "refresh-client -l")
        }
        if let value = command.value("F") { setClientFlags(target, value) }
        if let value = command.value("f") { setClientFlags(target, value) }
        if command.has("A") {
            guard target.isControl else { return notControlClient(item) }
            // Pane output states affect only %output, which is not modelled.
            return .normal
        }
        if command.has("B") {
            guard target.isControl else { return notControlClient(item) }
            for value in command.values("B") {
                updateSubscription(target, value)
            }
            return .normal
        }
        if let size = command.value("C") {
            guard target.isControl else { return notControlClient(item) }
            return controlClientSize(item, target, size)
        }
        redrawClient(target)
        return .normal
    }

    private func notControlClient(_ item: CommandItem) -> CommandResult {
        commandError(item, "not a control client")
        return .error
    }

    /// cmd_refresh_client_control_client_size (cmd-refresh-client.c:80-130);
    /// 3.2 accepts only `W,H` and `WxH` (3.2 cmd-refresh-client.c:204-221).
    /// The forms are told apart by sscanf's conversion count: three for
    /// `@W:WxH`, else one for `@W` followed by anything (`@0`, `@0:`,
    /// `@0:junk`), which clears that window's size (cmd-refresh-client.c:89-114).
    /// Every accepted form ends in `recalculate_sizes_now(1)`, which skips
    /// the unchanged-size guard (W10).
    private func controlClientSize(_ item: CommandItem, _ target: ClientState, _ text: String) -> CommandResult {
        func inRange(_ value: UInt64) -> Bool {
            value >= UInt64(WindowLimits.minimum) && value <= UInt64(WindowLimits.maximum)
        }
        if version.hasPerWindowClientSize {
            var full = ScanfScanner(text)
            if full.literal("@"), let window = full.unsigned(), full.literal(":"),
               let columns = full.unsigned(), full.literal("x"), let rows = full.unsigned() {
                guard inRange(columns), inRange(rows) else {
                    commandError(item, "size too small or too big")
                    return .error
                }
                target.windowSizes[Int(truncatingIfNeeded: window)] = CellSize(Int(columns), Int(rows))
                target.flags.insert(.windowSizeChanged)
                recalculateSizes(now: true)
                return .normal
            }
            var clear = ScanfScanner(text)
            if clear.literal("@"), let window = clear.unsigned() {
                let id = Int(truncatingIfNeeded: window)
                if target.windowSizes[id] != nil {
                    target.windowSizes[id] = CellSize(0, 0)
                    recalculateSizes(now: true)
                }
                return .normal
            }
        }
        var size: (UInt64, UInt64)?
        for separator in [",", "x"] {
            var scanner = ScanfScanner(text)
            if let columns = scanner.unsigned(), scanner.literal(separator), let rows = scanner.unsigned() {
                size = (columns, rows)
                break
            }
        }
        guard let (columns, rows) = size else {
            commandError(item, "bad size argument")
            return .error
        }
        guard inRange(columns), inRange(rows) else {
            commandError(item, "size too small or too big")
            return .error
        }
        target.tty = CellSize(Int(columns), Int(rows))
        target.flags.insert(.sizeChanged)
        recalculateSizes(now: true)
        return .normal
    }

    // MARK: resize-window

    /// cmd_resize_window_exec (cmd-resize-window.c:46-115). From 3.3a the
    /// window becomes manual, remembers `manual_sx/sy` and resizes through a
    /// forced `recalculate_size(w, 1)`; 3.2 calls resize_window directly
    /// (3.2 cmd-resize-window.c:110-111). `window-size` is set with
    /// options_set_number, so there is no options_push_changes pass.
    func executeResizeWindow(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let window = windowState(item.target.window!)
        var adjust = 1
        if let argument = command.arguments.first {
            if let error = strtonumError(argument, minimum: 1, maximum: Int(Int32.max)) {
                commandError(item, "adjustment \(error)")
                return .error
            }
            adjust = Int(argument.trimmingCharacters(in: .whitespaces))!
        }
        var columns = window.size.columns
        var rows = window.size.rows
        if let value = command.value("x") {
            if let error = strtonumError(value, minimum: WindowLimits.minimum, maximum: WindowLimits.maximum) {
                commandError(item, "width \(error)")
                return .error
            }
            columns = Int(value.trimmingCharacters(in: .whitespaces))!
        }
        if let value = command.value("y") {
            if let error = strtonumError(value, minimum: WindowLimits.minimum, maximum: WindowLimits.maximum) {
                commandError(item, "height \(error)")
                return .error
            }
            rows = Int(value.trimmingCharacters(in: .whitespaces))!
        }
        if command.has("L") {
            if columns >= adjust { columns -= adjust }
        } else if command.has("R") {
            columns += adjust
        } else if command.has("U") {
            if rows >= adjust { rows -= adjust }
        } else if command.has("D") {
            rows += adjust
        }
        if command.has("A") || command.has("a") {
            return recordUnsupported(item, "resize-window -A/-a")
        }
        window.options["window-size"] = WindowSizePolicy.manual.rawValue
        if version.manualSizeThroughRecalculation {
            window.manualSize = CellSize(columns, rows)
            recalculateSize(window, now: true)
        } else {
            resizeWindow(window, to: CellSize(columns, rows))
        }
        return .normal
    }

    // MARK: set-option

    /// cmd_set_option_exec (cmd-set-option.c:83-239). The name is
    /// format-expanded; `-u` of an option with no local value does nothing
    /// (no push); every successful change ends in options_push_changes
    /// (cmd-set-option.c:226).
    func executeSetOption(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let isWindowCommand = command.spec.kind == .setWindowOption
        let context = targetFormatContext(item)
        let argument = expandFormat(command.arguments[0], context)
        let quiet = command.has("q")
        let name: String
        switch matchOption(item, argument) {
        case .name(let matched): name = matched
        case .invalid:
            if quiet { return .normal }
            commandError(item, "invalid option: \(argument)")
            return .error
        case .ambiguous:
            // cmd-set-option.c:111-118, cmd-show-options.c:102-110.
            if quiet { return .normal }
            commandError(item, "ambiguous option: \(argument)")
            return .error
        case .unsupported(let result): return result
        }
        var value = command.arguments.count > 1 ? command.arguments[1] : nil
        if let raw = value, command.has("F") {
            value = expandFormat(raw, context)
        }
        let scope: OptionTarget
        switch scopeFromName(name, global: command.has("g"), server: command.has("s"), pane: command.has("p"),
                             window: isWindowCommand || command.has("w"), state: item.target,
                             explicitTarget: command.value("t")) {
        case .success(let found): scope = found
        case .failure(let message):
            if quiet { return .normal }
            commandError(item, message)
            return .error
        }
        let local = store(scope)[name]
        if !command.has("u"), command.has("o"), local != nil {
            if quiet { return .normal }
            commandError(item, "already set: \(argument)")
            return .error
        }
        if command.has("U"), case .window(let windowID) = scope {
            windowState(windowID).paneOptions[name] = nil
        }
        if command.has("u") || command.has("U") {
            guard local != nil else { return .normal }
            // options_remove_or_default (options.c:1171-1186).
            if let entry = optionEntry(name), [.server, .globalSession, .globalWindow].contains(scope) {
                setStored(scope, name, entry.defaultValue)
            } else {
                setStored(scope, name, nil)
            }
        } else if name.hasPrefix("@") {
            guard let value else {
                commandError(item, "empty value")
                return .error
            }
            let appended = command.has("a") ? (local ?? "") + value : value
            setStored(scope, name, appended)
        } else {
            guard let entry = optionEntry(name) else { return recordUnsupported(item, "option \(name)") }
            switch optionFromString(entry, scope: scope, value: value, append: command.has("a")) {
            case .success(let stored):
                setStored(scope, name, stored)
            case .failure(let error):
                commandError(item, error.message)
                return .error
            }
        }
        pushOptionChanges(name)
        return .normal
    }

    enum OptionMatch {
        case name(String)
        case invalid
        case ambiguous
        case unsupported(CommandResult)
    }

    /// options_match (options.c:636-676) against the release's whole option
    /// table, so abbreviations and ambiguity follow tmux. A table option the
    /// model does not implement is reported as unsupported.
    func matchOption(_ item: CommandItem, _ argument: String) -> OptionMatch {
        if argument.contains("[") {
            return .unsupported(recordUnsupported(item, "array option index in \(argument)"))
        }
        switch OptionTable.match(argument, version: version) {
        case .invalid: return .invalid
        case .ambiguous: return .ambiguous
        case .found(let name):
            if name.hasPrefix("@") || optionEntry(name) != nil { return .name(name) }
            return .unsupported(recordUnsupported(item, "option \(name)"))
        }
    }

    /// The model's table entry for an option name in this release.
    func optionEntry(_ name: String) -> OptionEntry? {
        OptionTable.entry(name, version: version)
    }

    /// The value options_get_number would read: the scope's own value, then
    /// its parents.
    func effectiveOption(_ scope: OptionTarget, _ name: String) -> String? {
        switch scope {
        case .server: return serverOptions[name]
        case .globalSession: return globalSessionOptions[name]
        case .globalWindow: return globalWindowOptions[name]
        case .session(let id): return sessionState(id).options[name] ?? globalSessionOptions[name]
        case .window(let id): return windowState(id).options[name] ?? globalWindowOptions[name]
        case .pane(let id):
            let window = windowState(id)
            return window.paneOptions[name] ?? window.options[name] ?? globalWindowOptions[name]
        }
    }

    /// options_from_string (options.c:1031-1100) for the modelled types.
    func optionFromString(_ entry: OptionEntry, scope: OptionTarget, value: String?, append: Bool) -> Result<String, OptionError> {
        switch entry.kind {
        case .string:
            guard let value else { return .failure(OptionError("empty value")) }
            let new = append ? (effectiveOption(scope, entry.name) ?? "") + value : value
            // options_from_string_check: default-size has pattern
            // "[0-9]*x[0-9]*" (options-table.c:480-486).
            if entry.name == "default-size", !globMatch("[0-9]*x[0-9]*", new) {
                return .failure(OptionError("value is invalid: \(new)"))
            }
            return .success(new)
        case .number:
            guard let value else { return .failure(OptionError("empty value")) }
            if let error = strtonumError(value, minimum: 0, maximum: Int(Int32.max)) {
                return .failure(OptionError("value is \(error): \(value)"))
            }
            return .success(String(Int(value.trimmingCharacters(in: .whitespaces))!))
        case .flag:
            // options_from_string_flag (options.c:969-990).
            guard let value, !value.isEmpty else {
                return .success(flagOption(effectiveOption(scope, entry.name)) ? "off" : "on")
            }
            if value == "1" || ["on", "yes"].contains(value.lowercased()) { return .success("on") }
            if value == "0" || ["off", "no"].contains(value.lowercased()) { return .success("off") }
            return .failure(OptionError("bad value: \(value)"))
        case .choice(let choices):
            // options_from_string_choice (options.c:1012-1028).
            guard let value else {
                let current = choices.firstIndex(of: effectiveOption(scope, entry.name) ?? entry.defaultValue) ?? 0
                return .success(choices[current < 2 ? 1 - current : current])
            }
            guard choices.contains(value) else { return .failure(OptionError("unknown value: \(value)")) }
            return .success(value)
        }
    }

    struct OptionError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: show-options

    /// cmd_show_options_exec (cmd-show-options.c:76-145): only the scope's
    /// own value prints (or the inherited one with `-A`, marked `*`); a
    /// missing `@` option is an error unless `-q` (3.3a on); a missing table option
    /// prints nothing.
    func executeShowOptions(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let isWindowCommand = command.spec.kind == .showWindowOptions
        guard let raw = command.arguments.first else {
            return recordUnsupported(item, "show-options without an option name")
        }
        let quiet = command.has("q")
        let argument = expandFormat(raw, targetFormatContext(item))
        let name: String
        switch matchOption(item, argument) {
        case .name(let matched): name = matched
        case .invalid:
            if quiet { return .normal }
            commandError(item, "invalid option: \(argument)")
            return .error
        case .ambiguous:
            // cmd-set-option.c:111-118, cmd-show-options.c:102-110.
            if quiet { return .normal }
            commandError(item, "ambiguous option: \(argument)")
            return .error
        case .unsupported(let result): return result
        }
        let scope: OptionTarget
        switch scopeFromName(name, global: command.has("g"), server: command.has("s"), pane: command.has("p"),
                             window: isWindowCommand || command.has("w"), state: item.target,
                             explicitTarget: command.value("t")) {
        case .success(let found): scope = found
        case .failure(let message):
            if quiet { return .normal }
            commandError(item, message)
            return .error
        }
        var value = store(scope)[name]
        var parent = false
        if value == nil, command.has("A") {
            value = effectiveOption(scope, name)
            parent = value != nil
        }
        if let value {
            let label = parent ? "\(name)*" : name
            let isString = name.hasPrefix("@") || optionEntry(name).map { if case .string = $0.kind { true } else { false } } ?? false
            if command.has("v") {
                commandPrint(item, value)
            } else if isString {
                commandPrint(item, "\(label) \(argsEscape(value))")
            } else {
                commandPrint(item, "\(label) \(value)")
            }
        } else if name.hasPrefix("@"), version >= .v3_3a {
            // cmd-show-options.c:129-133 in 3.3a; 3.2 prints nothing and
            // succeeds (verified live on 3.2).
            if quiet { return .normal }
            commandError(item, "invalid option: \(argument)")
            return .error
        }
        return .normal
    }

    /// args_escape (arguments.c; not in the verified subset, from memory):
    /// empty → `''`; any of ` #';${}%` → double quotes with `"`, `\` and
    /// `$` escaped; a space or `"` alone → single quotes.
    func argsEscape(_ value: String) -> String {
        if value.isEmpty { return "''" }
        let doubleQuoted = value.contains { " #';${}%".contains($0) }
        let singleQuoted = !doubleQuoted && value.contains { " \"".contains($0) }
        if value.count == 1, value != " ", doubleQuoted || singleQuoted || value == "~" {
            return "\\\(value)"
        }
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\"" where doubleQuoted: escaped += "\\\""
            case "$" where doubleQuoted: escaped += "\\$"
            default: escaped.append(character)
            }
        }
        if singleQuoted { return "'\(escaped)'" }
        if doubleQuoted { return escaped.hasPrefix("~") ? "\"\\\(escaped)\"" : "\"\(escaped)\"" }
        return escaped.hasPrefix("~") ? "\\\(escaped)" : escaped
    }

    // MARK: display-message

    /// cmd_display_message_exec (cmd-display-message.c, from memory): the
    /// format's client is the target client when it is in the target
    /// session, else that session's best client; `-p` prints to the issuer,
    /// otherwise a control target client receives the text as a line.
    func executeDisplayMessage(_ item: CommandItem) -> CommandResult {
        let command = item.command
        if command.has("I") || command.has("a") {
            return recordUnsupported(item, "display-message -I/-a")
        }
        if command.has("F"), !command.arguments.isEmpty {
            commandError(item, "only one of -F or argument must be given")
            return .error
        }
        guard let template = command.value("F") ?? command.arguments.first else {
            return recordUnsupported(item, "display-message default template")
        }
        let session = item.target.session.flatMap { sessions[$0] }
        let formatClient: ClientState?
        if let target = item.targetClient, target.sessionID == session?.id {
            formatClient = target
        } else {
            formatClient = bestClient(of: session)
        }
        let message: String
        if command.has("l") {
            message = template
        } else {
            if template.contains("%") {
                // format_expand_time passes the template through strftime.
                return recordUnsupported(item, "strftime sequences in a display-message template")
            }
            let window = item.target.window.flatMap { windows[$0] }
            message = expandFormat(template, formatContext(client: formatClient, session: session, winlinkIndex: item.target.winlinkIndex, window: window))
        }
        if command.has("p") {
            commandPrint(item, message)
        } else if let target = item.targetClient, target.isControl {
            write(target, message)
        } else if let target = item.targetClient {
            target.statusMessages.append(message)
        }
        return .normal
    }

    // MARK: list-clients

    /// cmd_list_clients_exec (cmd-list-clients.c:53-102): attached clients in
    /// creation order; `-t S` keeps only clients whose session is exactly S,
    /// so grouped peers are not listed.
    func executeListClients(_ item: CommandItem) -> CommandResult {
        let command = item.command
        let session = command.has("t") ? item.target.session : nil
        let template = command.value("F") ?? Self.listClientsTemplate
        let filter = command.value("f")
        for client in clients where client.sessionID != nil {
            if let session, client.sessionID != session { continue }
            let context = formatContext(client: client, session: nil, winlinkIndex: nil, window: nil)
            if let filter, !formatTrue(expandFormat(filter, context)) { continue }
            commandPrint(item, expandFormat(template, context))
        }
        return .normal
    }

    /// LIST_CLIENTS_TEMPLATE (cmd-list-clients.c:31-36).
    static let listClientsTemplate = "#{client_name}: #{session_name} "
        + "[#{client_width}x#{client_height} #{client_termname}] "
        + "#{?#{!=:#{client_uid},#{uid}},"
        + "[user #{?client_user,#{client_user},#{client_uid},}] ,}"
        + "#{?client_flags,(,}#{client_flags}#{?client_flags,),}"

    // MARK: Helpers

    /// format_single_from_target: the target client and the item's target.
    func targetFormatContext(_ item: CommandItem) -> FormatContext {
        let session = item.target.session.flatMap { sessions[$0] }
        let window = item.target.window.flatMap { windows[$0] }
        return formatContext(client: item.targetClient, session: session, winlinkIndex: item.target.winlinkIndex, window: window)
    }

    /// strtonum's errstr ("too small", "too large", "invalid") or nil.
    func strtonumError(_ text: String, minimum: Int, maximum: Int) -> String? {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        var digits = Substring(trimmed)
        var negative = false
        if let sign = digits.first, sign == "-" || sign == "+" {
            negative = sign == "-"
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return "invalid" }
        guard let magnitude = Int(digits) else { return negative ? "too small" : "too large" }
        let value = negative ? -magnitude : magnitude
        if value < minimum { return "too small" }
        if value > maximum { return "too large" }
        return nil
    }
}

/// Enough of sscanf for `%u` and literal characters.
struct ScanfScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    /// `%u`: optional white space, an optional sign, then digits. A negative
    /// value wraps, as `%u` does.
    mutating func unsigned() -> UInt64? {
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
        var negative = false
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            negative = characters[index] == "-"
            index += 1
        }
        var value: UInt64 = 0
        var digits = 0
        while index < characters.count, let digit = characters[index].wholeNumberValue, characters[index].isASCII {
            value = value &* 10 &+ UInt64(digit)
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }
        return negative ? UInt64(UInt32(truncatingIfNeeded: 0 &- Int64(value))) : UInt64(UInt32(truncatingIfNeeded: value))
    }

    /// `%d` into an int: optional white space, an optional sign, digits; the
    /// value is truncated to 32 bits.
    mutating func signed() -> Int32? {
        while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
        var negative = false
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            negative = characters[index] == "-"
            index += 1
        }
        var value: UInt64 = 0
        var digits = 0
        while index < characters.count, let digit = characters[index].wholeNumberValue, characters[index].isASCII {
            value = value &* 10 &+ UInt64(digit)
            digits += 1
            index += 1
        }
        guard digits > 0 else { return nil }
        let magnitude = Int32(truncatingIfNeeded: value)
        return negative ? 0 &- magnitude : magnitude
    }

    mutating func literal(_ text: String) -> Bool {
        for character in text {
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
        }
        return true
    }
}
