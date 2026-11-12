import SwiftUI
import TesseraArtifactsCore

enum ArtifactBrowserSheet: String, Identifiable, CaseIterable {
    case quickOpen, switcher
    var id: String { rawValue }
}

struct ArtifactBrowserSheetState {
    private(set) var presentedSheet: ArtifactBrowserSheet?

    func visibleSheet(isLocked: Bool) -> ArtifactBrowserSheet? { isLocked ? nil : presentedSheet }

    mutating func present(_ sheet: ArtifactBrowserSheet?, isLocked: Bool) {
        presentedSheet = isLocked ? nil : sheet
    }

    mutating func lockChanged(isLocked: Bool) {
        if isLocked { presentedSheet = nil }
    }
}

@MainActor
struct ArtifactsRootView: View {
    @Environment(ArtifactsStore.self) private var store
    @Environment(\.designTokens) private var T

    init() {}

    var body: some View {
        ArtifactsBrowserView(store: store)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg.ignoresSafeArea())
        // A container, so the page's identifier does not replace its
        // controls' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifacts-page")
    }
}

@MainActor
struct ArtifactsBrowserView: View {
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.duoRailMode) private var railMode
    @Environment(\.duoOpenSwitcher) private var openSwitcher
    @Environment(\.artifactSurfaceVisible) private var surfaceVisible
    @Environment(\.artifactPresentationObscured) private var presentationObscured
    @State private var phonePath: [String] = []
    @State private var sheetState = ArtifactBrowserSheetState()
    @State private var pageSession = ArtifactPageSession()
    @State private var visibilitySession = ArtifactVisibilitySession()
    @State private var didPresentInitialSheet = false
    /// Duo's settled fold, in this browser's coordinates.
    @State private var fold: DuoFold?
    /// The address being edited in place: the toolbar's field, or a phone
    /// tab's address bar.
    @State private var addressEdit: ArtifactAddressEntry?
    /// The tab shown when that edit began, nil over the overview.
    @State private var addressEditTabID: String?
    /// What the address sheet opens with, on a phone.
    @State private var sheetRequest = ArtifactAddressEditRequest.newTab(currentHostID: nil)
    @State private var shareRequest: ArtifactFileShareRequest?
    @State private var shortcutRelay = ArtifactsShortcutRelay()
    @State private var keyboardFocusID = UUID()
    let store: any ArtifactsBrowserStore
    var startsInQuickOpen = false
    var startsInSwitcher = false
    /// A host-free harness lays the laptop pose out without a hinge.
    var foldOverride: DuoFold?

    private var compact: Bool { CompactLayout.isPhone(sizeClass) }
    private var currentFold: DuoFold? { foldOverride ?? fold }
    /// Laptop pose stands the open tab, or with none the title and its open
    /// field, in the upper half, with the overview on the desk below it.
    private var splitsAtTheFold: Bool {
        compact && ArtifactsBrowserPresentation.splitsAtTheFold(currentFold, railMode: railMode)
    }
    private var presentsSheets: Bool {
        ArtifactsBrowserPresentation.presentsSheets(compact: compact, splitsAtTheFold: splitsAtTheFold)
    }
    private var isOverview: Bool { compact ? phonePath.isEmpty : Self.showsOverview(store) }
    private var displayedTab: ArtifactTab? {
        guard !isOverview else { return nil }
        if compact { return phonePath.last.flatMap { store.tab($0) } }
        return store.selectedTab
    }
    private var visibleTabID: String? {
        surfaceVisible && !presentationObscured && !appLockController.isLocked
            && sheetState.presentedSheet == nil ? displayedTab?.id : nil
    }
    /// The browser's chords are live while it is on screen and nothing
    /// covers it. The address sheet handles its own keys.
    private var holdsKeyboard: Bool {
        surfaceVisible && !presentationObscured && !appLockController.isLocked && sheetState.presentedSheet == nil
    }
    private var presentedSheet: Binding<ArtifactBrowserSheet?> {
        Binding(get: { sheetState.visibleSheet(isLocked: appLockController.isLocked) },
                set: { sheetState.present($0, isLocked: appLockController.isLocked) })
    }
    private var webModel: ArtifactWebViewModel? {
        pageSession.webModel(for: displayedTab, store: store)
    }
    private var currentHostID: String? { displayedTab?.hostID ?? store.selectedTab?.hostID }
    private var regularControls: Set<ArtifactsChromeControl> {
        ArtifactsChromePolicy.controls(.regular, showsOverview: isOverview, hasTabs: !store.state.tabs.isEmpty)
    }

    var body: some View {
        Group {
            if compact { compactBrowser }
            else { regularBrowser }
        }
        .background {
            // Read against the keyboard-free frame: typing in the tab on top
            // ends the browser at the fold's top, and the split must hold.
            Color.clear
                .ignoresSafeArea(.keyboard)
                .onDuoFoldChange { next in
                    if fold != next { fold = next }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background { shortcuts }
        .background(T.presentationBg)
        // Safe areas remain active in both orientations. Page forms, the
        // overview search and Quick Open all resize above the keyboard.
        .sheet(item: presentedSheet) { sheet in
            if !appLockController.isLocked {
                sheetContent(sheet)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onAppear(perform: appeared)
        .onChange(of: appLockController.isLocked, initial: true) { _, isLocked in
            sheetState.lockChanged(isLocked: isLocked)
            if isLocked {
                endEditing()
                // The lock covers SwiftUI, not a UIKit share sheet above it.
                shareRequest = nil
            }
        }
        .onChange(of: store.state.selectedID) { old, new in selectionChanged(old: old, new: new) }
        // An open or select elsewhere reveals the selected tab. A tab merely
        // becoming visible, as in the Duo context, leaves the route alone.
        .onChange(of: store.showsBrowserOverview) { _, overview in
            guard compact else { return }
            if overview { phonePath = [] }
            else if phonePath.isEmpty { phonePath = Self.phonePath(store) }
        }
        .onChange(of: phonePath) { _, path in
            if compact, store.showsBrowserOverview != path.isEmpty { store.showsBrowserOverview = path.isEmpty }
        }
        .onChange(of: compact) { _, isCompact in
            endEditing()
            if isCompact { phonePath = Self.phonePath(store) }
        }
        .onChange(of: splitsAtTheFold) { _, splits in splitChanged(splits) }
        // An edit belongs to the tab, or the overview, it started on, even
        // when it started as that tab was revealed.
        .onChange(of: displayedTab?.id) { _, shown in
            if shown != addressEditTabID { endEditing() }
        }
        .onChange(of: visibleTabID, initial: true) { _, _ in updateVisibility() }
        .onChange(of: store.state.selectedID) { _, _ in updateVisibility(force: true) }
        .onChange(of: pageIdentity, initial: true) { _, _ in updatePageSession() }
        .onDisappear {
            endEditing()
            visibilitySession.release()
            pageSession.end()
        }
    }

    /// The browser's chords: hidden buttons while it holds the keyboard,
    /// and a claim a terminal beside it relays them to.
    private var shortcuts: some View {
        ArtifactsBrowserKeyboardScope(
            focusID: keyboardFocusID, relay: shortcutRelay, watches: holdsKeyboard, holdsKeyboard: holdsKeyboard,
            available: ArtifactsShortcutPolicy.available(shortcutContext), perform: perform
        )
    }

    private var shortcutContext: ArtifactsShortcutContext {
        let tab = displayedTab
        return ArtifactsShortcutContext(
            tabCount: store.state.tabs.count, hasDisplayedTab: tab != nil,
            canRefresh: tab.map { store.canRefreshOrReconnect($0.id) } ?? false,
            canGoBack: webModel?.canGoBack == true, canGoForward: webModel?.canGoForward == true,
            canReopen: store.canReopenClosedTab, showsPage: webModel != nil,
            canShareFile: tab.map { store.shareableFile(for: $0.id).isReady } ?? false
        )
    }

    @ViewBuilder
    private var compactBrowser: some View {
        if splitsAtTheFold {
            // The route stays in `phonePath`: a desk row puts its tab on top,
            // and back or a closed last tab brings the title back.
            ArtifactsFoldLayout(fold: currentFold) {
                if let tab = displayedTab { compactTab(tab) } else { foldTitle }
                ArtifactsOverviewView(store: store, compact: true, onDesk: true, tabOnTop: displayedTab?.id,
                                      onSelect: reveal, onQuickOpen: newTab)
            }
            // The keyboard rises from the fold. The tab, its page forms and
            // the open field are above it already; the overview waits under
            // it unsqueezed.
            .ignoresSafeArea(.keyboard)
        } else {
            phoneStack
        }
    }

    /// Laptop pose with no tab on top: the section's title, its ⌄ and the
    /// open field above the fold, where the field's rows end too.
    private var foldTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                DuoTitleSwitcher(identifier: "artifacts-title-switcher") {
                    Text("artifacts")
                        .font(Typography.pageTitle)
                        .foregroundStyle(T.fg)
                }
                if let entry = addressEdit {
                    ArtifactAddressEditor(editing: editing(entry), compact: true)
                } else {
                    ArtifactsOpenByPathButton(identifier: "artifacts-fold-open", action: newTab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // With no tabs the desk says so.
            ZStack(alignment: .top) {
                if let entry = addressEdit { foldDropdown(entry) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(T.presentationBg)
    }

    private var phoneStack: some View {
        // A missing tab's page has no + of its own beside the rail's.
        let emptyNewTab: (() -> Void)? = railMode ? nil : { newTab() }
        return NavigationStack(path: $phonePath) {
            ArtifactsOverviewView(store: store, compact: true,
                                  offersNewTab: ArtifactsChromePolicy.overviewHeaderOffersNewTab(
                                      regular: false, railMode: railMode, onDesk: false),
                                  onSelect: reveal, onQuickOpen: newTab)
                .modifier(ArtifactsRailChrome(isEnabled: railMode))
                .toolbar { if railMode { railItems } }
                .navigationDestination(for: String.self) { id in
                    if let tab = store.tab(id) {
                        compactTab(tab)
                            .modifier(ArtifactsRailChrome(isEnabled: railMode))
                            .toolbar { if railMode { railItems } }
                    } else {
                        ArtifactsEmptyState(onQuickOpen: emptyNewTab)
                            .modifier(ArtifactsRailChrome(isEnabled: railMode))
                            .toolbar { if railMode { railItems } }
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var railItems: some ToolbarContent {
        if let openSwitcher {
            ToolbarItem(placement: .cancellationAction) {
                Button("switcher", systemImage: "chevron.down") { openSwitcher() }
                    .accessibilityIdentifier("duo-artifacts-switcher")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("new tab", systemImage: "plus", action: newTab)
                .accessibilityIdentifier("duo-artifacts-open")
        }
        if let tab = displayedTab {
            ToolbarItem(placement: .primaryAction) {
                Button("reload", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(!store.canRefreshOrReconnect(tab.id))
                    .accessibilityIdentifier("duo-artifacts-reload")
            }
        }
    }

    private var regularBrowser: some View {
        VStack(spacing: 0) {
            ArtifactAddressBar(store: store, tab: displayedTab, webModel: webModel, showsOverview: isOverview,
                               editing: addressEdit.map(editing), onEditAddress: editAddress, onNewTab: newTab,
                               onOverview: toggleOverview, onRefresh: refresh, shareRequest: $shareRequest)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if regularControls.contains(.tabStrip) {
                        ArtifactTabStrip(store: store, onSelect: reveal)
                    }
                    regularContent
                }
                if let entry = addressEdit { dropdown(entry) }
            }
        }
    }

    @ViewBuilder
    private var regularContent: some View {
        if let tab = displayedTab {
            ArtifactTabContentView(store: store, tab: tab, webModel: webModel, onRefresh: refresh)
                .id(ArtifactsBrowserPresentation.contentIdentity(tab))
        } else if store.state.tabs.isEmpty {
            ArtifactsEmptyState(onQuickOpen: nil)
        } else {
            ArtifactsOverviewView(store: store, offersNewTab: false, onSelect: reveal, onQuickOpen: newTab)
        }
    }

    private func compactTab(_ tab: ArtifactTab) -> some View {
        let model = displayedTab?.id == tab.id ? webModel : nil
        let splits = splitsAtTheFold
        let entry = addressEdit.flatMap {
            ArtifactsBrowserPresentation.tabBarShowsEdit($0.request.placement, tabID: tab.id, splitsAtTheFold: splits) ? $0 : nil
        }
        return VStack(spacing: 0) {
            ArtifactAddressBar(store: store, tab: tab, webModel: model, compact: true,
                               editing: entry.map(editing), onEditAddress: { edit(tab, webURL: model?.url) },
                               onBackToOverview: { endEditing(); phonePath = [] }, onRefresh: refresh)
            ZStack(alignment: .top) {
                ArtifactTabContentView(store: store, tab: tab, webModel: model, onRefresh: refresh)
                    .id(ArtifactsBrowserPresentation.contentIdentity(tab))
                if let entry {
                    if splits { foldDropdown(entry) } else { dropdown(entry) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { compactToolbar(tab) }
        .background(T.presentationBg)
    }

    private func compactToolbar(_ tab: ArtifactTab) -> some View {
        HStack(spacing: 0) {
            ArtifactPageHistoryButtons(model: webModel)
            Spacer(minLength: 0)
            ArtifactRefreshButton(enabled: store.canRefreshOrReconnect(tab.id), action: refresh)
            Spacer(minLength: 0)
            ArtifactTabNavigationButtons(store: store, onSelect: reveal)
            Spacer(minLength: 0)
            // Laptop pose has the overview on the desk below, not in a sheet.
            if presentsSheets {
                ArtifactChromeButton(symbol: "square.grid.2x2", label: "tab switcher") { present(.switcher) }
                    .accessibilityIdentifier("artifacts-show-overview")
            }
            ArtifactTabMenu(store: store, tab: tab, currentPageURL: webModel?.url, shareRequest: $shareRequest)
        }
        .frame(maxWidth: .infinity)
        .artifactsChromeSurface()
    }

    private func dropdown(_ entry: ArtifactAddressEntry, fillsSpace: Bool = false) -> some View {
        ArtifactAddressDropdown(store: store, entry: entry, onPick: { suggestion in
            entry.submit(suggestion, store: store, onOpened: { opened($0, from: entry) },
                         onKeep: { endEditing(entry.request.id) })
        }, onCancel: { endEditing(entry.request.id) }, fillsSpace: fillsSpace)
    }

    /// Laptop pose: the rows end where the space above the fold does,
    /// however many there are, so none lies on the hinge.
    private func foldDropdown(_ entry: ArtifactAddressEntry) -> some View {
        dropdown(entry, fillsSpace: true)
            // A minimum, or a taller list sizes the frame and nothing clips.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            .contentShape(Rectangle())
    }

    private func editing(_ entry: ArtifactAddressEntry) -> ArtifactAddressEditing {
        ArtifactAddressEditing(entry: entry, submit: {
            entry.submit(store, onOpened: { opened($0, from: entry) }, onKeep: { endEditing(entry.request.id) })
        }, cancel: { endEditing(entry.request.id) })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ArtifactBrowserSheet) -> some View {
        switch sheet {
        case .quickOpen:
            ArtifactQuickOpenView(store: store, request: sheetRequest) { id in
                present(nil)
                reveal(id)
            }
        case .switcher:
            ArtifactsOverviewView(store: store, compact: true, usesGrid: true, onSelect: { id in
                present(nil)
                reveal(id)
            }, onQuickOpen: newTab, onDismiss: { present(nil) })
                .presentationBackground(T.presentationBg)
        }
    }

    // MARK: - Commands

    private func perform(_ command: ArtifactsBrowserCommand) {
        guard !appLockController.isLocked else { return }
        switch command {
        case .newTab: newTab()
        case .editAddress: editAddress()
        case .reload: refresh()
        case .back: webModel?.goBack()
        case .forward: webModel?.goForward()
        case .closeTab:
            guard let tab = displayedTab else { return }
            endEditing()
            store.close(tab.id)
        case .reopenTab:
            if let id = store.reopenClosedTab() { reveal(id) }
        case .previousTab: step(-1)
        case .nextTab: step(1)
        case let .selectTab(digit):
            if let id = ArtifactsBrowserPresentation.tabID(forDigit: digit, tabs: store.state.tabs) { reveal(id) }
        case .overview: toggleOverview()
        case .find: webModel?.presentFind()
        case .shareFile:
            guard let tab = displayedTab else { return }
            shareRequest = ArtifactShareStaging.request(for: store.shareableFile(for: tab.id))
        }
    }

    /// ⌘T and +: an empty field that opens a new tab, in the toolbar or,
    /// on a phone, in the address sheet. Laptop pose types it in place above
    /// the fold: in the tab's bar, or under the title.
    private func newTab() {
        guard !appLockController.isLocked else { return }
        endEditing()
        let request = ArtifactAddressEditRequest.newTab(currentHostID: currentHostID)
        if presentsSheets {
            sheetRequest = request
            present(.quickOpen)
        } else {
            addressEdit = ArtifactAddressEntry(request)
            addressEditTabID = displayedTab?.id
        }
    }

    /// ⌘L and a tap on the address: the tab's address, all selected; the
    /// overview's open field when no tab shows.
    private func editAddress() {
        if let tab = displayedTab { edit(tab, webURL: webModel?.url) }
        else { newTab() }
    }

    private func edit(_ tab: ArtifactTab, webURL: URL?) {
        guard !appLockController.isLocked else { return }
        endEditing()
        addressEdit = ArtifactAddressEntry(.edit(tab, webURL: webURL))
        addressEditTabID = displayedTab?.id
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

    private func step(_ offset: Int) {
        if let id = ArtifactsBrowserPresentation.adjacentTabID(
            tabs: store.state.tabs, selectedID: displayedTab?.id ?? store.state.selectedID, offset: offset
        ) { reveal(id) }
    }

    /// The one overview control: the overview, and back to the tab from it.
    /// In laptop pose the overview lies on the desk already: the tab on top
    /// gives way to the title, as ‹ does.
    private func toggleOverview() {
        if displayedTab != nil {
            if presentsSheets { present(.switcher) } else { overview() }
        } else if let selected = store.selectedTab {
            reveal(selected.id)
        }
    }

    private func appeared() {
        // The store holds the route: a rebuilt or reappearing browser
        // shows the overview or the tab the user left.
        if compact, phonePath.isEmpty { phonePath = Self.phonePath(store) }
        updateVisibility()
        updatePageSession()
        if !didPresentInitialSheet {
            didPresentInitialSheet = true
            if startsInQuickOpen { newTab() }
            else if startsInSwitcher, presentsSheets { present(.switcher) }
        }
    }

    /// Laptop pose has no sheets: folding into it closes the switcher, whose
    /// overview is on the desk, and moves Quick Open's field above the fold.
    /// Leaving it moves the same new-tab draft back into the phone's sheet.
    private func splitChanged(_ splits: Bool) {
        if splits {
            let sheet = sheetState.presentedSheet
            present(nil)
            if sheet == .quickOpen {
                endEditing()
                addressEdit = ArtifactAddressEntry(sheetRequest)
                addressEditTabID = displayedTab?.id
            }
        } else if compact, let entry = addressEdit, entry.request.placement == .newTab {
            sheetRequest = entry.request
            endEditing()
            present(.quickOpen)
        }
    }

    private func reveal(_ id: String) {
        guard !appLockController.isLocked, store.tab(id) != nil else { return }
        if store.state.selectedID != id { store.select(id) }
        store.showsBrowserOverview = false
        if compact { phonePath = [id] }
    }

    private func overview() {
        store.showsBrowserOverview = true
        if compact { phonePath = [] }
    }

    private func present(_ sheet: ArtifactBrowserSheet?) {
        sheetState.present(sheet, isLocked: appLockController.isLocked)
    }

    private func selectionChanged(old: String?, new: String?) {
        guard let id = new else {
            phonePath = []
            store.showsBrowserOverview = true
            return
        }
        // Closing the selected tab from the overview keeps the overview in
        // place. An explicit select/open of an existing tab reveals it
        // through the store's route.
        let previousWasClosed = old.map { store.tab($0) == nil } ?? false
        if compact {
            if !phonePath.isEmpty || !previousWasClosed { phonePath = [id] }
        } else if !previousWasClosed { store.showsBrowserOverview = false }
    }

    /// The phone stack a browser starts from: the overview, or the selected
    /// tab unless the user left the browser on its overview.
    static func phonePath(_ store: any ArtifactsBrowserStore) -> [String] {
        store.showsBrowserOverview ? [] : store.selectedTab.map { [$0.id] } ?? []
    }

    static func showsOverview(_ store: any ArtifactsBrowserStore) -> Bool {
        store.showsBrowserOverview || store.selectedTab == nil
    }

    private func refresh() {
        pageSession.refresh(displayedTab, store: store)
    }

    private var pageIdentity: BrowserPageIdentity? {
        pageSession.pageIdentity(for: displayedTab, store: store)
    }

    private func updatePageSession() {
        pageSession.updatePageSession(for: displayedTab, store: store)
    }

    private func updateVisibility(force: Bool = false) {
        visibilitySession.update(visibleTabID, store: store, priority: 1, force: force)
    }
}

/// Laptop pose: the open tab, or the title and its open field, stands in the
/// upper half and the overview lies on the desk below the fold, at the sizes
/// the fold gives them.
struct ArtifactsFoldLayout: Layout {
    var fold: DuoFold?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let split = DuoPaneGeometry.deckSplit(container: bounds.size, fold: fold) ?? (
            content: CGRect(origin: .zero, size: bounds.size),
            deck: CGRect(x: 0, y: bounds.height, width: bounds.width, height: 0)
        )
        for (subview, frame) in zip(subviews, [split.content, split.deck]) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size)
            )
        }
    }
}

struct ArtifactsRailChrome: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isEnabled)
            .toolbar(isEnabled ? .visible : .hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(isEnabled ? .hidden : .automatic, for: .navigationBar)
            .ignoresSafeArea(.container, edges: isEnabled ? .top : [])
    }
}
