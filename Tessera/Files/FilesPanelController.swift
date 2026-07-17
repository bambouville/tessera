// Tessera/Files/FilesPanelController.swift
//
// State + dispatch glue for the Remote Files panel. One controller per
// SessionView / MoshSessionView instance (mirrors FindController's
// scoping). The controller owns no transport- or UIKit-specific code:
// the session view installs a FileBridging implementation and pushes
// cwd reports into `terminalReportedDirectory(_:)`; feature packets
// (preview, share, transfers, injection) install optional handler
// closures — menu items for absent handlers stay hidden, so the panel
// degrades gracefully while later milestones land.

import Foundation
import Observation

@Observable
@MainActor
final class FilesPanelController {

    // MARK: - Follow state

    enum FollowState: Equatable {
        /// Panel root tracks the terminal's reported cwd live.
        case following
        /// User navigated elsewhere; the link is broken until re-tapped.
        case manual
        /// No cwd signal from this session (plain SSH/mosh without shell
        /// integration) — panel offers the installer CTA and browses from
        /// $HOME.
        case unavailable
    }

    // MARK: - Handlers installed by later packets

    /// All optional: nil hides the corresponding action in the UI.
    var onPreviewFile: ((RemoteFileEntry) -> Void)?
    var onDownloadFile: ((RemoteFileEntry) -> Void)?
    var onShareFile: ((RemoteFileEntry) -> Void)?
    var onSendPathToTerminal: ((String) -> Void)?
    var onUploadRequested: (() -> Void)?
    var onInstallShellIntegration: (() -> Void)?

    // MARK: - Presentation requests (observed by the panel's sheets)

    struct PreviewRequest: Identifiable {
        let id = UUID()
        let localURL: URL
        let title: String
    }

    struct ShareRequest: Identifiable {
        let id = UUID()
        let items: [URL]
    }

    /// Set when a preview/share download completes; the panel view binds
    /// `.sheet(item:)` to these. Plain Foundation values — the controller
    /// stays UIKit-free.
    var presentedPreview: PreviewRequest?
    var presentedShare: ShareRequest?

    /// Toolbar "upload here" → the panel view's fileImporter binds this.
    var showingUploadPicker = false

    // MARK: - Wiring

    private(set) var bridge: (any FileBridging)?
    /// Installed by the transfer packet; the strip renders when non-nil.
    var transfers: (any TransferQueueing)?

    func attach(bridge: any FileBridging) {
        self.bridge = bridge
        bridge.suppressIdleTeardown = isOpen
    }

    // MARK: - Visibility

    private(set) var isOpen = false

    /// Opening is the user gesture that permits the lazy bridge connect
    /// (the never-auto-connect rule: nothing dials before this).
    func open() {
        isOpen = true
        bridge?.suppressIdleTeardown = true
        Task { await ensureConnectedAndLoad() }
    }

    func close() {
        isOpen = false
        bridge?.suppressIdleTeardown = false
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    // MARK: - Directory / follow state

    /// Last cwd the terminal reported (tmux pane_current_path or OSC 7).
    private(set) var terminalDirectory: String?
    /// The panel's current root directory (absolute).
    private(set) var currentDirectory: String?
    private(set) var followEnabled = true

    var followState: FollowState {
        if terminalDirectory == nil { return .unavailable }
        return followEnabled ? .following : .manual
    }

    /// Every cwd report funnels through here (tmux pane path, OSC 7,
    /// poller) — this mirror lets the session view propagate the value
    /// to transport-agnostic consumers (TerminalSession
    /// .remoteWorkingDirectory, read by the Upload sheet).
    var onTerminalDirectoryChanged: ((String?) -> Void)?

    /// Session view pushes every cwd report here, regardless of source.
    /// Passing nil (e.g. tmux detached) flips the panel to .unavailable
    /// but keeps the current listing browsable.
    func terminalReportedDirectory(_ path: String?) {
        terminalDirectory = normalize(path)
        onTerminalDirectoryChanged?(terminalDirectory)
        guard isOpen, followEnabled, let dir = terminalDirectory,
              dir != currentDirectory else { return }
        Task { await load(directory: dir) }
    }

    /// Single-quote shell quoting for a path typed into the terminal
    /// (paste-path / send-path): safe for spaces and specials, no
    /// trailing newline. Same `'\''` idiom the transfer/poller remote
    /// commands use.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Link-glyph tap: re-enable follow (snapping to the terminal's cwd)
    /// or break it. In .unavailable there is nothing to toggle.
    func toggleFollow() {
        guard terminalDirectory != nil else { return }
        followEnabled.toggle()
        if followEnabled, let dir = terminalDirectory {
            Task { await load(directory: dir) }
        }
    }

    /// Breadcrumb tap / manual navigation. Breaks follow (the panel
    /// never fights the user).
    func navigate(to path: String) {
        followEnabled = false
        Task { await load(directory: path) }
    }

    func refresh() {
        guard let dir = currentDirectory else { return }
        Task { await load(directory: dir, evictingChildren: true) }
    }

    // MARK: - Listing / tree state

    private(set) var childrenByPath: [String: [RemoteFileEntry]] = [:]
    private(set) var expandedPaths: Set<String> = []
    private(set) var loadingPaths: Set<String> = []
    private(set) var isLoadingRoot = false
    var showHidden = false
    var sortByModified = false
    /// Toolbar search (§1 of the improvements mockup): while active
    /// the panel filters the LOADED rows (current directory + expanded
    /// subfolders) by name, live. A filter, not a host-wide find.
    var searchActive = false {
        didSet { if !searchActive { searchText = "" } }
    }
    var searchText = ""
    var lastError: String?
    /// Non-error transient notice (e.g. "shell integration installed —
    /// takes effect on the next login"). Rendered dimmer than errors.
    var infoMessage: String?

    /// True while any of the panel's alerts (rename / new folder /
    /// install / delete) is presented. The session view ORs this into
    /// `suppressFirstResponderReclaim` so the terminal doesn't steal
    /// keyboard focus from an alert's TextField mid-word — the same
    /// gate the find bar needed (see TerminalSurfaceBound.updateUIView).
    var textEntryActive = false

    struct Row: Identifiable, Equatable {
        let entry: RemoteFileEntry
        let depth: Int
        var id: String { entry.path }
    }

    /// Flattened outline rows: current directory's entries with expanded
    /// subdirectories walked depth-first.
    var rows: [Row] {
        guard let root = currentDirectory else { return [] }
        var out: [Row] = []
        appendRows(of: root, depth: 0, into: &out)
        return out
    }

    /// Rows surviving the live filter (§1). Case-insensitive substring
    /// on the entry name; original depth preserved (the view flattens).
    var searchRows: [Row] {
        guard !searchText.isEmpty else { return rows }
        return rows.filter { $0.entry.name.localizedCaseInsensitiveContains(searchText) }
    }

    /// How many loaded rows the filter is hiding (footer count).
    var searchHiddenCount: Int {
        guard !searchText.isEmpty else { return 0 }
        return max(0, rows.count - searchRows.count)
    }

    private func appendRows(of path: String, depth: Int, into out: inout [Row]) {
        for entry in visibleChildren(of: path) {
            out.append(Row(entry: entry, depth: depth))
            if entry.kind == .directory, expandedPaths.contains(entry.path) {
                appendRows(of: entry.path, depth: depth + 1, into: &out)
            }
        }
    }

    private func visibleChildren(of path: String) -> [RemoteFileEntry] {
        var entries = childrenByPath[path] ?? []
        if !showHidden { entries.removeAll(where: \.isHidden) }
        return sorted(entries)
    }

    private func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted { a, b in
            let aDir = a.kind == .directory, bDir = b.kind == .directory
            if aDir != bDir { return aDir }
            if sortByModified, a.modified != b.modified {
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func isExpanded(_ entry: RemoteFileEntry) -> Bool {
        expandedPaths.contains(entry.path)
    }

    func isLoading(_ entry: RemoteFileEntry) -> Bool {
        loadingPaths.contains(entry.path)
    }

    func toggleExpanded(_ entry: RemoteFileEntry) {
        guard entry.kind == .directory else { return }
        if expandedPaths.contains(entry.path) {
            expandedPaths.remove(entry.path)
            return
        }
        expandedPaths.insert(entry.path)
        if childrenByPath[entry.path] == nil {
            Task { await loadChildren(of: entry.path) }
        }
    }

    // MARK: - Breadcrumbs

    struct Crumb: Identifiable, Equatable {
        let name: String
        let path: String
        var id: String { path }
    }

    /// Absolute path split into tappable components, with $HOME
    /// abbreviated to "~".
    var breadcrumbs: [Crumb] {
        guard var path = currentDirectory else { return [] }
        var crumbs: [Crumb] = []
        let home = bridge?.homeDirectory
        let prefixCrumb: Crumb
        if let home, path == home || path.hasPrefix(home + "/") {
            prefixCrumb = Crumb(name: "~", path: home)
            path = String(path.dropFirst(home.count))
        } else {
            prefixCrumb = Crumb(name: "/", path: "/")
        }
        var running = prefixCrumb.path
        for component in path.split(separator: "/") where !component.isEmpty {
            running = running == "/" ? "/\(component)" : "\(running)/\(component)"
            crumbs.append(Crumb(name: String(component), path: running))
        }
        return [prefixCrumb] + crumbs
    }

    // MARK: - Path input (§2 path bar / §4 quick open)

    /// Path-bar commit: directories only (the bar edits *where the
    /// panel is*; quick-open is the file verb). Returns true when
    /// navigation happened — the view exits edit mode on success and
    /// keeps the field up on failure, with the error banner explaining.
    func commitPathInput(_ typed: String) async -> Bool {
        guard let bridge else { return false }
        lastError = nil
        do {
            try await bridge.connect()
            guard let absolute = RemotePathResolver.expand(
                typed, home: bridge.homeDirectory,
                cwd: terminalDirectory ?? currentDirectory) else {
                lastError = "Can't resolve: \(typed)"
                return false
            }
            switch try await RemotePathResolver.resolve(absolute: absolute, bridge: bridge) {
            case .directory(let path):
                followEnabled = false
                await load(directory: path)
                return lastError == nil
            case .file:
                lastError = "Not a directory: \(absolute)"
                return false
            }
        } catch {
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Quick-open commit: file → Quick Look, directory → browse there.
    /// Returns true when the popover should dismiss.
    func quickOpen(_ typed: String) async -> Bool {
        guard let bridge else { return false }
        lastError = nil
        do {
            try await bridge.connect()
            guard let absolute = RemotePathResolver.expand(
                typed, home: bridge.homeDirectory,
                cwd: terminalDirectory ?? currentDirectory) else {
                lastError = "Can't resolve: \(typed)"
                return false
            }
            switch try await RemotePathResolver.resolve(absolute: absolute, bridge: bridge) {
            case .directory(let path):
                followEnabled = false
                await load(directory: path)
            case .file(let entry):
                onPreviewFile?(entry)
            }
            noteRecentQuickOpen(absolute)
            return true
        } catch {
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Recents are deliberately ephemeral: in-memory per host key,
    /// shared across sessions to the same endpoint, gone on relaunch.
    /// Never SwiftData (see the iOS 26 array-migration gotcha).
    private static var recentQuickOpensByKey: [FileBridgeKey: [String]] = [:]

    var recentQuickOpenPaths: [String] {
        guard let key = bridge?.key else { return [] }
        return Self.recentQuickOpensByKey[key] ?? []
    }

    private func noteRecentQuickOpen(_ absolute: String) {
        guard let key = bridge?.key else { return }
        var recents = Self.recentQuickOpensByKey[key] ?? []
        recents.removeAll { $0 == absolute }
        recents.insert(absolute, at: 0)
        Self.recentQuickOpensByKey[key] = Array(recents.prefix(5))
    }

    /// Completion feed (§2, reused verbatim by quick-open): entries of
    /// the directory the typed input completes inside, served from the
    /// browse cache when warm. Cold parents fetch over the bridge and
    /// warm the same cache (harmless keys — `rows` only walks from
    /// `currentDirectory` plus expansions).
    func completionEntries(
        forTyped typed: String
    ) async -> (context: RemotePathResolver.CompletionContext, entries: [RemoteFileEntry])? {
        guard let bridge else { return nil }
        guard let context = RemotePathResolver.completionContext(
            forTyped: typed, home: bridge.homeDirectory,
            cwd: terminalDirectory ?? currentDirectory) else { return nil }
        if let cached = childrenByPath[context.parentPath] {
            return (context, cached)
        }
        guard bridge.state == .connected,
              let entries = try? await bridge.listDirectory(context.parentPath) else { return nil }
        childrenByPath[context.parentPath] = entries
        return (context, entries)
    }

    // MARK: - Terminal-initiated open (§3 selection menu)

    enum TerminalPathIntent { case quickLook, reveal }

    /// Selection-menu entry point. The panel may be CLOSED here: misses
    /// surface through `onMiss` (the session view routes it to the
    /// terminal toast), and file previews present via the session-level
    /// sheet host, so nothing gates on `isOpen`.
    func openTerminalPath(
        _ selection: String,
        cwd: String?,
        intent: TerminalPathIntent,
        onMiss: @escaping @MainActor (String) -> Void
    ) {
        guard let bridge, let queue = transfers else { return }
        Task { @MainActor in
            do {
                try await bridge.connect()
                guard let candidate = RemotePathResolver.pathCandidate(from: selection) else {
                    onMiss("Selection doesn't look like a path.")
                    return
                }
                guard let absolute = RemotePathResolver.expand(
                    candidate, home: bridge.homeDirectory,
                    cwd: cwd ?? terminalDirectory) else {
                    onMiss("Can't resolve \(candidate) — no directory signal for relative paths.")
                    return
                }
                switch (try await RemotePathResolver.resolve(absolute: absolute, bridge: bridge), intent) {
                case (.file(let entry), .quickLook):
                    stageForPresentation(
                        entry, using: queue, allowClosedPanel: true, onFailure: onMiss
                    ) { [weak self] url in
                        self?.presentedPreview = PreviewRequest(localURL: url, title: entry.name)
                    }
                case (.file(let entry), .reveal):
                    revealDirectory((entry.path as NSString).deletingLastPathComponent)
                case (.directory(let path), _):
                    revealDirectory(path)
                }
            } catch {
                onMiss((error as? FileBridgeError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Open the panel focused on `path` (directory hits / “Reveal”).
    /// A minimal `open()` variant: skips ensureConnectedAndLoad's cwd
    /// targeting so the reveal target can't race the follow signal.
    private func revealDirectory(_ path: String) {
        followEnabled = false
        isOpen = true
        bridge?.suppressIdleTeardown = true
        Task { await load(directory: path) }
    }

    // MARK: - Mutations (wired into the UI at the write-path milestone)

    func createFolder(named name: String) {
        guard let dir = currentDirectory, !name.isEmpty else { return }
        let path = dir == "/" ? "/\(name)" : "\(dir)/\(name)"
        Task {
            await run { try await self.bridge?.createDirectory(path) }
            await load(directory: dir, evictingChildren: true)
        }
    }

    func rename(_ entry: RemoteFileEntry, to newName: String) {
        guard !newName.isEmpty, newName != entry.name else { return }
        let parent = parentPath(of: entry.path)
        let newPath = parent == "/" ? "/\(newName)" : "\(parent)/\(newName)"
        Task {
            await run { try await self.bridge?.rename(from: entry.path, to: newPath) }
            await loadChildren(of: parent)
        }
    }

    func delete(_ entry: RemoteFileEntry) {
        let parent = parentPath(of: entry.path)
        Task {
            await run {
                if entry.kind == .directory {
                    try await self.bridge?.removeDirectory(entry.path)
                } else {
                    try await self.bridge?.removeFile(entry.path)
                }
            }
            await loadChildren(of: parent)
        }
    }

    // MARK: - Internals

    private func ensureConnectedAndLoad() async {
        guard let bridge else { return }
        let wasConnected = bridge.state == .connected
        do {
            try await bridge.connect()
        } catch {
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
            return
        }
        // Browse-only sessions must honor the "auto-cleans after N d"
        // promise too — the transfer path only reaps when something
        // is actually transferred.
        transfers?.scheduleReaperIfNeeded(freshConnect: !wasConnected)
        let target = (followEnabled ? terminalDirectory : currentDirectory)
            ?? currentDirectory
            ?? terminalDirectory
            ?? bridge.homeDirectory
            ?? "/"
        await load(directory: target)
    }

    /// Monotonic token: each navigation supersedes in-flight loads, so
    /// a slow listDirectory reply can't clobber a newer directory (cd
    /// during load, rapid breadcrumb taps, follow racing manual nav).
    private var loadGeneration = 0

    private func load(directory: String, evictingChildren: Bool = false) async {
        guard let bridge else { return }
        let dir = normalize(directory) ?? directory
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingRoot = childrenByPath[dir] == nil
        lastError = nil
        if evictingChildren {
            childrenByPath = childrenByPath.filter { $0.key == dir }
        }
        do {
            let entries = try await bridge.listDirectory(dir)
            guard generation == loadGeneration else { return }
            childrenByPath[dir] = entries
            if currentDirectory != dir {
                currentDirectory = dir
                expandedPaths.removeAll()
            }
        } catch {
            guard generation == loadGeneration else { return }
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingRoot = false
    }

    private func loadChildren(of path: String) async {
        guard let bridge else { return }
        loadingPaths.insert(path)
        defer { loadingPaths.remove(path) }
        do {
            childrenByPath[path] = try await bridge.listDirectory(path)
        } catch {
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
            expandedPaths.remove(path)
        }
    }

    private func run(_ op: @MainActor () async throws -> Void) async {
        lastError = nil
        do {
            try await op()
        } catch {
            lastError = (error as? FileBridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - File actions (M2: download / preview / share / drag-out)

    /// Wires the transfer queue and the download/preview/share handlers.
    /// Called by the session views right after `attach(bridge:)` — the
    /// closures only touch the controller, its bridge, and the queue, so
    /// SSH and mosh share this single implementation.
    ///
    ///   - Downloads land in Documents/<hostFolderName>/ ("On My iPad/
    ///     Tessera/<host>/" in Files.app), collision-suffixed.
    ///   - Preview/share download to a per-request temp dir first, then
    ///     flip the matching presentation request; failures surface via
    ///     the item's phase in the transfer strip.
    func configureFileActions(transfers queue: any TransferQueueing, hostFolderName: String) {
        transfers = queue

        onDownloadFile = { [weak self] entry in
            guard let self else { return }
            do {
                let destination = try Self.uniqueDownloadDestination(
                    named: entry.name, hostFolderName: hostFolderName)
                queue.enqueueDownload(
                    remotePath: entry.path, displayName: entry.name, to: destination)
            } catch {
                self.lastError = error.localizedDescription
            }
        }

        onPreviewFile = { [weak self] entry in
            self?.stageForPresentation(entry, using: queue) { url in
                self?.presentedPreview = PreviewRequest(localURL: url, title: entry.name)
            }
        }

        onShareFile = { [weak self] entry in
            self?.stageForPresentation(entry, using: queue) { url in
                self?.presentedShare = ShareRequest(items: [url])
            }
        }

        onUploadRequested = { [weak self] in
            self?.showingUploadPicker = true
        }
    }

    // MARK: - Local-file uploads (picker + drop-on-panel)

    /// fileImporter results: security-scoped URLs. Staging runs off the
    /// main actor — the coordinated read can block while an evicted
    /// iCloud file downloads — with the scope held for its duration;
    /// the destination is captured NOW, not when staging finishes.
    func uploadLocalFiles(_ urls: [URL]) {
        guard transfers != nil else { return }
        guard let dir = currentDirectory else {
            lastError = "No destination directory yet."
            return
        }
        for url in urls {
            Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let staged = try FilesPanelController.stageLocalCopy(of: url)
                    await MainActor.run { [weak self] in
                        self?.enqueueStagedUpload(staged, toDirectory: dir)
                    }
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run { [weak self] in
                        self?.lastError = message
                    }
                }
            }
        }
    }

    /// Drop-on-panel. Providers deliver their file representation on a
    /// background queue into a temp URL that dies when the callback
    /// returns — copy synchronously there, then enqueue on main into
    /// the directory shown AT DROP TIME (follow-mode can move
    /// currentDirectory before a slow provider materializes).
    /// Returns whether the drop was accepted.
    func handleDroppedItems(_ providers: [NSItemProvider]) -> Bool {
        guard transfers != nil, let dir = currentDirectory else { return false }
        var accepted = false
        for provider in providers {
            // Skip the panel's own drag-out rows: a self-drop would
            // download the remote file and re-upload it onto itself.
            guard !provider.hasItemConformingToTypeIdentifier(
                RemoteFileItemProvider.localDragMarkerTypeIdentifier) else { continue }
            guard let typeID = provider.registeredTypeIdentifiers.first else { continue }
            accepted = true
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url, let staged = try? Self.stageLocalCopy(of: url) else { return }
                Task { @MainActor [weak self] in
                    self?.enqueueStagedUpload(staged, toDirectory: dir)
                }
            }
        }
        return accepted
    }

    /// Drop-on-terminal: stage each dropped file, upload it to the
    /// host's temp dir (paste naming + reaper), then hand the resolved
    /// remote paths back for injection into the session. The panel's
    /// own drag-out rows are skipped — that file is already ON the
    /// host. Staging fans out, but enqueue/injection preserve the
    /// original drag order via TerminalDropBatch (provider callbacks
    /// complete in size-dependent order, which would otherwise
    /// scramble multi-file argument order). Returns acceptance.
    static func handleTerminalDrop(
        _ providers: [NSItemProvider],
        queue: any TransferQueueing,
        inject: @escaping @MainActor (String) -> Void,
        reportFailure: @escaping @MainActor (String) -> Void
    ) -> Bool {
        let eligible = providers.filter {
            !$0.hasItemConformingToTypeIdentifier(
                RemoteFileItemProvider.localDragMarkerTypeIdentifier)
                && !$0.registeredTypeIdentifiers.isEmpty
        }
        guard !eligible.isEmpty else { return false }

        let batch = TerminalDropBatch(
            count: eligible.count,
            queue: queue,
            inject: inject,
            reportFailure: reportFailure
        )
        for (index, provider) in eligible.enumerated() {
            let typeID = provider.registeredTypeIdentifiers[0]
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                let staged = url.flatMap { try? Self.stageLocalCopy(of: $0) }
                Task { @MainActor in
                    batch.deliver(index: index, staged: staged)
                }
            }
        }
        return true
    }

    private func enqueueStagedUpload(_ staged: URL, toDirectory dir: String) {
        guard let queue = transfers else { return }
        let item = queue.enqueueUpload(localURL: staged, toDirectory: dir)
        Task { [weak self] in
            await item.awaitFinished()
            if item.phase == .completed { self?.refresh() }
        }
    }

    /// Copy into a private staging dir so the upload outlives both the
    /// security scope (picker) and the provider callback (drop). The
    /// read is coordinated: fileImporter hands back UNMATERIALIZED URLs
    /// for evicted iCloud Drive items, and only a coordinated read
    /// triggers the download (a bare copyItem throws).
    nonisolated static func stageLocalCopy(of url: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [], error: &coordinationError
        ) { readURL in
            do {
                try FileManager.default.copyItem(at: readURL, to: staged)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return staged
    }

    /// Drag-out source for a row: a lazy file promise that downloads
    /// over the bridge only when a drop target accepts (dragging an
    /// 18 MB log to Mail doesn't pre-fetch it). nil for non-files.
    func dragItemProvider(for entry: RemoteFileEntry) -> NSItemProvider? {
        guard let bridge else { return nil }
        return RemoteFileItemProvider.itemProviderIfDraggable(for: entry) { destination in
            try await bridge.download(remotePath: entry.path, to: destination, progress: nil)
        }
    }

    /// Download to a fresh temp dir, wait for the queue to finish the
    /// item, then hand the local URL to `present`. Cancellation/failure
    /// end silently here — the transfer strip already shows them.
    private func stageForPresentation(
        _ entry: RemoteFileEntry,
        using queue: any TransferQueueing,
        allowClosedPanel: Bool = false,
        onFailure: (@MainActor (String) -> Void)? = nil,
        present: @escaping (URL) -> Void
    ) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            lastError = error.localizedDescription
            return
        }
        let destination = staging.appendingPathComponent(entry.name, isDirectory: false)
        let item = queue.enqueueDownload(
            remotePath: entry.path, displayName: entry.name, to: destination)
        Task { [weak self] in
            await item.awaitFinished()
            // isOpen gate: a download that finishes after the panel
            // closed must not pop its sheet on the next open. Terminal-
            // initiated previews (§3) present with the panel closed by
            // design — the session view hosts their sheet.
            guard let self, allowClosedPanel || self.isOpen else { return }
            switch item.phase {
            case .completed:
                present(destination)
            case .failed(let message):
                // Panel-initiated previews surface failures in the
                // transfer strip; terminal-initiated ones (§3) run with
                // the panel closed, so the caller supplies a toast.
                onFailure?(message)
            default:
                break
            }
        }
    }

    /// Documents/<hostFolderName>/<name>, suffixing "name 2.ext" style
    /// on collisions. Documents == "On My iPad/Tessera" (file sharing
    /// is enabled in Info.plist).
    static func uniqueDownloadDestination(named name: String, hostFolderName: String) throws -> URL {
        let sanitizedFolder = hostFolderName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent(sanitizedFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var attempt = 0
        while true {
            attempt += 1
            let candidateName = attempt == 1 ? name
                : ext.isEmpty ? "\(base) \(attempt)" : "\(base) \(attempt).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
    }

    /// Strips trailing slashes and percent-decodes OSC 7-style values.
    /// Accepts both bare paths and `file://host/path` URLs.
    private func normalize(_ raw: String?) -> String? {
        guard var value = raw, !value.isEmpty else { return nil }
        if value.hasPrefix("file://") {
            // OSC 7 payload: file://hostname/percent-encoded-path. Trust
            // the path, ignore the hostname (VPNs/containers lie).
            let afterScheme = value.dropFirst("file://".count)
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            value = String(afterScheme[slash...])
            value = value.removingPercentEncoding ?? value
        }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        guard value.hasPrefix("/") else { return nil }
        return value
    }
}

/// One terminal drop's staging results, re-serialized: providers
/// materialize on background queues in size-dependent order, so the
/// batch waits for every slot, then enqueues in the ORIGINAL drag
/// order and injects strictly sequentially — `part1 part2 part3`
/// stays `part1 part2 part3` on the command line.
@MainActor
private final class TerminalDropBatch {
    private var staged: [URL?]
    private var remaining: Int
    private let queue: any TransferQueueing
    private let inject: @MainActor (String) -> Void
    private let reportFailure: @MainActor (String) -> Void

    init(
        count: Int,
        queue: any TransferQueueing,
        inject: @escaping @MainActor (String) -> Void,
        reportFailure: @escaping @MainActor (String) -> Void
    ) {
        self.staged = Array(repeating: nil, count: count)
        self.remaining = count
        self.queue = queue
        self.inject = inject
        self.reportFailure = reportFailure
    }

    func deliver(index: Int, staged url: URL?) {
        staged[index] = url
        remaining -= 1
        guard remaining == 0 else { return }

        let unreadable = staged.count - staged.compactMap { $0 }.count
        if unreadable > 0 {
            reportFailure(unreadable == 1
                ? "Couldn't read the dropped file."
                : "Couldn't read \(unreadable) dropped files.")
        }
        let items = staged.compactMap { $0 }.map {
            queue.enqueuePasteUpload(localURL: $0)
        }
        guard !items.isEmpty else { return }
        Task { @MainActor [inject, reportFailure] in
            for item in items {
                await item.awaitFinished()
                switch item.phase {
                case .completed:
                    if let path = item.resolvedRemotePath { inject(path) }
                case .failed(let message):
                    reportFailure(message)
                default:
                    break
                }
            }
        }
    }
}

/// Suspends until the item leaves .queued/.running, riding Observation
/// change notifications (no polling). Used by the panel's preview/share
/// staging, upload-refresh, and the Upload sheet's paste-path handoff.
extension TransferItem {
    func awaitFinished() async {
        while true {
            switch phase {
            case .completed, .failed, .cancelled: return
            case .queued, .running:
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = phase
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
