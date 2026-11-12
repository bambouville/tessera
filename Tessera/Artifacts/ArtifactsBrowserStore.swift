import SwiftUI
import TesseraArtifactsCore

/// The browser only reads presentation and sends explicit user actions. A
/// DEBUG fixture can supply the same surface without owning a connection.
@MainActor
protocol ArtifactsBrowserStore: AnyObject {
    var state: ArtifactsState { get }
    var selectedTab: ArtifactTab? { get }
    /// Whether the browser shows its overview rather than the selected tab.
    /// The store outlives every browser view, so an app-tab switch that
    /// rebuilds the view comes back to what the user left.
    var showsBrowserOverview: Bool { get set }
    var quickOpenHosts: [ArtifactsQuickOpenHost] { get }
    func tab(_ id: String) -> ArtifactTab?
    func overview(query: String) -> ArtifactsOverview
    func content(for tabID: String) -> ArtifactContent
    func presentation(for tabID: String) -> ArtifactsCachePresentation
    func isLive(hostID: String) -> Bool
    func select(_ tabID: String)
    func close(_ tabID: String)
    func closeAll(hostID: String)
    func setPinned(_ tabID: String, _ pinned: Bool)
    func setFilter(_ filter: ArtifactsFilter)
    func refresh(_ tabID: String)
    func noteVisible(_ tabID: String?)
    func noteOverviewVisible(_ id: UUID, _ visible: Bool)
    func titleLearned(_ tabID: String, _ title: String)
    func canKeepAsRule(_ tabID: String) -> Bool
    func keepAsRule(_ tabID: String)
    func quickOpenSuggestions(_ input: String, currentHostID: String?) -> [ArtifactsSuggestion]
    /// A typed or picked address. `.newTab` always opens a new tab;
    /// `.navigate` shows it in that tab, where its kind allows.
    func quickOpen(_ input: String, currentHostID: String?, placement: ArtifactOpenPlacement) async -> ArtifactQuickOpenOutcome
    /// Nil unless the tab's host is connected in a terminal but not over
    /// Files, and the tab is a file, or a page on a mosh host with no SSH
    /// connection to forward it.
    func filesReconnect(for tabID: String) -> ArtifactFilesReconnect?
    /// Opens that Files connection, as opening Files does: only ever from a
    /// refresh the user asked for, since a tab never reconnects on its own.
    func connectFiles(_ tabID: String)
    /// ⌘⇧T, from a small in-memory stack of closed tabs.
    var canReopenClosedTab: Bool { get }
    @discardableResult func reopenClosedTab() -> String?
    func shareableFile(for tabID: String) -> ArtifactFileShare
    /// Counts the address submissions that sent a page tab somewhere, so
    /// its web view goes there even when the tab's target is unchanged
    /// (the page had followed a link away from it).
    func pageNavigation(for tabID: String) -> Int
}

/// Where a tab the user asked for goes.
enum ArtifactOpenPlacement: Equatable {
    /// ⌘T, +, or the overview's open field.
    case newTab
    /// The tab whose address was edited. A tab keeps its host and an agent
    /// edit's snapshot cannot be retargeted, so an address on another host,
    /// or typed on an agent edit, opens as a new tab instead.
    case navigate(tabID: String)
}

/// What a tab's share control offers.
enum ArtifactFileShare: Equatable {
    /// Not a file: a forwarded page or an agent edit has no file to send.
    case none
    /// The complete cached copy, with its own name.
    case ready(URL)
    /// A file without a complete copy yet, and why.
    case unavailable(String)
}

/// Closed tabs for reopening, newest last, bounded.
struct ArtifactClosedTabStack {
    static let capacity = 20
    private(set) var tabs: [ArtifactTab] = []

    mutating func push(_ tab: ArtifactTab) {
        tabs.append(tab)
        if tabs.count > Self.capacity { tabs.removeFirst(tabs.count - Self.capacity) }
    }

    mutating func pop() -> ArtifactTab? { tabs.popLast() }

    mutating func retain(where keep: (ArtifactTab) -> Bool) { tabs.removeAll { !keep($0) } }

    func contains(where predicate: (ArtifactTab) -> Bool) -> Bool { tabs.contains(where: predicate) }
}

/// A file tab's way back to fresh content while its host's terminal is
/// connected and Files is not.
enum ArtifactFilesReconnect: Equatable {
    case available
    case connecting
    case failed(String)
}

extension ArtifactsBrowserStore {
    func noteOverviewVisible(_ id: UUID, _ visible: Bool) {}
    func filesReconnect(for tabID: String) -> ArtifactFilesReconnect? { nil }
    func connectFiles(_ tabID: String) {}
    var canReopenClosedTab: Bool { false }
    @discardableResult func reopenClosedTab() -> String? { nil }
    func shareableFile(for tabID: String) -> ArtifactFileShare { .none }
    func pageNavigation(for tabID: String) -> Int { 0 }

    /// A failed load is worth another try while its host is reachable. A
    /// page counts as refreshable only once forwarded, so this is the way
    /// back for one whose forward failed.
    func canRetry(_ tabID: String) -> Bool {
        guard case .unavailable(.failed) = content(for: tabID), let tab = tab(tabID) else { return false }
        return isLive(hostID: tab.hostID)
    }

    /// Refresh controls also reconnect a connected terminal's host over Files.
    func canRefreshOrReconnect(_ tabID: String) -> Bool {
        if presentation(for: tabID).canRefresh || canRetry(tabID) { return true }
        switch filesReconnect(for: tabID) {
        case .available?, .failed?: return true
        case .connecting?, nil: return false
        }
    }
}

extension ArtifactsStore: ArtifactsBrowserStore {}

struct ArtifactChromeButton: View {
    @Environment(\.designTokens) private var T
    let symbol: String
    let label: LocalizedStringKey
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? T.fgMuted : T.fgFaint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct ArtifactsChromeSurface: ViewModifier {
    @Environment(\.designTokens) private var T

    func body(content: Content) -> some View {
        content
            // Over a picture, frost it with the theme's glass wash, as the
            // session's pane header does beside it.
            .background(T.picturesBehind ? T.sidebarBg : T.panelBg)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 0.5) }
    }
}

extension View {
    func artifactsChromeSurface() -> some View { modifier(ArtifactsChromeSurface()) }
}
