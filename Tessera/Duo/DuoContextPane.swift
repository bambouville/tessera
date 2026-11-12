import Observation
import SwiftUI
import TesseraArtifactsCore

enum DuoContextSelection: Hashable {
    case automatic, tab(String), extra(String)
}

struct DuoContextExtra: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let content: () -> AnyView
}

@MainActor
struct DuoContextPane: View {
    @Environment(ArtifactsStore.self) private var store
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.designTokens) private var T
    @Environment(\.duoWorkspace) private var workspace
    @Environment(\.duoContextPageOwner) private var workspacePageOwner
    @Environment(\.openArtifact) private var openArtifact
    @Environment(\.duoContextSuspended) private var isSuspended
    @Environment(\.artifactSurfaceVisible) private var surfaceVisible
    @Environment(\.artifactPresentationObscured) private var presentationObscured
    @Binding private var selection: DuoContextSelection
    @State private var sheetState = ArtifactBrowserSheetState()
    @State private var localPageOwner = DuoContextPageOwner()
    @State private var pageOwnerID = UUID()
    @State private var visibilitySession = ArtifactVisibilitySession()
    @State private var sheetRequest = ArtifactAddressEditRequest.newTab(currentHostID: nil)
    /// Laptop pose's address, typed in place under the header.
    @State private var addressEdit: ArtifactAddressEntry?
    @State private var shareRequest: ArtifactFileShareRequest?
    /// Touching the pane gives it the browser's chords; touching anything
    /// else, the terminal beside it above all, takes them back.
    @State private var shortcutRelay = ArtifactsShortcutRelay()
    @State private var keyboardFocusID = UUID()
    private let hostID: UUID?
    private let extras: [DuoContextExtra]
    private let fallbackExtraID: String?

    init(hostID: UUID?, extras: [DuoContextExtra], fallbackExtraID: String?,
         selection: Binding<DuoContextSelection>) {
        self.hostID = hostID
        self.extras = extras
        self.fallbackExtraID = fallbackExtraID
        self._selection = selection
    }

    private var tabs: [ArtifactTab] { DuoContextPolicy.orderedTabs(hostID: hostID, tabs: store.state.tabs) }
    private var resolvedSelection: DuoContextSelection {
        DuoContextPolicy.resolvedSelection(selection, tabs: tabs, extraIDs: extras.map(\.id),
                                           fallbackExtraID: fallbackExtraID)
    }
    private var displayedTab: ArtifactTab? {
        guard case let .tab(id) = resolvedSelection else { return nil }
        return tabs.first { $0.id == id }
    }
    private var displayedExtra: DuoContextExtra? {
        guard case let .extra(id) = resolvedSelection else { return nil }
        return extras.first { $0.id == id }
    }
    private var slotVisible: Bool {
        !isSuspended && DuoContextPolicy.slotVisible(arrangement: workspace?.arrangement,
            isContextShown: workspace?.isContextShown ?? true, isSwapped: workspace?.isSwapped ?? false)
    }
    private var paneVisible: Bool {
        DuoContextPolicy.isVisible(surfaceVisible: surfaceVisible, slotVisible: slotVisible,
            isLocked: appLockController.isLocked, isObscured: presentationObscured,
            hasSheet: sheetState.presentedSheet != nil)
    }
    private var visibleTabID: String? { paneVisible ? displayedTab?.id : nil }
    private var pickerTitle: Text {
        if let tab = displayedTab { return Text(verbatim: tab.title) }
        if let extra = displayedExtra { return Text(extra.title) }
        return Text("context")
    }
    private var pageOwner: DuoContextPageOwner { workspacePageOwner ?? localPageOwner }
    private var pageSession: ArtifactPageSession { pageOwner.pageSession }
    private var pageIdentity: BrowserPageIdentity? { pageSession.pageIdentity(for: displayedTab, store: store) }
    private var presentedSheet: Binding<ArtifactBrowserSheet?> {
        Binding(get: { sheetState.visibleSheet(isLocked: appLockController.isLocked) },
                set: { sheetState.present($0, isLocked: appLockController.isLocked) })
    }
    private var addressInPlace: Bool {
        Self.entersAddressInPlace(arrangement: workspace?.arrangement)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let entry = addressEdit {
                ArtifactAddressEditor(editing: editing(entry), compact: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .artifactsChromeSurface()
            }
            ZStack(alignment: .top) {
                if !slotVisible {
                    // A hidden slot keeps its proposal without mounting the web
                    // view; the page owner keeps the page for its return.
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let tab = displayedTab {
                    ArtifactTabContentView(store: store, tab: tab,
                        webModel: pageSession.webModel(for: tab, store: store), onRefresh: refresh)
                        .id(tab.id)
                } else if let extra = displayedExtra {
                    extra.content()
                        .environment(\.artifactSurfaceVisible, paneVisible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
                if let entry = addressEdit { dropdown(entry) }
            }
        }
        .background(T.presentationBg)
        .background { shortcuts }
        .accessibilityIdentifier("duo-context-pane")
        .sheet(item: presentedSheet) { _ in
            if !appLockController.isLocked {
                ArtifactQuickOpenView(store: store, request: sheetRequest) { id in
                    sheetState.present(nil, isLocked: appLockController.isLocked)
                    reveal(id)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            pageOwner.adopt(pageOwnerID)
            updatePageSession()
            updateVisibility()
        }
        .onChange(of: appLockController.isLocked, initial: true) { _, locked in
            sheetState.lockChanged(isLocked: locked)
            // The lock covers SwiftUI, not a UIKit share sheet above it.
            if locked {
                shareRequest = nil
                endEditing()
            }
        }
        .onChange(of: hostID) { _, _ in
            sheetState.present(nil, isLocked: appLockController.isLocked)
            endEditing()
        }
        // An edit belongs to what the pane showed when it started.
        .onChange(of: resolvedSelection) { _, _ in endEditing() }
        .onChange(of: addressInPlace) { _, inPlace in
            if inPlace, sheetState.presentedSheet == .quickOpen {
                sheetState.present(nil, isLocked: appLockController.isLocked)
                enterAddress(sheetRequest)
            } else if !inPlace, let entry = addressEdit {
                enterAddress(entry.request)
            }
        }
        .onChange(of: visibleTabID, initial: true) { _, _ in updateVisibility() }
        .onChange(of: store.state.selectedID) { _, _ in updateVisibility(force: true) }
        .onChange(of: pageIdentity, initial: true) { _, _ in updatePageSession() }
        .onDisappear {
            endEditing()
            visibilitySession.release()
            pageOwner.release(pageOwnerID)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(tabs) { tab in
                    Button { pickTab(tab.id) } label: {
                        Label(tab.title, systemImage: resolvedSelection == .tab(tab.id)
                              ? "checkmark" : ArtifactsBrowserPresentation.kindSymbol(tab))
                    }
                    .accessibilityAddTraits(resolvedSelection == .tab(tab.id) ? .isSelected : [])
                    .accessibilityIdentifier("duo-context-tab-\(tab.id)")
                }
                Button("open…", systemImage: "plus", action: quickOpen)
                    .accessibilityIdentifier("duo-context-open")
                if let tab = displayedTab, store.shareableFile(for: tab.id) != .none {
                    let share = store.shareableFile(for: tab.id)
                    Button { shareFile(tab) } label: {
                        Label("share file", systemImage: "square.and.arrow.up")
                        if let reason = share.reason { Text(verbatim: reason) }
                    }
                    .disabled(!share.isReady)
                    .accessibilityIdentifier("duo-context-share-file")
                }
                if !extras.isEmpty {
                    Divider()
                    ForEach(extras) { extra in
                        Button { selection = .extra(extra.id) } label: {
                            Label(extra.title, systemImage: resolvedSelection == .extra(extra.id)
                                  ? "checkmark" : extra.systemImage)
                        }
                        .accessibilityAddTraits(resolvedSelection == .extra(extra.id) ? .isSelected : [])
                        .accessibilityIdentifier("duo-context-extra-\(extra.id)")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let tab = displayedTab {
                        Label(tab.title, systemImage: ArtifactsBrowserPresentation.kindSymbol(tab))
                    } else if let extra = displayedExtra {
                        Label(extra.title, systemImage: extra.systemImage)
                    } else {
                        Label("context", systemImage: "book")
                    }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("choose context")
            .accessibilityValue(pickerTitle)
            .accessibilityIdentifier("duo-context-picker")
            // The pane's per-tab action, so its sheet hangs off the picker.
            .systemShareSheet(item: $shareRequest) { [$0.fileURL] }
            if let workspace {
                Button("swap", systemImage: "arrow.left.arrow.right", action: workspace.swap)
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 28)
                    .windowTopTapTarget(workspace.swap)
                    .accessibilityIdentifier("duo-context-swap")
                if workspace.offersFullScreen {
                    Button(action: workspace.toggleFullScreen) {
                        Label(workspace.isFullScreen ? LocalizedStringKey("exit full screen") : LocalizedStringKey("full screen"),
                              systemImage: workspace.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 28)
                    .windowTopTapTarget(workspace.toggleFullScreen)
                    .accessibilityIdentifier("duo-context-fullscreen")
                }
            }
        }
        .buttonStyle(.plain)
        .font(Typography.tesseraMonoFixed(size: 10.5))
        .foregroundStyle(T.fgMuted)
        .frame(height: 28)
        .artifactsChromeSurface()
        .accessibilityIdentifier("duo-context-header")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book").font(.system(size: 28, weight: .light)).foregroundStyle(T.fgDim)
            Text("no context yet").font(Typography.tesseraMono(size: 13)).foregroundStyle(T.fgMuted)
            Button("open…", systemImage: "plus", action: quickOpen)
                .frame(minWidth: 60, minHeight: 44)
                .foregroundStyle(T.fg)
                .accessibilityIdentifier("duo-context-empty-open")
        }
        .font(Typography.tesseraMono(size: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("duo-context-empty")
    }

    private func pickTab(_ id: String) {
        guard !appLockController.isLocked,
              let picked = Self.pickTab(id, hostID: hostID, store: store) else { return }
        selection = picked
    }

    /// Shows a tab this pane made or reopened: here when it is on this
    /// pane's host, otherwise in the full browser, by its own ID, so an
    /// older tab on the same target does not answer instead.
    private func reveal(_ id: String) {
        guard !appLockController.isLocked else { return }
        if let picked = Self.pickTab(id, hostID: hostID, store: store) {
            selection = picked
        } else if let tab = store.tab(id), let request = DuoContextPolicy.quickOpenRequest(for: tab) {
            openArtifact?(request)
        }
    }

    /// The order ⌘⇧[ / ⌘⇧] and ⌘1–⌘9 walk: the strip's, filtered to this
    /// pane's host. The picker's most-recent-first order would move under
    /// each step, so "next" would only ever swap two tabs.
    nonisolated static func shortcutOrder(hostID: UUID?, tabs: [ArtifactTab]) -> [ArtifactTab] {
        guard let hostID else { return [] }
        return tabs.filter { UUID(uuidString: $0.hostID) == hostID }
    }

    static func pickTab(_ id: String, hostID: UUID?, store: any ArtifactsBrowserStore) -> DuoContextSelection? {
        guard DuoContextPolicy.orderedTabs(hostID: hostID, tabs: store.state.tabs).contains(where: { $0.id == id }) else {
            return nil
        }
        store.select(id)
        return .tab(id)
    }

    private func quickOpen() {
        enterAddress(.newTab(currentHostID: hostID?.uuidString))
    }

    /// Laptop pose: the panes stack across the fold, and the address is
    /// typed in place under the header. The desk trades up above the
    /// keyboard as the field takes it, so no sheet crosses the hinge. The
    /// rail and the iPad keep the address sheet.
    nonisolated static func entersAddressInPlace(arrangement: DuoPaneArrangement?) -> Bool {
        arrangement == .stacked
    }

    private func enterAddress(_ request: ArtifactAddressEditRequest) {
        endEditing()
        guard addressInPlace else {
            sheetRequest = request
            sheetState.present(.quickOpen, isLocked: appLockController.isLocked)
            return
        }
        guard !appLockController.isLocked else { return }
        addressEdit = ArtifactAddressEntry(request)
    }

    private func editing(_ entry: ArtifactAddressEntry) -> ArtifactAddressEditing {
        ArtifactAddressEditing(entry: entry, submit: {
            entry.submit(store, onOpened: { opened($0, from: entry) }, onKeep: { endEditing(entry.request.id) })
        }, cancel: { endEditing(entry.request.id) })
    }

    /// The rows over the pane's content end with the pane, however many
    /// there are, so none lies on the hinge.
    private func dropdown(_ entry: ArtifactAddressEntry) -> some View {
        ArtifactAddressDropdown(store: store, entry: entry, onPick: { suggestion in
            entry.submit(suggestion, store: store, onOpened: { opened($0, from: entry) },
                         onKeep: { endEditing(entry.request.id) })
        }, onCancel: { endEditing(entry.request.id) }, fillsSpace: true)
        // A minimum, or a taller list sizes the frame and nothing clips.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
    }

    private func opened(_ id: String, from entry: ArtifactAddressEntry) {
        endEditing(entry.request.id)
        reveal(id)
    }

    private func endEditing(_ requestID: UUID? = nil) {
        guard let entry = addressEdit, requestID == nil || entry.request.id == requestID else { return }
        entry.cancel()
        addressEdit = nil
    }

    private func shareFile(_ tab: ArtifactTab) {
        shareRequest = ArtifactShareStaging.request(for: store.shareableFile(for: tab.id))
    }

    // MARK: - The browser's chords, while this pane holds them

    /// An address typed in place covers nothing: the pane keeps its chords
    /// meanwhile, as the browser's toolbar field does.
    private var holdsKeyboard: Bool {
        paneVisible && sheetState.presentedSheet == nil && ArtifactsKeyboardFocus.shared.holds(keyboardFocusID)
    }

    /// The pane's own Quick Open sheet pauses its claim rather than ending
    /// it, so ⌘L then Esc leaves the browser's chords with the pane.
    private var shortcuts: some View {
        ArtifactsBrowserKeyboardScope(
            focusID: keyboardFocusID, relay: shortcutRelay, watches: paneShowsUnderItsSheet, claimsWhileActive: false,
            pausesTouches: sheetState.presentedSheet != nil,
            holdsKeyboard: holdsKeyboard, available: ArtifactsShortcutPolicy.available(shortcutContext), perform: perform
        )
    }

    private var paneShowsUnderItsSheet: Bool {
        DuoContextPolicy.isVisible(surfaceVisible: surfaceVisible, slotVisible: slotVisible,
            isLocked: appLockController.isLocked, isObscured: presentationObscured, hasSheet: false)
    }

    private var shortcutContext: ArtifactsShortcutContext {
        let tab = displayedTab
        let model = pageSession.webModel(for: tab, store: store)
        return ArtifactsShortcutContext(
            tabCount: tabs.count, hasDisplayedTab: tab != nil,
            canRefresh: tab.map { store.canRefreshOrReconnect($0.id) } ?? false,
            canGoBack: model?.canGoBack == true, canGoForward: model?.canGoForward == true,
            canReopen: store.canReopenClosedTab, showsPage: model != nil,
            canShareFile: tab.map { store.shareableFile(for: $0.id).isReady } ?? false,
            hasOverview: false
        )
    }

    private func perform(_ command: ArtifactsBrowserCommand) {
        guard !appLockController.isLocked else { return }
        let model = pageSession.webModel(for: displayedTab, store: store)
        switch command {
        case .newTab: quickOpen()
        case .editAddress:
            guard let tab = displayedTab else { return quickOpen() }
            enterAddress(.edit(tab, webURL: model?.url))
        case .reload: refresh()
        case .back: model?.goBack()
        case .forward: model?.goForward()
        case .closeTab:
            if let tab = displayedTab { store.close(tab.id) }
        case .reopenTab:
            if let id = store.reopenClosedTab() { reveal(id) }
        case .previousTab, .nextTab:
            if let id = ArtifactsBrowserPresentation.adjacentTabID(
                tabs: Self.shortcutOrder(hostID: hostID, tabs: store.state.tabs), selectedID: displayedTab?.id,
                offset: command == .previousTab ? -1 : 1
            ) { pickTab(id) }
        case let .selectTab(digit):
            if let id = ArtifactsBrowserPresentation.tabID(
                forDigit: digit, tabs: Self.shortcutOrder(hostID: hostID, tabs: store.state.tabs)
            ) { pickTab(id) }
        case .find: model?.presentFind()
        case .shareFile:
            if let tab = displayedTab { shareFile(tab) }
        case .overview: break
        }
    }
    private func refresh() { pageSession.refresh(displayedTab, store: store) }
    private func updatePageSession() {
        pageOwner.update(displayedTab, store: store, ownerID: pageOwnerID)
    }
    private func updateVisibility(force: Bool = false) {
        visibilitySession.update(visibleTabID, store: store, force: force)
    }
}

@MainActor @Observable
final class DuoFilesListing {
    static let maximumEntries = 1_000
    private(set) var entries: [RemoteFileEntry] = []
    private(set) var directory: String?
    private(set) var isOffline = true
    private(set) var isLoading = false
    private(set) var isTruncated = false
    private(set) var error: String?
    @ObservationIgnored private var generation = 0

    func load(directory: String?, bridge: (any FileBridging)?) async {
        generation &+= 1
        let request = generation
        entries = []
        self.directory = nil
        error = nil
        isLoading = false
        isTruncated = false
        isOffline = bridge?.state != .connected
        guard let bridge, bridge.state == .connected else { return }
        let path = directory.flatMap { $0.isEmpty ? nil : $0 } ?? bridge.homeDirectory ?? "/"
        self.directory = path
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let values = try await bridge.listDirectory(path)
            guard generation == request, !Task.isCancelled, bridge.state == .connected else { return }
            isTruncated = values.count > Self.maximumEntries
            entries = Array(values.prefix(Self.maximumEntries))
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            isOffline = bridge.state != .connected
            if !isOffline { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct DuoFilesContext: View {
    @Environment(FileBridgeRegistry.self) private var fileBridges
    @Environment(SessionRegistry.self) private var sessions: SessionRegistry?
    @Environment(\.openArtifact) private var openArtifact
    @Environment(\.designTokens) private var T
    @Environment(\.artifactSurfaceVisible) private var surfaceVisible
    @State private var listing = DuoFilesListing()
    @State private var browsedDirectory: String?
    @State private var refreshRevision = 0
    @State private var openingTask: Task<Void, Never>?
    let hostID: UUID
    let directory: String?
    var markedPaths: Set<String> = []
    /// The session's own Files panel, opened in this pane by a tap: the
    /// listing never connects by itself.
    var onOpenFiles: (() -> Void)?

    init(hostID: UUID, directory: String?, markedPaths: Set<String> = [], onOpenFiles: (() -> Void)? = nil) {
        self.hostID = hostID
        self.directory = directory
        self.markedPaths = markedPaths
        self.onOpenFiles = onOpenFiles
    }

    private var bridge: (any FileBridging)? {
        let keys = DuoContextPolicy.fileBridgeKeys(
            hostID: hostID,
            sessionKeys: (sessions?.activeSessions ?? []).map { FileBridgeKey(host: $0.session.terminalSession.host) },
            existingKeys: Array(fileBridges.bridges.keys)
        )
        let existing = keys.compactMap { fileBridges.bridges[$0] }
        return existing.first { $0.state == .connected } ?? existing.first
    }

    private struct Request: Equatable {
        let hostID: UUID
        let directory: String?
        let bridgeID: ObjectIdentifier?
        let connected: Bool
        let visible: Bool
        let refreshRevision: Int
    }

    private var request: Request {
        Request(hostID: hostID, directory: browsedDirectory ?? directory,
                bridgeID: bridge.map(ObjectIdentifier.init), connected: bridge?.state == .connected,
                visible: surfaceVisible, refreshRevision: refreshRevision)
    }

    var body: some View {
        Group {
            if bridge?.state != .connected || listing.isOffline {
                VStack(spacing: 12) {
                    message("files offline", symbol: "folder.badge.questionmark")
                        .accessibilityIdentifier("duo-files-offline")
                    if case .failed(let reason) = bridge?.state {
                        Text(verbatim: reason)
                            .multilineTextAlignment(.center)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .padding(.horizontal, 16)
                            .accessibilityIdentifier("duo-files-failure")
                    }
                    if bridge?.state == .connecting {
                        ProgressView().tint(T.fgDim).frame(minHeight: 44)
                    } else if let onOpenFiles {
                        Button("open files", systemImage: "folder", action: onOpenFiles)
                            .buttonStyle(.plain)
                            .font(Typography.tesseraMono(size: 12))
                            .foregroundStyle(T.fg)
                            .frame(minWidth: 60, minHeight: 44)
                            .accessibilityIdentifier("duo-files-open")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = listing.error {
                VStack(spacing: 12) {
                    Text(verbatim: error).multilineTextAlignment(.center)
                    Button("retry", systemImage: "arrow.clockwise") { refreshRevision &+= 1 }
                    .frame(minWidth: 60, minHeight: 44)
                }
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileList
            }
        }
        .background(T.presentationBg)
        .accessibilityIdentifier("duo-files-context")
        // The task lists the request it was started for, not a later one.
        .task(id: request) { [request] in
            await listing.load(directory: request.directory, bridge: request.visible ? bridge : nil)
        }
        .onChange(of: hostID) { _, _ in resetNavigation() }
        .onChange(of: directory) { _, _ in resetNavigation() }
        .onChange(of: request) { _, _ in openingTask?.cancel(); openingTask = nil }
        .onDisappear { openingTask?.cancel(); openingTask = nil }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let directory = listing.directory {
                    Text(verbatim: directory)
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(2)
                        .padding(12)
                    if let parent = DuoContextPolicy.parentDirectory(directory) {
                        Button { browsedDirectory = parent } label: {
                            Label("up", systemImage: "chevron.left")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 12)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("duo-files-up")
                    }
                }
                if listing.isLoading {
                    ProgressView().tint(T.fgDim).frame(maxWidth: .infinity, minHeight: 44)
                } else if listing.entries.isEmpty {
                    Text("empty directory").foregroundStyle(T.fgDim).padding(12)
                }
                ForEach(listing.entries) { entry in
                    Button { open(entry) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.kind == .directory ? "folder" : "doc")
                                .frame(width: 16)
                            Text(verbatim: entry.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            if markedPaths.contains(entry.path) {
                                Text(verbatim: "●").font(.system(size: 7)).accessibilityLabel("edited")
                            }
                            if entry.kind == .directory {
                                Image(systemName: "chevron.right").font(.system(size: 9))
                            }
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .disabled(entry.kind == .other)
                    .accessibilityIdentifier("duo-files-entry-\(entry.path)")
                }
                if listing.isTruncated {
                    Text("showing the first \(DuoFilesListing.maximumEntries) entries")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .padding(12)
                }
            }
        }
        .buttonStyle(.plain)
        .font(Typography.tesseraMono(size: 11))
        .foregroundStyle(T.fgMuted)
    }

    private func message(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(Typography.tesseraMono(size: 12))
            .foregroundStyle(T.fgDim)
            .frame(maxWidth: .infinity)
    }

    private func resetNavigation() {
        openingTask?.cancel()
        openingTask = nil
        browsedDirectory = nil
    }

    private func open(_ entry: RemoteFileEntry) {
        guard let bridge, bridge.state == .connected else { return }
        if entry.kind == .directory { browsedDirectory = entry.path; return }
        if entry.kind == .file { openFile(entry.path); return }
        guard entry.kind == .symlink else { return }
        let current = request
        openingTask?.cancel()
        openingTask = Task { @MainActor in
            guard let target = try? await bridge.attributes(entry.path), !Task.isCancelled,
                  request == current, bridge.state == .connected else { return }
            if target.kind == .directory { browsedDirectory = entry.path }
            else if target.kind == .file { openFile(entry.path) }
        }
    }

    private func openFile(_ path: String) {
        openArtifact?(.init(hostID: hostID, target: .file(path: path), origin: .files))
    }
}
