import Foundation

// MARK: - Internal state (mirrors struct client / session / window in tmux.h)

/// Client flags the model tracks (tmux.h:1832-1879).
struct ClientFlags: OptionSet {
    let rawValue: UInt32
    static let attached = ClientFlags(rawValue: 1 << 0)          // CLIENT_ATTACHED
    static let focused = ClientFlags(rawValue: 1 << 1)           // CLIENT_FOCUSED
    static let ignoreSize = ClientFlags(rawValue: 1 << 2)        // CLIENT_IGNORESIZE
    static let noOutput = ClientFlags(rawValue: 1 << 3)          // CLIENT_CONTROL_NOOUTPUT
    static let readOnly = ClientFlags(rawValue: 1 << 4)          // CLIENT_READONLY
    static let sizeChanged = ClientFlags(rawValue: 1 << 5)       // CLIENT_SIZECHANGED
    static let windowSizeChanged = ClientFlags(rawValue: 1 << 6) // CLIENT_WINDOWSIZECHANGED
    static let statusOff = ClientFlags(rawValue: 1 << 7)         // CLIENT_STATUSOFF
    static let dead = ClientFlags(rawValue: 1 << 8)              // CLIENT_DEAD
    static let waitExit = ClientFlags(rawValue: 1 << 9)          // CLIENT_CONTROL_WAITEXIT
    static let pauseAfter = ClientFlags(rawValue: 1 << 10)       // CLIENT_CONTROL_PAUSEAFTER
    static let activePane = ClientFlags(rawValue: 1 << 11)       // CLIENT_ACTIVEPANE
    static let suspended = ClientFlags(rawValue: 1 << 12)        // CLIENT_SUSPENDED

    /// CLIENT_NOSIZEFLAGS and CLIENT_UNATTACHEDFLAGS (tmux.h:1869-1879):
    /// DEAD|SUSPENDED|EXIT. The model has no separate EXIT state.
    static let noSizeFlags: ClientFlags = [.dead, .suspended]
}

final class ClientState {
    let index: Int
    let name: String
    let pid: Int
    let isControl: Bool
    let isCommandClient: Bool
    let creationTime: Int64
    var activityTime: Int64
    var flags: ClientFlags = [.focused]
    /// `c->tty.sx/sy`; server_client_create starts every client at 80x24
    /// (server-client.c:275-276).
    var tty = CellSize(80, 24)
    /// `struct client_window` (per-window `refresh-client -C @W:WxH`).
    var windowSizes: [Int: CellSize] = [:]
    var sessionID: Int?
    var lastSessionID: Int?
    var queue: [QueueItem] = []
    var subscriptions: [String: Subscription] = [:]
    var subscriptionTimer: Int64?
    /// `c->pause_age`: the pause-after value times 1000, as a u_int.
    var pauseAge: UInt32 = 0
    var output: [ControlLine] = []
    var printed: [String] = []
    var errors: [String] = []
    var statusMessages: [String] = []
    /// CLIENT_EXIT: the client is told to exit; the model then loses it.
    var exitRequested = false
    /// Indexes of `output` already returned by `send` or `take`.
    var returned: Set<Int> = []
    /// How much of `output` the scenario runner has read.
    var scenarioMark = 0
    var redrawPending = false
    var redrawRequests = 0
    var repaints = 0
    var termName: String

    init(index: Int, name: String, pid: Int, isControl: Bool, isCommandClient: Bool, now: Int64, termName: String) {
        self.index = index
        self.name = name
        self.pid = pid
        self.isControl = isControl
        self.isCommandClient = isCommandClient
        self.creationTime = now
        self.activityTime = now
        self.termName = termName
    }
}

final class SessionState {
    let id: Int
    var name: String
    var options: [String: String] = [:]
    /// Winlinks: index → window id.
    var winlinks: [Int: Int] = [:]
    var currentIndex: Int = 0
    /// `s->lastw`, most recent first.
    var lastWindows: [Int] = []
    var activityTime: Int64
    var lastActivityTime: Int64
    var groupName: String?
    let creationTime: Int64

    init(id: Int, name: String, now: Int64) {
        self.id = id
        self.name = name
        self.activityTime = now
        self.lastActivityTime = now
        self.creationTime = now
    }

    var sortedIndexes: [Int] { winlinks.keys.sorted() }
    var currentWindowID: Int? { winlinks[currentIndex] }
}

final class WindowState {
    let id: Int
    var name: String
    let paneID: Int
    var size: CellSize
    var options: [String: String] = [:]
    var paneOptions: [String: String] = [:]
    /// `w->latest`, as a client index (which may no longer be live).
    var latest: Int?
    var manualSize: CellSize
    /// WINDOW_RESIZE with `new_sx/new_sy`.
    var pendingResize: CellSize?
    var activityTime: Int64
    var alive = true
    var resizeCount = 0
    var paneResizes = 0
    var layoutChangeNotifications = 0

    init(id: Int, name: String, paneID: Int, size: CellSize, now: Int64) {
        self.id = id
        self.name = name
        self.paneID = paneID
        self.size = size
        self.manualSize = size
        self.activityTime = now
    }
}

/// `struct cmdq_state`: shared by every command of one parsed line.
final class CommandState {
    var current: FindState?
    let control: Bool

    init(control: Bool) {
        self.control = control
    }
}

enum QueueItemKind {
    case command(ParsedCommand, group: Int, state: CommandState)
    /// A control-stream line that failed to parse (control_error).
    case parseError(String)
    /// A command-line (MSG_COMMAND) parse failure: cmdq_get_error's callback
    /// reports it through cmdq_error and the client exits
    /// (server-client.c:2915-2921, cmd-queue.c:695-700).
    case commandLineError(String)
    /// server_client_command_done (server-client.c:2840-2852).
    case commandDone
    case key
    case notify(Notification)
}

struct QueueItem {
    var kind: QueueItemKind
}

/// `cmd_find_state`. A valid state has all four parts.
struct FindState: Equatable {
    var session: Int?
    var winlinkIndex: Int?
    var window: Int?
    var pane: Int?

    var isValid: Bool { session != nil && winlinkIndex != nil && window != nil && pane != nil }
}

// MARK: - The model

/// A deterministic tmux server. Drive it with the scripting API and read back
/// control-mode output, window geometry, `latest` and option state.
public final class TmuxServerModel {
    public let version: TmuxVersion
    /// Model time in microseconds since the model started.
    public internal(set) var now: Int64 = 0
    /// Seconds added to `now` when printing `%begin` times.
    public var epochSeconds: Int64 = 1_700_000_000

    var clients: [ClientState] = []
    var lostClients: [Int: ClientState] = [:]
    var sessions: [Int: SessionState] = [:]
    var windows: [Int: WindowState] = [:]
    var groups: [String: [Int]] = [:]
    var globalQueue: [QueueItem] = []
    var serverOptions: [String: String] = [:]
    var globalSessionOptions: [String: String] = [:]
    var globalWindowOptions: [String: String] = [:]

    var nextSessionID = 0
    var nextWindowID = 0
    var nextPaneID = 0
    var nextClientIndex = 0
    var nextPID = 4000
    var nextCommandGroup = 1
    var commandNumber = 0

    /// Every `recalculate_size` pass and every `options_push_changes`.
    public internal(set) var recalculationPasses = 0
    public internal(set) var optionPushes = 0
    /// Valid tmux input the model does not implement. A scenario that adds
    /// anything here is outside the model and must not be trusted.
    public internal(set) var unsupported: [String] = []

    public init(version: TmuxVersion = .v3_4) {
        self.version = version
        OptionTable.installDefaults(into: self)
    }

    // MARK: Setup

    /// `new-session -d -s NAME -x W -y H -n WINDOW` from a command client
    /// (cmd-new-session.c:262-317): the window is created detached, so its
    /// `latest` stays empty (spawn.c:165 with no target client), and `-x/-y`
    /// also become the session's `default-size` (cmd-new-session.c:263-269).
    @discardableResult
    public func newSession(_ name: String, size: CellSize? = nil, windowName: String? = nil) -> (session: SessionHandle, window: WindowHandle) {
        tick()
        let admin = makeCommandClient()
        let session = createSession(name: name)
        if let size {
            session.options["default-size"] = size.description
        }
        let window = spawnWindow(in: session, index: nil, name: windowName ?? name, detached: true, creator: nil)
        enqueueNotification(.sessionsChanged)
        loseClient(admin)
        runServerLoop()
        return (SessionHandle(id: session.id), WindowHandle(id: window.id))
    }

    /// `new-window -d -t SESSION: -n NAME` from a command client (spawn.c:78-200,
    /// then `session_group_synchronize_from`). Sized from the session's
    /// `default-size`, which is what `default_window_size` (resize.c:285-341)
    /// yields while no client is attached; see the known gaps for windows
    /// created while clients are attached.
    @discardableResult
    public func newWindow(in session: SessionHandle, name: String) -> WindowHandle {
        tick()
        let admin = makeCommandClient()
        let window = spawnWindow(in: sessionState(session.id), index: nil, name: name, detached: true, creator: nil)
        loseClient(admin)
        runServerLoop()
        return WindowHandle(id: window.id)
    }

    /// `new-session -d -s NAME -t TARGET` (cmd-new-session.c:132-142, 262-316):
    /// the new session spawns its own window first (consuming a window and a
    /// pane id), then `session_group_synchronize_to` replaces its winlinks with
    /// the group's and the spawned window is destroyed
    /// (session.c:647-702). Options are a fresh `options_create(global_s_options)`
    /// (cmd-new-session.c:262), so nothing session-scoped is shared. The new
    /// session's current window is the group's lowest index
    /// (cmd-new-session.c:315).
    @discardableResult
    public func newGroupedSession(_ name: String, groupedWith target: SessionHandle) -> SessionHandle {
        tick()
        let admin = makeCommandClient()
        let owner = sessionState(target.id)
        let session = createSession(name: name)
        let spawned = spawnWindow(in: session, index: nil, name: nil, detached: true, creator: nil)
        let groupName: String
        if let existing = owner.groupName {
            groupName = existing
        } else {
            groupName = owner.name
            owner.groupName = groupName
            groups[groupName] = [owner.id]
        }
        session.groupName = groupName
        groups[groupName, default: []].append(session.id)
        synchronizeSession(session, to: owner)
        if !session.winlinks.values.contains(spawned.id) {
            destroyWindow(spawned)
        }
        if let lowest = session.sortedIndexes.first {
            _ = setCurrentWindow(session, index: lowest)
        }
        enqueueNotification(.sessionsChanged)
        loseClient(admin)
        runServerLoop()
        return SessionHandle(id: session.id)
    }

    // MARK: Clients

    /// `tmux -C attach-session [-f FLAGS] -t SESSION`: a control client is
    /// created (server_client_create, server-client.c:251-290) and its
    /// command-line `attach-session` runs with non-control queue flags, so its
    /// own reply block carries flags 0 (cmd-queue.c:618-619).
    @discardableResult
    public func connect(control name: String, session: SessionHandle, flags: [String] = []) -> ClientHandle {
        tick()
        let client = makeClient(name: name, control: true)
        var line = "attach-session -t \(session)"
        if !flags.isEmpty { line += " -f \(flags.joined(separator: ","))" }
        enqueueCommandLine(line, client: client, control: false)
        runServerLoop()
        dropExitedClient(client)
        return ClientHandle(index: client.index, name: client.name)
    }

    /// `tmux attach-session -t SESSION` from a terminal of `size`: attach,
    /// then the client answers MSG_READY with MSG_RESIZE (client.c:668-673),
    /// which makes it `latest` and recalculates (server-client.c:2763-2780).
    @discardableResult
    public func attachTTY(_ name: String, session: SessionHandle, size: CellSize, flags: [String] = []) -> ClientHandle {
        tick()
        let client = makeClient(name: name, control: false)
        client.tty = size
        var line = "attach-session -t \(session)"
        if !flags.isEmpty { line += " -f \(flags.joined(separator: ","))" }
        enqueueCommandLine(line, client: client, control: false)
        runServerLoop()
        dropExitedClient(client)
        if client.sessionID != nil, !client.flags.contains(.dead) {
            handleResizeMessage(client, newSize: size)
            runServerLoop()
        }
        return ClientHandle(index: client.index, name: client.name)
    }

    /// One control-mode input line (control_read_callback, control.c:546-575).
    /// Returns the lines this client received while the server processed it.
    @discardableResult
    public func send(_ handle: ClientHandle, _ line: String) -> [String] {
        tick()
        let client = liveClient(handle)
        precondition(client.isControl, "\(handle.name) is not a control client")
        precondition(!line.isEmpty, "an empty line detaches a control client (control.c:561-565)")
        let mark = client.output.count
        enqueueCommandLine(line, client: client, control: true)
        runServerLoop()
        client.returned.formUnion(mark..<client.output.count)
        return client.output[mark...].map(\.text)
    }

    /// A key typed on a terminal client (server_client_handle_key,
    /// server-client.c:2059-2102, then server_client_key_callback,
    /// server-client.c:1851-2055).
    public func typeKey(_ handle: ClientHandle) {
        tick()
        let client = liveClient(handle)
        precondition(!client.isControl, "control clients have no keyboard; use send-keys")
        guard client.sessionID != nil, !client.flags.contains(.dead) else { return }
        client.queue.append(QueueItem(kind: .key))
        runServerLoop()
    }

    /// The terminal of a tty client changed size: SIGWINCH → MSG_RESIZE.
    public func resizeTTY(_ handle: ClientHandle, to size: CellSize) {
        tick()
        let client = liveClient(handle)
        handleResizeMessage(client, newSize: size)
        runServerLoop()
    }

    /// The client's connection dropped (server_client_lost, server-client.c:394-470).
    public func lose(_ handle: ClientHandle) {
        tick()
        let client = liveClient(handle)
        loseClient(client)
        runServerLoop()
    }

    /// One `tmux COMMAND` invocation from outside: a short-lived, unattached
    /// command client runs the line, then disconnects, and every disconnect
    /// ends with `recalculate_sizes()` (server-client.c:467).
    @discardableResult
    public func admin(_ line: String) -> (output: [String], errors: [String]) {
        tick()
        let client = makeCommandClient()
        enqueueCommandLine(line, client: client, control: false)
        runServerLoop()
        let result = (client.printed, client.errors)
        loseClient(client)
        runServerLoop()
        return result
    }

    /// Moves time forward, firing every control client's subscription timer
    /// that falls due on the way (control_check_subs_timer, control.c:1045-1074).
    public func advance(seconds: Double) {
        advance(to: now + Int64((seconds * 1_000_000).rounded()))
    }

    /// Moves time forward to an absolute model time (microseconds).
    public func advance(to time: Int64) {
        precondition(time >= now, "model time cannot run backwards")
        fireTimers(until: time)
        now = time
    }

    // MARK: Reading state

    /// Lines received by a control client that neither `send` nor `take`
    /// has returned yet: notifications, subscription changes and output
    /// caused by other clients.
    public func take(_ handle: ClientHandle) -> [String] {
        guard let client = anyClient(handle) else { return [] }
        let fresh = client.output.indices.filter { !client.returned.contains($0) }
        client.returned.formUnion(fresh)
        return fresh.map { client.output[$0].text }
    }

    /// Lines an unattached command client printed (stdout) and its errors
    /// (stderr), or an attached terminal's status messages.
    public func statusMessages(_ handle: ClientHandle) -> [String] {
        anyClient(handle)?.statusMessages ?? []
    }

    /// Every line a control client has received, with model timestamps.
    public func transcript(_ handle: ClientHandle) -> [ControlLine] {
        anyClient(handle)?.output ?? []
    }

    public func windowSize(_ window: WindowHandle) -> CellSize {
        windowState(window.id).size
    }

    public func latest(_ window: WindowHandle) -> LatestClient {
        guard let index = windowState(window.id).latest else { return .none }
        if let client = clients.first(where: { $0.index == index }) { return .client(client.name) }
        if let lost = lostClients[index] { return .dangling(lost.name) }
        return .none
    }

    public func pendingResize(_ window: WindowHandle) -> CellSize? {
        windowState(window.id).pendingResize
    }

    public func currentWindow(_ session: SessionHandle) -> WindowHandle {
        WindowHandle(id: sessionState(session.id).currentWindowID!)
    }

    public func sessionOption(_ session: SessionHandle, _ name: String) -> String? {
        sessionState(session.id).options[name]
    }

    public func windowOption(_ window: WindowHandle, _ name: String) -> String? {
        windowState(window.id).options[name]
    }

    public func clientSize(_ handle: ClientHandle) -> CellSize {
        liveClient(handle).tty
    }

    public func clientFlags(_ handle: ClientHandle) -> String {
        clientFlagsString(liveClient(handle))
    }

    /// Repaints a terminal client performed (server_client_check_redraw runs
    /// once per server loop for a client with pending redraw flags;
    /// control clients never repaint, server-client.c:2570-2571).
    public func repaints(_ handle: ClientHandle) -> Int {
        anyClient(handle)?.repaints ?? 0
    }

    /// Calls to `server_redraw_client` for this client (server-fn.c:33-36).
    public func redrawRequests(_ handle: ClientHandle) -> Int {
        anyClient(handle)?.redrawRequests ?? 0
    }

    /// `resize_window` calls for this window (resize.c:26-66).
    public func resizeCount(_ window: WindowHandle) -> Int {
        windowState(window.id).resizeCount
    }

    /// Pane geometry changes queued by window resizes: window_pane_resize
    /// queues one only when the pane's size changes (window.c:1066-1074). The
    /// SIGWINCH a pane receives coalesces queued changes on a timer
    /// (server-client.c:2216-2221) and is not modelled.
    public func paneResizes(_ window: WindowHandle) -> Int {
        windowState(window.id).paneResizes
    }

    public func sessionHandle(named name: String) -> SessionHandle? {
        sessions.values.first { $0.name == name }.map { SessionHandle(id: $0.id) }
    }

    public func sessionActivity(_ session: SessionHandle) -> Int64 {
        sessionState(session.id).activityTime
    }

    public func clientActivity(_ handle: ClientHandle) -> Int64 {
        liveClient(handle).activityTime
    }

    public func isLive(_ handle: ClientHandle) -> Bool {
        clients.contains { $0.index == handle.index }
    }

    // MARK: Internals: construction

    /// Every external event happens at its own microsecond, and timers that
    /// fell due before it fire first (libevent runs due timers before the
    /// next read callback).
    func tick() {
        fireTimers(until: now + 1)
        now += 1
    }

    func makeClient(name: String, control: Bool) -> ClientState {
        let client = ClientState(
            index: nextClientIndex,
            name: name,
            pid: nextPID,
            isControl: control,
            isCommandClient: false,
            now: now,
            termName: "xterm-256color"
        )
        nextClientIndex += 1
        nextPID += 1
        clients.append(client)
        return client
    }

    func makeCommandClient() -> ClientState {
        let pid = nextPID
        let client = ClientState(
            index: nextClientIndex,
            name: "client-\(pid)",
            pid: pid,
            isControl: false,
            isCommandClient: true,
            now: now,
            termName: "xterm-256color"
        )
        nextClientIndex += 1
        nextPID += 1
        clients.append(client)
        return client
    }

    func createSession(name: String) -> SessionState {
        let session = SessionState(id: nextSessionID, name: name, now: now)
        nextSessionID += 1
        sessions[session.id] = session
        return session
    }

    /// spawn_window (spawn.c:78-200) for a new window: the next free index
    /// from the session's base-index (spawn.c:149-151, winlink_add and
    /// winlink_next_index, window.c:168-170), `latest = sc->tc` (spawn.c:165),
    /// a named window turns automatic-rename off (spawn.c:181-185), then
    /// `session_group_synchronize_from` (spawn.c:198).
    @discardableResult
    func spawnWindow(in session: SessionState, index: Int?, name: String?, detached: Bool, creator: ClientState?) -> WindowState {
        let base = Int(sessionOptionValue(session, "base-index") ?? "0") ?? 0
        let idx = index ?? (base...).first { session.winlinks[$0] == nil }!
        let size = defaultWindowSize(session)
        let window = WindowState(id: nextWindowID, name: name ?? "sh", paneID: nextPaneID, size: size, now: now)
        nextWindowID += 1
        nextPaneID += 1
        windows[window.id] = window
        window.latest = creator?.index
        if name != nil { window.options["automatic-rename"] = "off" }
        let hadCurrent = session.winlinks[session.currentIndex] != nil
        session.winlinks[idx] = window.id
        if !hadCurrent { session.currentIndex = idx }
        if !detached { _ = setCurrentWindow(session, index: idx) }
        enqueueNotification(.windowLinked(session: session.id, window: window.id))
        synchronizeGroup(from: session)
        return window
    }

    /// default_window_size's `manual` path (resize.c:321-339), which is what a
    /// window created while no client sizes it gets: `sscanf("%ux%u")` of the
    /// session's default-size (else 80x24), clamped to WINDOW_MINIMUM and
    /// WINDOW_MAXIMUM. Windows created while clients are attached are a known
    /// gap (resize.c:285-320).
    func defaultWindowSize(_ session: SessionState) -> CellSize {
        var scanner = ScanfScanner(sessionOptionValue(session, "default-size") ?? "80x24")
        guard let columns = scanner.unsigned(), scanner.literal("x"), let rows = scanner.unsigned() else {
            return CellSize(80, 24)
        }
        return CellSize(WindowLimits.clamp(Int(columns)), WindowLimits.clamp(Int(rows)))
    }

    /// session_group_synchronize_from (session.c:627-639).
    func synchronizeGroup(from target: SessionState) {
        guard let name = target.groupName, let members = groups[name] else { return }
        for id in members where id != target.id {
            synchronizeSession(sessionState(id), to: target)
        }
    }

    /// session_group_synchronize1 (session.c:647-702): relink every window of
    /// the target, keep the current index if it still exists, keep the last
    /// window stack where possible, and report unlinked windows.
    func synchronizeSession(_ session: SessionState, to target: SessionState) {
        guard !target.winlinks.isEmpty else { return }
        let old = session.winlinks
        if old[session.currentIndex] != nil, target.winlinks[session.currentIndex] == nil {
            session.currentIndex = target.sortedIndexes.first!
        }
        session.winlinks = target.winlinks
        for idx in target.sortedIndexes {
            enqueueNotification(.windowLinked(session: session.id, window: target.winlinks[idx]!))
        }
        if old.isEmpty || session.winlinks[session.currentIndex] == nil {
            session.currentIndex = target.currentIndex
        }
        session.lastWindows = session.lastWindows.filter { session.winlinks[$0] != nil }
        for (_, windowID) in old where !session.winlinks.values.contains(windowID) {
            enqueueNotification(.windowUnlinked(session: session.id, window: windowID))
        }
    }

    func destroyWindow(_ window: WindowState) {
        window.alive = false
        windows[window.id] = nil
        deadWindows[window.id] = window
    }

    var deadWindows: [Int: WindowState] = [:]

    // MARK: Internals: lookups

    func sessionState(_ id: Int) -> SessionState {
        guard let session = sessions[id] else { preconditionFailure("no session $\(id)") }
        return session
    }

    func windowState(_ id: Int) -> WindowState {
        guard let window = windows[id] ?? deadWindows[id] else { preconditionFailure("no window @\(id)") }
        return window
    }

    func liveClient(_ handle: ClientHandle) -> ClientState {
        guard let client = clients.first(where: { $0.index == handle.index }) else {
            preconditionFailure("client \(handle.name) is not connected")
        }
        return client
    }

    func anyClient(_ handle: ClientHandle) -> ClientState? {
        clients.first { $0.index == handle.index } ?? lostClients[handle.index]
    }

    func client(index: Int) -> ClientState? {
        clients.first { $0.index == index }
    }

    func session(of client: ClientState) -> SessionState? {
        client.sessionID.flatMap { sessions[$0] }
    }

    /// session_has (session.c:375-384).
    func sessionHas(_ session: SessionState, window: Int) -> Bool {
        session.winlinks.values.contains(window)
    }

    /// Sessions in RB-tree order: `session_cmp` sorts by name.
    var sessionsInOrder: [SessionState] {
        sessions.values.sorted { $0.name < $1.name }
    }

    /// Windows in RB-tree order: `window_cmp` sorts by id.
    var windowsInOrder: [WindowState] {
        windows.values.sorted { $0.id < $1.id }
    }

    func formatTime(_ time: Int64) -> Int64 {
        epochSeconds + time / 1_000_000
    }

    // MARK: Internals: the event loop

    /// control_write (control.c): append one line to a control client.
    func write(_ client: ClientState, _ text: String) {
        guard client.isControl else { return }
        client.output.append(ControlLine(time: now, text: text))
    }

    /// server_loop (server.c:262-277): drain the global queue and every
    /// client's queue until nothing runs, then server_client_loop. Work that
    /// server_client_loop queues (a deferred resize's notification) runs on
    /// the next loop iteration, which the model takes immediately.
    func runServerLoop() {
        var guardCount = 0
        repeat {
            var items: Int
            repeat {
                items = runQueue(nil)
                for client in clients where !client.queue.isEmpty {
                    items += runQueue(client)
                }
            } while items != 0
            serverClientLoop()
            guardCount += 1
            precondition(guardCount < 1000, "server loop did not settle")
        } while !globalQueue.isEmpty || clients.contains { !$0.queue.isEmpty }
    }

    /// cmdq_next (cmd-queue.c:720-799).
    func runQueue(_ client: ClientState?) -> Int {
        var processed = 0
        while true {
            let item: QueueItem
            if let client {
                guard clients.contains(where: { $0 === client }), !client.queue.isEmpty else { break }
                item = client.queue.removeFirst()
            } else {
                guard !globalQueue.isEmpty else { break }
                item = globalQueue.removeFirst()
            }
            commandNumber += 1
            let time = formatTime(now)
            let number = commandNumber
            switch item.kind {
            case .command(let command, let group, let state):
                guard let client else { break }
                let failed = fireCommand(command, client: client, state: state, time: time, number: number)
                if failed {
                    // cmdq_next calls cmdq_remove_group on CMD_RETURN_ERROR:
                    // successors disappear without firing or guards (3.2-3.6a).
                    client.queue.removeAll {
                        if case .command(_, let other, _) = $0.kind { return other == group }
                        return false
                    }
                }
            case .parseError(let message):
                // control_read_callback queues only control_error on parse
                // failure: one error block, flags 1, no commands (3.2-3.6a).
                guard let client else { break }
                write(client, "%begin \(time) \(number) 1")
                write(client, "parse error: \(message)")
                write(client, "%error \(time) \(number) 1")
            case .commandLineError(let message):
                guard let client else { break }
                reportError(client, message)
                client.exitRequested = true
            case .commandDone:
                // A command client that did not attach exits.
                if let client, !client.flags.contains(.attached) { client.exitRequested = true }
            case .key:
                if let client { keyCallback(client) }
            case .notify(let notification):
                deliver(notification)
            }
            processed += 1
        }
        return processed
    }

    /// server_client_loop (server-client.c:2106-2140).
    func serverClientLoop() {
        for window in windowsInOrder {
            checkWindowResize(window)
        }
        for client in clients where client.sessionID != nil {
            // server_client_check_redraw (server-client.c:2557-2572).
            if client.redrawPending, !client.isControl, !client.flags.contains(.suspended) {
                client.repaints += 1
                client.redrawPending = false
            }
        }
    }

    /// server_client_check_window_resize (server-client.c:2144-2160): a
    /// deferred resize applies only once some attached session has the window
    /// current.
    func checkWindowResize(_ window: WindowState) {
        guard let size = window.pendingResize else { return }
        let shown = sessionsInOrder.contains { session in
            attachedCount(session) != 0 && session.currentWindowID == window.id
        }
        guard shown else { return }
        resizeWindow(window, to: size)
    }

    /// `s->attached` as recalculate_sizes_now counts it (resize.c:443-455).
    func attachedCount(_ session: SessionState) -> Int {
        clients.filter { $0.sessionID == session.id && !$0.flags.contains(.dead) && !$0.flags.contains(.suspended) }.count
    }

    /// server_redraw_client (server-fn.c:33-36).
    func redrawClient(_ client: ClientState) {
        client.redrawPending = true
        client.redrawRequests += 1
    }

    /// server_redraw_session (server-fn.c:45-53).
    func redrawSession(_ session: SessionState) {
        for client in clients where client.sessionID == session.id {
            redrawClient(client)
        }
    }

    /// server_redraw_window (server-fn.c:93-101).
    func redrawWindow(_ window: WindowState) {
        for client in clients {
            guard let session = session(of: client), session.currentWindowID == window.id else { continue }
            redrawClient(client)
        }
    }

    /// Queues one input line: a control-mode line when `control`
    /// (control_read_callback, control.c:546-575), else the client's command
    /// line (server_client_dispatch_command, server-client.c:2855-2921),
    /// which is followed by server_client_command_done.
    func enqueueCommandLine(_ line: String, client: ClientState, control: Bool) {
        switch CommandParser.parse(line, version: version) {
        case .failure(let message):
            client.queue.append(QueueItem(kind: control ? .parseError(message) : .commandLineError(message)))
        case .unsupported(let message):
            unsupported.append(message)
            let text = "model: unsupported \(message)"
            client.queue.append(QueueItem(kind: control ? .parseError(text) : .commandLineError(text)))
        case .success(let commands):
            // cmd_parse_from_string sets CMD_PARSE_ONEGROUP; cmdq_get_command
            // makes one item per command with that shared group (3.2-3.6a).
            let group = nextCommandGroup
            nextCommandGroup += 1
            let state = CommandState(control: control)
            for command in commands {
                client.queue.append(QueueItem(kind: .command(command, group: group, state: state)))
            }
            if !control { client.queue.append(QueueItem(kind: .commandDone)) }
        }
    }

    /// A client told to exit (CLIENT_EXIT) goes away; the model loses it at
    /// once instead of after the MSG_EXIT round trip.
    func dropExitedClient(_ client: ClientState) {
        guard client.exitRequested, !client.flags.contains(.dead) else { return }
        loseClient(client)
        runServerLoop()
    }
}
