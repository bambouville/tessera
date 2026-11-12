import XCTest
import SwiftUI
import SwiftTerm
import TmuxControlCore
@testable import TmuxControl
@testable import Tessera

#if DEBUG
/// Mounts the **real** `SessionView` — SwiftUI wiring, agent-center probes,
/// launch overlay and all — against a live fixture host, so the auto-tmux
/// launch is exercised through the same code path the shipping app uses
/// rather than through a hand-rolled transport rig.
@MainActor
final class AutoTmuxSessionViewLaunchTests: XCTestCase {
    private struct Config: Decodable {
        let stableHost: String
        let chaosHost: String
        let port: Int
        let user: String
        let password: String

        static func load() throws -> Self {
            guard let encoded = ProcessInfo.processInfo.environment[
                "TESSERA_REAL_HOST_CONFIG_B64"
            ],
            let data = Data(base64Encoded: encoded) else {
                throw XCTSkip("real-host fixture is opt-in")
            }
            return try JSONDecoder().decode(Self.self, from: data)
        }
    }

    /// Freshly added host: nothing cached locally, no tmux server remotely.
    func test_liveSessionViewAutoTmuxOnFreshlyAddedHost() async throws {
        let config = try Config.load()
        try await runMountedLaunch(config: config, label: "sessionview-fresh")
    }

    /// Immediately afterwards, the same host again — the state the user
    /// reports as working ("solved for that host").
    func test_liveSessionViewAutoTmuxOnRepeatConnect() async throws {
        let config = try Config.load()
        try await runMountedLaunch(config: config, label: "sessionview-repeat-1", keepSession: true)
        try await runMountedLaunch(config: config, label: "sessionview-repeat-2")
    }

    /// A host that can never hand us control mode: its login dotfiles
    /// `exec` a plain tmux client before the launch command can run. The
    /// launch must give the user their terminal back instead of spinning
    /// on "starting tmux" forever.
    func test_liveSessionViewDegradesWhenHostNeverEntersControlMode() async throws {
        let config = try Config.load()
        try await runMountedLaunch(
            config: config,
            label: "sessionview-hostile-dotfiles",
            user: "\(config.user)-dotfile-tmux",
            expectsControlMode: false
        )
    }

    /// The long-standing "tmux is not installed" path must still degrade
    /// through the same banner after the launch-script rework.
    func test_liveSessionViewDegradesWhenTmuxIsNotInstalled() async throws {
        let config = try Config.load()
        try await runMountedLaunch(
            config: config,
            label: "sessionview-no-tmux",
            user: "\(config.user)-notmux",
            expectsControlMode: false
        )
    }

    /// T-09 on an iPad: compact, regular, then the same compact grid. The
    /// session stays mounted throughout, so what compact last asked tmux for
    /// must not stop it asking again once regular sized the client.
    func test_liveSessionViewSendsTheCompactGridAgainAfterRegular() async throws {
        let config = try Config.load()
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a phone is compact in every size class")
        let host = Host(
            name: "SessionView compact-regular", address: config.stableHost, port: config.port,
            user: config.user, password: config.password, transport: .ssh, autoTmux: true, launchMode: .autoTmux
        )
        await KnownHostsStore.shared.remove(endpoint: "\(config.stableHost):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        // The controller's own sizing decisions, for a failure to explain
        // itself: the test host keeps no diagnostic log.
        var diagnostics: [String] = []
        let previousDiagnosticsSink = TmuxDiagnostics.sink
        TmuxDiagnostics.sink = { message in
            diagnostics.append(message)
            previousDiagnosticsSink?(message)
        }
        defer { TmuxDiagnostics.sink = previousDiagnosticsSink }
        let session = SSHSession(host: host)
        let liveSessionID = UUID()
        let sessionRegistry = SessionRegistry()
        let sizeClass = SizeClassBox()
        let controller = UIHostingController(rootView: SizeClassHost(box: sizeClass, content: mounted(
            SessionView(session: session, liveSessionID: liveSessionID, isActive: true, onToggleSidebar: {},
                        sidebarVisible: false, onBack: {}, onEditHost: {}, onRetry: {}, onSessionEnded: {},
                        onSelectSession: { _ in }, onOpenSettings: {}),
            registry: sessionRegistry, opening: liveSessionID)))
        let compact = CGRect(x: 0, y: 0, width: 420, height: 900)
        let regular = CGRect(x: 0, y: 0, width: 1_180, height: 820)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = compact
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }
        let acceptor = Task { @MainActor in
            for _ in 0..<600 {
                if let pending = session.pendingHostKeyVerification, !pending.isResolved { pending.accept() }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { acceptor.cancel() }
        for _ in 0..<300 where !sessionRegistry.isRenderReady(liveSessionID) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sessionRegistry.isRenderReady(liveSessionID), "the session never rendered")

        let name = HostRuntimeStateStore.sessionName(for: host)
        /// The session's window as tmux sized it, "<cols>x<rows>". A control
        /// client reports no height of its own; the window follows it.
        func client() async -> String {
            let output = (try? await session.executeConnectedCommand(
                "tmux display-message -p -t '=\(name):' 'size=#{window_width}x#{window_height}' 2>/dev/null"
            )) ?? ""
            NSLog("compact-regular sample %@", output.debugDescription)
            return output.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("size=") }
                .map { String($0.dropFirst(5)) } ?? ""
        }
        /// What tmux holds for this host, for a failure to explain itself.
        func layout() async -> String {
            (try? await session.executeConnectedCommand(
                "tmux list-sessions -F 'session #{session_name} group=#{session_group} attached=#{session_attached}' 2>&1; "
                    + "tmux list-clients -F 'client #{client_session} control=#{client_control_mode} #{client_width} flags=#{client_flags}' 2>&1; "
                    + "tmux list-windows -a -F 'window #{session_name}:#{window_index} #{window_id} #{window_width}x#{window_height} size=#{window-size}' 2>&1"
            )) ?? "unreadable"
        }
        /// The client once it held one size for a second and a half and `accepts` it.
        func settled(_ label: String, _ accepts: (String) -> Bool) async throws -> String {
            var previous = ""
            var held = 0
            for _ in 0..<40 {
                let current = await client()
                held = current == previous ? held + 1 : 0
                if !current.isEmpty, held >= 3, accepts(current) { return current }
                previous = current
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let sizing = diagnostics.filter {
                ["client-size", "grid-authority", "refresh", "layout"].contains(where: $0.contains)
            }.suffix(60)
            // One line each: a long log line is cut short.
            for line in sizing { NSLog("compact-regular diagnostic %@", line) }
            XCTFail("\(label): the client stayed \(previous); tmux: \(await layout())\n\(sizing.joined(separator: "\n"))")
            return previous
        }
        func present(_ frame: CGRect, _ value: UserInterfaceSizeClass) {
            window.frame = frame
            sizeClass.value = value
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        NSLog("compact-regular layout %@", await layout())
        let first = try await settled("compact") { _ in true }
        present(regular, .regular)
        let wide = try await settled("regular") { $0 != first }
        present(compact, .compact)
        let again = try await settled("compact again") { $0 == first }
        XCTAssertEqual(again, first, "compact sends its grid again over regular's \(wide)")
        _ = try? await session.executeConnectedCommand("tmux kill-session -t '=\(name)' >/dev/null 2>&1 || true")
    }

    /// A phone's mosh+tmux canvas is framed at the client grid the compact
    /// viewport advertises, and a split window needs a wider grid than a
    /// single pane. Mosh took that size at once while the canvas reached it a
    /// layout pass later, so a switch's frame was drawn at the old width; the
    /// canvas then panned to the right pane's columns, which stayed blank
    /// because Mosh had already sent them. A quiet split came back empty
    /// until something printed in it (Duo retest M4 item 9).
    func test_liveMoshCompactSplitReturnPaintsTheFocusedPane() async throws {
        let config = try Config.load()
        await KnownHostsStore.shared.remove(endpoint: "\(config.stableHost):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        let token = UUID().uuidString.prefix(8).lowercased()
        let name = "tessera-compact-split-\(token)"
        let view = AutoTmuxCommands.moshViewSessionName(for: name)
        let helper = SSHSession(host: Host(
            name: "compact split helper", address: config.stableHost, port: config.port,
            user: config.user, password: config.password, transport: .ssh, autoTmux: false,
            launchMode: .customCommand, launchCommand: "exec /bin/bash --noprofile --norc"
        ))
        helper.connect()
        func helperConnected() -> Bool { if case .connected = helper.state { true } else { false } }
        for _ in 0..<700 where !helperConnected() {
            if let pending = helper.pendingHostKeyVerification, !pending.isResolved { pending.accept() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(helperConnected(), "the helper never connected: \(helper.state)")
        func remote(_ command: String) async throws -> String {
            try await helper.executeConnectedCommand(command)
        }
        // A single-pane window to leave for, and a split one to come back to,
        // each pane marked so its columns can be told apart.
        let left = "LEFT_\(token)", right = "RIGHT_\(token)", other = "OTHER_\(token)"
        _ = try await remote(
            "tmux new-session -d -s '\(name)' -x 80 -y 24 && "
                + "tmux new-window -t '=\(name):' && tmux split-window -h -t '=\(name):1' && "
                + "tmux send-keys -t '=\(name):0.0' 'printf \"%s\\n\" \(other)' Enter && "
                + "tmux send-keys -t '=\(name):1.0' 'printf \"%s\\n\" \(left)' Enter && "
                + "tmux send-keys -t '=\(name):1.1' 'printf \"%s\\n\" \(right)' Enter && "
                + "tmux select-window -t '=\(name):0'"
        )

        var host = Host(
            name: "SessionView compact split", address: config.stableHost, port: config.port,
            user: config.user, password: config.password, transport: .mosh, autoTmux: true, launchMode: .pinnedTmux
        )
        host.tmuxSessionName = name
        host.launchCommand = nil
        let session = MoshSession(host: host)
        let liveSessionID = UUID()
        let sessionRegistry = SessionRegistry()
        let controller = UIHostingController(rootView: SizeClassHost(box: SizeClassBox(), content: mounted(
            MoshSessionView(session: session, liveSessionID: liveSessionID, isActive: true, onToggleSidebar: {},
                            sidebarVisible: false, onBack: {}, onEditHost: {}, onRetry: {}, onSessionEnded: {},
                            onSelectSession: { _ in }, onOpenSettings: {}),
            registry: sessionRegistry, opening: liveSessionID)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }
        let acceptor = Task { @MainActor in
            for _ in 0..<900 {
                if let pending = session.pendingHostKeyVerification, !pending.isResolved { pending.accept() }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { acceptor.cancel() }
        for _ in 0..<450 where !sessionRegistry.isRenderReady(liveSessionID) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sessionRegistry.isRenderReady(liveSessionID), "the session never rendered")

        /// Each pane of the view session's current window: index, left column, width.
        func panes() async throws -> [(index: Int, left: Int, width: Int)] {
            try await remote("tmux list-panes -t '=\(view):' -F '#{pane_index} #{pane_left} #{pane_width}'")
                .split(whereSeparator: \.isNewline).compactMap { line in
                    let fields = line.split(separator: " ").compactMap { Int($0) }
                    return fields.count == 3 ? (fields[0], fields[1], fields[2]) : nil
                }
        }
        /// The canvas's rows, cut to one pane's columns.
        func columns(_ pane: (index: Int, left: Int, width: Int), of terminal: Terminal) -> String {
            (0..<terminal.rows).map { row in
                guard let data = terminal.getLine(row: row)?.getData() else { return "" }
                let end = min(pane.left + pane.width, data.count)
                return pane.left < end ? String(data[pane.left..<end].map { $0.getCharacter() }) : ""
            }.joined(separator: "\n")
        }
        func terminals(in view: UIView) -> [TerminalView] {
            (view as? TerminalView).map { [$0] } ?? view.subviews.flatMap(terminals)
        }
        /// Waits for the canvas to show `marker` in that pane's columns, and
        /// returns the window's width then (0 if it never did).
        @discardableResult
        func expectPane(_ index: Int, shows marker: String, _ label: String) async throws -> Int {
            var last = ""
            let started = Date()
            var layout: [(index: Int, left: Int, width: Int)] = []
            for _ in 0..<200 {
                // The window's layout once; then only the local canvas, so the
                // time printed is the paint's, not a remote poll's.
                if !layout.contains(where: { $0.index == index }) { layout = try await panes() }
                try await Task.sleep(nanoseconds: 20_000_000)
                guard let pane = layout.first(where: { $0.index == index }) else { continue }
                let width = layout.map { $0.left + $0.width }.max() ?? 0
                for terminal in terminals(in: controller.view).map({ $0.getTerminal() }) where terminal.cols == width {
                    last = columns(pane, of: terminal)
                    if last.contains(marker) {
                        // From the switch's command returning; `panes()` polls tmux too.
                        print("TESSERA_SPLIT_RETURN \(label) ms=\(Int(Date().timeIntervalSince(started) * 1_000))")
                        return width
                    }
                }
            }
            XCTFail("\(label): pane \(index) never showed \(marker); its columns read:\n\(last)")
            return 0
        }

        let singleWidth = try await expectPane(0, shows: other, "the single-pane window")
        _ = try await remote("tmux select-window -t '=\(view):1'")
        let splitWidth = try await expectPane(1, shows: right, "the split, first visit")
        // The lag needs the canvas to grow on the switch; without that this
        // test could not fail.
        XCTAssertGreaterThan(splitWidth, singleWidth, "the compact split must widen the client")
        _ = try await remote("tmux select-window -t '=\(view):0'")
        try await expectPane(0, shows: other, "back to the single pane")
        _ = try await remote("tmux select-window -t '=\(view):1'")
        try await expectPane(1, shows: right, "the split, quiet return")
        try await expectPane(0, shows: left, "the split's other pane, quiet return")
        _ = try? await remote(
            "tmux kill-session -t '=\(view)' >/dev/null 2>&1; tmux kill-session -t '=\(name)' >/dev/null 2>&1; true"
        )
        helper.disconnect()
    }

    /// A reader in an SSH+tmux pane's history keeps their rows through a
    /// font change. SwiftTerm parked them at the tail when the new font
    /// refit the grid, before the rebuild that follows recorded their place,
    /// so the rebuild restored the tail (Duo retest M4 and M5 item 1). The
    /// rebuild's clear also dropped the hold that keeps a VoiceOver reader
    /// through output, so the next output took them to the tail (M6 item
    /// 1): output follows each rebuild here, and a deepen's.
    func test_liveFontChangeKeepsATmuxReaderInHistory() async throws {
        let config = try Config.load()
        let fontSizeKey = "tessera.pref.fontSize"
        let savedFontSize = UserDefaults.standard.object(forKey: fontSizeKey)
        defer { UserDefaults.standard.set(savedFontSize, forKey: fontSizeKey) }
        let appearance = AppearancePreferences()
        appearance.fontSize = 13
        await KnownHostsStore.shared.remove(endpoint: "\(config.stableHost):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()
        let token = UUID().uuidString.prefix(8).lowercased()
        let name = "tessera-font-reader-\(token)"
        let helper = SSHSession(host: Host(
            name: "font reader helper", address: config.stableHost, port: config.port,
            user: config.user, password: config.password, transport: .ssh, autoTmux: false,
            launchMode: .customCommand, launchCommand: "exec /bin/bash --noprofile --norc"
        ))
        helper.connect()
        func helperConnected() -> Bool { if case .connected = helper.state { true } else { false } }
        for _ in 0..<700 where !helperConnected() {
            if let pending = helper.pendingHostKeyVerification, !pending.isResolved { pending.accept() }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(helperConnected(), "the helper never connected: \(helper.state)")
        func remote(_ command: String) async throws -> String {
            try await helper.executeConnectedCommand(command)
        }
        defer {
            Task { @MainActor in
                _ = try? await helper.executeConnectedCommand(
                    "for s in $(tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null"
                        + " | awk '$1 == \"\(name)\" || $2 == \"\(name)\" { print $1 }'); do"
                        + " tmux kill-session -t \"=$s\"; done; true"
                )
                helper.disconnect()
            }
        }
        // Numbered lines two rows long on a phone's grid and one row long
        // in a landscape window: tmux repaints history in its own rows at
        // each width, where only the reader's text finds their line. More of
        // them than the attach captures, so that paging to its oldest row
        // deepens it; history-limit sizes only panes made after it, hence the
        // replacement window.
        let dots = String(repeating: ".", count: 56)
        _ = try await remote(
            "tmux new-session -d -s '\(name)' -x 80 -y 24 \\; set-option -t '\(name)' history-limit 10000 \\; "
                + "new-window -k -t '\(name):0' && "
                + "tmux send-keys -t '=\(name):0.0' 'seq -f \"row-%04g \(dots)\" 1 3000' Enter"
        )
        for _ in 0..<100 {
            let size = Int(try await remote("tmux display -p -t '=\(name):0.0' '#{history_size}'")
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if size >= 2_900 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(appearance.scrollbackLines, 5_000, "the app's scrollback must hold a deepen")

        var host = Host(
            name: "SessionView font reader", address: config.stableHost, port: config.port,
            user: config.user, password: config.password, transport: .ssh, autoTmux: true, launchMode: .pinnedTmux
        )
        host.tmuxSessionName = name
        host.launchCommand = nil
        let session = SSHSession(host: host)
        let liveSessionID = UUID()
        let sessionRegistry = SessionRegistry()
        let controller = UIHostingController(rootView: SizeClassHost(box: SizeClassBox(), content: mounted(
            SessionView(session: session, liveSessionID: liveSessionID, isActive: true, onToggleSidebar: {},
                        sidebarVisible: false, onBack: {}, onEditHost: {}, onRetry: {}, onSessionEnded: {},
                        onSelectSession: { _ in }, onOpenSettings: {}),
            registry: sessionRegistry, opening: liveSessionID, appearance: appearance)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }
        let acceptor = Task { @MainActor in
            for _ in 0..<900 {
                if let pending = session.pendingHostKeyVerification, !pending.isResolved { pending.accept() }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { acceptor.cancel() }
        for _ in 0..<450 where !sessionRegistry.isRenderReady(liveSessionID) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sessionRegistry.isRenderReady(liveSessionID), "the session never rendered")

        func terminals(in view: UIView) -> [TerminalView] {
            (view as? TerminalView).map { [$0] } ?? view.subviews.flatMap(terminals)
        }
        /// The surface holding the pane's history, once it holds most of it.
        func historySurface() -> TerminalView? {
            terminals(in: controller.view).first { $0.contentSize.height > 10 * max(1, $0.bounds.height) }
        }
        /// The transcript row at the top of the surface, or `above` rows up.
        func topText(of view: TerminalView, above: Int = 0) -> String {
            let terminal = view.getTerminal()
            let font = view.font as CTFont
            let rowHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
            guard let first = (0..<20_000).first(where: { terminal.getScrollInvariantLine(row: $0) != nil }) else { return "" }
            return terminal.getScrollInvariantLine(row: first + Int((view.contentOffset.y / rowHeight).rounded()) - above)?
                .translateToString(trimRight: true).trimmingCharacters(in: .whitespaces) ?? ""
        }
        /// The number of the line at the top of the surface, whose second
        /// row may be the top one.
        func topRow(of view: TerminalView) -> Int? {
            for above in 0...1 {
                let text = topText(of: view, above: above)
                if text.hasPrefix("row-") { return Int(text.dropFirst(4).prefix(4)) }
                guard text.allSatisfy({ $0 == "." }) else { return nil }
            }
            return nil
        }
        /// For a failure to explain itself.
        func describe(_ view: TerminalView) -> String {
            let terminal = view.getTerminal()
            return "top=\(topText(of: view).debugDescription) offset=\(view.contentOffset.y) inset=\(view.contentInset.top) "
                + "content=\(view.contentSize.height) bounds=\(view.bounds.height) grid=\(terminal.cols)x\(terminal.rows) "
                + "screen=\((0..<min(3, terminal.rows)).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" })"
        }
        var surface: TerminalView?
        for _ in 0..<100 {
            surface = historySurface()
            if surface != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let view = try XCTUnwrap(surface, "the pane's history never arrived")
        for _ in 0..<6 { XCTAssertTrue(view.accessibilityScroll(.up), "a VoiceOver page must move") }
        let held = try XCTUnwrap(topRow(of: view), "no numbered line at the top: \(describe(view))")
        XCTAssertLessThan(held, 3000 - 2 * view.getTerminal().rows, "the reader must be in history")
        /// The reader's row once the grid changed and the rebuild that
        /// follows it (tmux's resize, then the pane's history) settled.
        func settledRow(after change: String, from grid: (Int, Int)) async throws -> Int {
            var settled: Int?
            var previous: Int?
            var steady = 0
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                let current = historySurface().flatMap(topRow)
                let terminal = (historySurface() ?? view).getTerminal()
                let refit = terminal.cols != grid.0 || terminal.rows != grid.1
                steady = current != nil && current == previous ? steady + 1 : 0
                previous = current
                if refit, steady >= 15 { settled = current; break }
            }
            let terminal = (historySurface() ?? view).getTerminal()
            XCTAssertTrue(terminal.cols != grid.0 || terminal.rows != grid.1, "\(change) must refit the grid")
            return try XCTUnwrap(settled ?? previous,
                                 "no numbered line at the top after \(change): \(describe(historySurface() ?? view))")
        }
        /// Some output, the way a program's arrives (typing here would
        /// return the reader to the prompt): the reader stays on `row`.
        func assertOutputKeeps(_ row: Int, after change: String) async throws {
            let before = (historySurface() ?? view).contentSize.height
            _ = try await remote(
                "tmux send-keys -t '=\(name):0.0' 'printf \"out-%s\\n\" 1 2 3' Enter"
            )
            for _ in 0..<50 where (historySurface() ?? view).contentSize.height <= before {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertGreaterThan((historySurface() ?? view).contentSize.height, before, "no output arrived after \(change)")
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(historySurface().flatMap(topRow), row,
                           "output after \(change) moved the reader: \(describe(historySurface() ?? view))")
        }
        try await assertOutputKeeps(held, after: "the pages")

        appearance.fontSize = 15
        let afterFont = try await settledRow(
            after: "15 pt", from: (view.getTerminal().cols, view.getTerminal().rows))
        XCTAssertLessThanOrEqual(abs(afterFont - held), 2,
            "the reader held line \(held) and came back at \(afterFont) after 15 pt: \(describe(historySurface() ?? view))")
        try await assertOutputKeeps(afterFont, after: "15 pt")

        // A rotation or a Duo pose refits the grid through layout the same
        // way (items 3 and 4). A landscape row holds a whole line, so tmux's
        // repaint has half the rows between the reader and the tail.
        let rotating = (historySurface() ?? view).getTerminal()
        let grid = (rotating.cols, rotating.rows)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let afterRotation = try await settledRow(after: "a landscape window", from: grid)
        XCTAssertLessThanOrEqual(abs(afterRotation - afterFont), 2,
            "the reader held line \(afterFont) and came back at \(afterRotation) after rotating: \(describe(historySurface() ?? view))")
        try await assertOutputKeeps(afterRotation, after: "rotating")

        // Paging toward the oldest row the attach captured asks tmux for
        // more. The deepen rebuilds the transcript under the reader and puts
        // them back on their line, held.
        let shallow = (historySurface() ?? view).contentSize.height
        var reading: Int?
        var requested = false
        for _ in 0..<1_000 where !requested {
            let surface = historySurface() ?? view
            _ = surface.accessibilityScroll(.up)
            reading = topRow(of: surface) ?? reading
            try await Task.sleep(nanoseconds: surface.contentOffset.y < 1 ? 100_000_000 : 5_000_000)
            requested = (historySurface() ?? view).contentSize.height != shallow
        }
        XCTAssertTrue(requested, "paging toward the oldest row must deepen: \(describe(historySurface() ?? view))")
        let paged = try XCTUnwrap(reading, "no numbered line at the top while paging")
        var placed: Int?
        var steady = 0
        for _ in 0..<150 where steady < 15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard (historySurface()?.contentSize.height ?? 0) > shallow else { steady = 0; continue }
            let current = historySurface().flatMap(topRow)
            steady = current != nil && current == placed ? steady + 1 : 0
            placed = current
        }
        let afterDeepen = try XCTUnwrap(placed, "the deepened page never settled: \(describe(historySurface() ?? view))")
        XCTAssertLessThanOrEqual(abs(afterDeepen - paged), 2,
            "the reader paged to line \(paged) and came back at \(afterDeepen) after the deepen: \(describe(historySurface() ?? view))")
        try await assertOutputKeeps(afterDeepen, after: "a deepen")
    }

    /// The app's environment around a mounted session view, opened as
    /// ContentView opens one: a session the user did not open stays hidden
    /// to tmux's grid authority, which then sizes nothing.
    private func mounted<Content: View>(
        _ view: Content,
        registry: SessionRegistry,
        opening liveSessionID: UUID,
        appearance: AppearancePreferences = AppearancePreferences()
    ) -> some View {
        let appPhase = AppPhase()
        let showEdges = SessionShowCoordinator(appForeground: true, locked: false)
        showEdges.setSelectedSlot(liveSessionID)
        showEdges.explicitOpen(liveSessionID)
        return view
            .environment(\.sessionShowCoordinator, showEdges)
            .environment(appearance)
            .environment(AppLockController(appearance: appearance))
            .environment(BellController(appearance: appearance, appPhase: appPhase))
            .environment(TunnelsRegistry())
            .environment(SwipePadProfileStore())
            .environment(SpeechDictationController(appearance: appearance))
            .environment(registry)
            .environment(CommandPalette())
            .environment(AgentCenterV2Coordinator())
            .environment(ProgramStatusCenter())
            .environment(appPhase)
            .environment(FileBridgeRegistry())
            .environment(HostTerminalBackgroundStore())
            .environment(ShortcutStore())
    }

    private func runMountedLaunch(
        config: Config,
        label: String,
        user: String? = nil,
        expectsControlMode: Bool = true,
        keepSession: Bool = false
    ) async throws {
        let host = Host(
            name: "SessionView \(label)",
            address: config.stableHost,
            port: config.port,
            user: user ?? config.user,
            password: config.password,
            transport: .ssh,
            autoTmux: true,
            launchMode: .autoTmux
        )
        await KnownHostsStore.shared.remove(endpoint: "\(config.stableHost):\(config.port)")
        SSHAuthenticationPolicyStore.shared.resetForTesting()

        let session = SSHSession(host: host)
        let liveSessionID = UUID()

        let sessionRegistry = SessionRegistry()
        let view = mounted(SessionView(
            session: session,
            liveSessionID: liveSessionID,
            isActive: true,
            onToggleSidebar: {},
            sidebarVisible: false,
            onBack: {},
            onEditHost: {},
            onRetry: {},
            onSessionEnded: {},
            onSelectSession: { _ in },
            onOpenSettings: {}
        ), registry: sessionRegistry, opening: liveSessionID)

        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        defer {
            session.disconnect()
            window.isHidden = true
            window.rootViewController = nil
        }

        // Accept the first-connect host-key prompt the way ContentView does.
        let acceptor = Task { @MainActor in
            for _ in 0..<600 {
                if let pending = session.pendingHostKeyVerification, !pending.isResolved {
                    pending.accept()
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { acceptor.cancel() }

        // The overlay dropping is the user-visible contract: either tmux
        // took over, or the launch degraded to the plain shell. Both must
        // happen inside the watchdog window; neither may hang.
        let started = Date()
        let deadline = started.addingTimeInterval(expectsControlMode ? 30 : 45)
        while Date() < deadline {
            if sessionRegistry.isRenderReady(liveSessionID) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let ready = sessionRegistry.isRenderReady(liveSessionID)
        let elapsed = Date().timeIntervalSince(started)
        let report = "[\(label)] renderReady=\(ready) after=\(String(format: "%.1f", elapsed))s "
            + "state=\(session.state) launchMode=\(session.host.launchMode.rawValue)"
        print(report)
        XCTAssertTrue(ready, "launch overlay never cleared — \(report)")
        if !expectsControlMode {
            XCTAssertEqual(
                session.state,
                .connected,
                "degrading must keep the shell session alive — \(report)"
            )
        }
        // The launch created the host's automatic session on the shared
        // fixture: remove it by exact name so the next run starts from a
        // fresh host again.
        if expectsControlMode, !keepSession {
            _ = try? await session.executeConnectedCommand(
                "tmux kill-session -t '=\(HostRuntimeStateStore.sessionName(for: host))' >/dev/null 2>&1 || true"
            )
        }
    }
}

/// The size class a mounted session view reads, changed without remounting it.
@Observable
private final class SizeClassBox {
    var value: UserInterfaceSizeClass = .compact
}

private struct SizeClassHost<Content: View>: View {
    let box: SizeClassBox
    let content: Content
    var body: some View { content.environment(\.horizontalSizeClass, box.value) }
}
#endif
