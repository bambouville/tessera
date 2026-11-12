import SwiftUI
import TesseraArtifactsCore

@MainActor
struct ArtifactsOverviewView: View {
    @Environment(AppLockController.self) private var appLockController
    @Environment(\.designTokens) private var T
    @State private var query = ""
    @State private var overviewID = UUID()
    @State private var isVisible = false
    let store: any ArtifactsBrowserStore
    var compact = false
    /// On the laptop's desk, where no field may wait under the keyboard.
    /// Under an open tab, open-by-path takes the title's and the search
    /// field's place, and that tab is marked; with no tab on top, the title
    /// and the open field stand above the fold instead.
    var onDesk = false
    /// The tab open above the desk's overview.
    var tabOnTop: String?
    var usesGrid = false
    /// Whether the header carries the browser's one +: only where no
    /// toolbar does (`ArtifactsChromePolicy`).
    var offersNewTab = true
    let onSelect: (String) -> Void
    let onQuickOpen: () -> Void
    var onDismiss: (() -> Void)?

    private var overview: ArtifactsOverview { store.overview(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Search and zero counts say nothing before the first tab.
            if !store.state.tabs.isEmpty { filters }
            if store.state.tabs.isEmpty {
                ArtifactsEmptyState(onQuickOpen: nil)
            } else if overview.groups.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 24, weight: .light))
                        Text("no matching tabs")
                            .font(Typography.tesseraMono(size: 14))
                        Text("try another filter or search")
                            .font(Typography.tesseraMono(size: 11))
                    }
                    .foregroundStyle(T.fgMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            } else {
                groups
            }
        }
        .background(T.presentationBg)
        .accessibilityIdentifier("artifacts-overview")
        .onAppear {
            isVisible = true
            store.noteOverviewVisible(overviewID, !appLockController.isLocked)
        }
        .onDisappear {
            isVisible = false
            store.noteOverviewVisible(overviewID, false)
        }
        .onChange(of: appLockController.isLocked) { _, locked in
            store.noteOverviewVisible(overviewID, isVisible && !locked)
        }
    }

    @ViewBuilder
    private var header: some View {
        if onDesk {
            if tabOnTop != nil {
                ArtifactsOpenByPathButton(identifier: "artifacts-desk-open", action: onQuickOpen)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
        } else {
            titleAndSearch
        }
    }

    private var titleAndSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                // Not in the tab switcher's sheet, which has its own done.
                DuoTitleSwitcher(identifier: "artifacts-title-switcher", isEnabled: onDismiss == nil) {
                    Text("artifacts")
                        .font(Typography.pageTitle)
                        .foregroundStyle(T.fg)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if offersNewTab {
                    ArtifactChromeButton(symbol: "plus", label: "new tab", action: onQuickOpen)
                        .accessibilityIdentifier("artifacts-new-tab")
                }
                if let onDismiss {
                    Button("done", action: onDismiss)
                        .font(Typography.tesseraMono(size: 12, weight: .medium))
                        .foregroundStyle(T.fg)
                        .frame(minWidth: 44, minHeight: 44)
                        .keyboardShortcut(.cancelAction)
                }
            }
            if !store.state.tabs.isEmpty { search }
        }
        .padding(.horizontal, compact ? 16 : 24)
        .padding(.top, 12)
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(T.fgDim)
            TextField("search tabs", text: $query)
                .font(Typography.tesseraMono(size: 12))
                .foregroundStyle(T.fg)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("artifacts-search")
            if !query.isEmpty {
                ArtifactChromeButton(symbol: "xmark", label: "clear search") { query = "" }
            }
        }
        .padding(.leading, 12)
        .frame(minHeight: 44)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ArtifactsFilter.allCases, id: \.rawValue) { filter in
                    Button { store.setFilter(filter) } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: ArtifactsBrowserPresentation.filterTitle(filter))
                            Text(verbatim: "\(ArtifactsBrowserPresentation.count(filter, in: overview))")
                                .foregroundStyle(T.fgDim)
                        }
                        .font(Typography.tesseraMono(size: 11))
                        .foregroundStyle(T.fg)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(store.state.filter == filter ? T.inputBg : T.inputBgSoft,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(store.state.filter == filter ? T.borderStrong : T.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("artifacts-filter-\(filter.rawValue)")
                    .accessibilityAddTraits(store.state.filter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.vertical, 12)
        }
    }

    private var groups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(overview.groups, id: \.hostID) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        groupHeader(group)
                        if usesGrid || !compact {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 150 : 230), spacing: 12, alignment: .top)], spacing: 12) {
                                ForEach(group.tabIDs, id: \.self) { id in
                                    if let tab = store.tab(id) { card(tab, grid: true) }
                                }
                            }
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(group.tabIDs, id: \.self) { id in
                                    if let tab = store.tab(id) { card(tab, grid: false) }
                                }
                            }
                            .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 9))
                            // The marked row's fill keeps to the rounded group.
                            .clipShape(RoundedRectangle(cornerRadius: onDesk ? 9 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(T.border, lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func groupHeader(_ group: ArtifactsHostGroup) -> some View {
        HStack(spacing: 6) {
            Circle().fill(store.isLive(hostID: group.hostID) ? T.fgMuted : T.fgFaint)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(verbatim: group.hostLabel)
                .font(Typography.tesseraMono(size: 12, weight: .medium))
                .foregroundStyle(T.fg)
            Text(verbatim: store.isLive(hostID: group.hostID) ? String(localized: "live") : String(localized: "offline"))
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
            Spacer(minLength: 0)
            Button("close all") { store.closeAll(hostID: group.hostID) }
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgMuted)
                .frame(minWidth: 60, minHeight: 44)
                .accessibilityLabel("close all on \(group.hostLabel)")
        }
    }

    private func card(_ tab: ArtifactTab, grid: Bool) -> some View {
        ArtifactOverviewCard(store: store, tab: tab, grid: grid,
                             isOnTop: onDesk && tabOnTop == tab.id) { onSelect(tab.id) }
            .contextMenu { ArtifactTabMenuActions(store: store, tab: tab) }
    }
}

/// Laptop pose's open field before it opens: on the desk under a tab, or
/// under the title with none. Either types in place above the fold, in the
/// tab's bar or here under the title, never on the desk under the keyboard.
struct ArtifactsOpenByPathButton: View {
    @Environment(\.designTokens) private var T
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(T.fgDim)
                Text("host:path or a port")
                    .font(Typography.tesseraMono(size: 12))
                    .foregroundStyle(T.fgDim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("new tab")
        .accessibilityHint("open a path or a port in a new tab")
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private struct ArtifactOverviewCard: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let tab: ArtifactTab
    let grid: Bool
    /// The tab open above the desk's overview.
    var isOnTop = false
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 8) {
                    if grid { preview }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: ArtifactsBrowserPresentation.kindSymbol(tab))
                            .font(.system(size: 13))
                            .foregroundStyle(T.fgMuted)
                        Text(verbatim: tab.title)
                            .font(Typography.tesseraMono(size: 12, weight: .medium))
                            .foregroundStyle(T.fg)
                            .lineLimit(2, reservesSpace: grid)
                        if tab.unseenChange {
                            Circle().fill(T.fg).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0.height + 1 }
                                .accessibilityLabel("unseen change")
                        }
                        if tab.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9))
                                .foregroundStyle(T.fgDim).accessibilityLabel("pinned")
                        }
                    }
                    Text(verbatim: ArtifactsBrowserPresentation.location(tab))
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Grid cards reserve every optional line, so a row's
                    // cards share one height.
                    ZStack(alignment: .leading) {
                        if grid { Text(verbatim: " ").font(Typography.tesseraMono(size: 10)).hidden() }
                        ArtifactCacheBadge(presentation: store.presentation(for: tab.id))
                    }
                    if let origin = ArtifactsBrowserPresentation.openedFrom(tab) {
                        Text(verbatim: origin)
                            .font(Typography.tesseraMono(size: 9))
                            .foregroundStyle(T.fgDim)
                            .lineLimit(2, reservesSpace: grid)
                    } else if grid {
                        Text(verbatim: " ")
                            .font(Typography.tesseraMono(size: 9))
                            .lineLimit(2, reservesSpace: true)
                            .hidden()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("artifacts-tab-\(tab.id)")
            .accessibilityAddTraits(store.state.selectedID == tab.id ? .isSelected : [])
            ArtifactChromeButton(symbol: "xmark", label: "close \(tab.title)") { store.close(tab.id) }
                .accessibilityIdentifier("artifacts-close-\(tab.id)")
        }
        .background(grid ? T.inputBgSoft : isOnTop ? T.inputBg : T.presentationBg,
                    in: RoundedRectangle(cornerRadius: grid ? 9 : 0))
        .overlay {
            if grid {
                RoundedRectangle(cornerRadius: 9).stroke(T.border, lineWidth: 0.5)
            }
        }
        .overlay(alignment: .bottom) {
            if !grid { Rectangle().fill(T.border).frame(height: 0.5).padding(.leading, 12) }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: ArtifactsBrowserPresentation.kindSymbol(tab))
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(T.fgDim)
            Text(verbatim: tab.hostLabel)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}
