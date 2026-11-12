import Foundation
import Observation
import TesseraArtifactsCore

struct ArtifactsQuickOpenSuggestionKey: Equatable {
    let input: String
    let currentHostID: String?
    let storeID: ObjectIdentifier
    let revision: Int
}

@MainActor @Observable
final class ArtifactsQuickOpenSuggestionSnapshot {
    private(set) var suggestions: [ArtifactsSuggestion] = []
    private(set) var revision = 0
    @ObservationIgnored private var key: ArtifactsQuickOpenSuggestionKey?
    @ObservationIgnored private var observationGeneration = 0

    func update(_ key: ArtifactsQuickOpenSuggestionKey, evaluate: () -> [ArtifactsSuggestion]) {
        guard self.key != key else { return }
        self.key = key
        observationGeneration &+= 1
        let generation = observationGeneration
        // Track the store's actual search dependencies, including port-probe
        // completion and recents, without extending the browser protocol.
        let values = withObservationTracking {
            evaluate()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.revision &+= 1
            }
        }
        suggestions = ArtifactsBrowserPresentation.groupedSuggestions(values)
    }

    func stopObserving() {
        observationGeneration &+= 1
        key = nil
    }
}

struct ArtifactsBadgeText: Equatable {
    let symbol: String
    let text: String
    let accessibilityLabel: String
}

enum ArtifactsBrowserPresentation {
    /// Laptop pose: a phone's open tab, or with none the section's title and
    /// its open field, stands in the upper half, and the overview lies on the
    /// desk below it, another tab a tap away. Flat, folded like a book or in
    /// rail mode, the phone's stack stays.
    static func splitsAtTheFold(_ fold: DuoFold?, railMode: Bool) -> Bool {
        !railMode && fold?.splitsSideBySide == false
    }

    /// A phone types its address and switches tabs in sheets. Laptop pose
    /// keeps both above the fold: the field in place, the overview on the
    /// desk. Wider layouts type in the toolbar.
    static func presentsSheets(compact: Bool, splitsAtTheFold: Bool) -> Bool {
        compact && !splitsAtTheFold
    }

    /// The field a phone's tab bar shows: its own address being edited, and
    /// in laptop pose a new tab's too, which has no sheet there.
    static func tabBarShowsEdit(_ placement: ArtifactOpenPlacement, tabID: String, splitsAtTheFold: Bool) -> Bool {
        placement == .navigate(tabID: tabID) || (splitsAtTheFold && placement == .newTab)
    }

    static func kindSymbol(_ tab: ArtifactTab) -> String {
        switch tab.target.viewer {
        case .markdown: return "doc.text"
        case .html: return "doc.richtext"
        case .web: return "globe"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return tab.kind == .docs ? "doc.text" : "chevron.left.forwardslash.chevron.right"
        case .diff: return "plus.forwardslash.minus"
        case .other: return "doc"
        }
    }

    static func filterTitle(_ filter: ArtifactsFilter) -> String {
        switch filter {
        case .all: return String(localized: "all")
        case .docs: return String(localized: "docs")
        case .pages: return String(localized: "pages")
        case .changes: return String(localized: "changes")
        case .files: return String(localized: "files")
        }
    }

    static func count(_ filter: ArtifactsFilter, in overview: ArtifactsOverview) -> Int {
        filter == .all ? overview.totalCount : overview.countsByKind[filter.rawValue, default: 0]
    }

    static func badge(_ presentation: ArtifactsCachePresentation, now: Date = Date()) -> ArtifactsBadgeText? {
        switch presentation.state {
        case .none: return nil
        case .live:
            return .init(symbol: "circle.fill", text: String(localized: "live"),
                         accessibilityLabel: String(localized: "live; a session is connected to this host"))
        case .cached:
            let text: String
            if let fetchedAt = presentation.fetchedAt {
                let date = Date(timeIntervalSince1970: Double(fetchedAt) / 1_000)
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                let relative = formatter.localizedString(for: min(date, now), relativeTo: now)
                text = String(localized: "cached \(relative)")
            } else { text = String(localized: "cached") }
            return .init(symbol: "clock", text: text, accessibilityLabel: text)
        case .stale:
            return .init(symbol: "clock.badge.exclamationmark", text: String(localized: "stale"),
                         accessibilityLabel: String(localized: "stale; the host has a newer copy"))
        case .offline:
            return .init(symbol: "bolt.slash", text: String(localized: "offline"),
                         accessibilityLabel: String(localized: "offline; no cached copy or live session"))
        }
    }

    static func location(_ tab: ArtifactTab, webURL: URL? = nil) -> String {
        if case let .page(_, port, path) = tab.target {
            if let webURL, let components = URLComponents(url: webURL, resolvingAgainstBaseURL: false) {
                let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
                let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
                let fragment = components.percentEncodedFragment.map { "#" + $0 } ?? ""
                return ":\(port)\(path)\(query)\(fragment)"
            }
            return ":\(port)\(path)"
        }
        return tab.target.path
    }

    static func copyValue(_ tab: ArtifactTab, webURL: URL? = nil) -> String {
        if case let .page(scheme, _, _) = tab.target {
            return "\(scheme)://localhost\(location(tab, webURL: webURL))"
        }
        return tab.target.path
    }

    static func shareValue(_ tab: ArtifactTab, webURL: URL? = nil) -> String {
        if case .page = tab.target { return "\(tab.hostLabel): \(copyValue(tab, webURL: webURL))" }
        return "\(tab.hostLabel):\(tab.target.path)"
    }

    /// The origin alone: a session hint is the opening session's identifier,
    /// for routing a forward, and never reads as a name.
    static func openedFrom(_ tab: ArtifactTab) -> String? {
        switch tab.origin {
        case "files": return String(localized: "opened from Files")
        case "terminalSelection": return String(localized: "opened from a selected path")
        case "terminalLink", "forwarding": return String(localized: "opened from a localhost link")
        case "agentEdit": return String(localized: "opened from an agent edit")
        case "quickOpen": return String(localized: "opened from quick open")
        case "documentLink": return String(localized: "opened from a link in a document")
        default: return nil
        }
    }

    static func suggestionHeading(_ kind: ArtifactsSuggestionKind) -> String {
        switch kind {
        case .hostPrefix: return String(localized: "host and path")
        case .activeForward: return String(localized: "active tunnels")
        case .openTab: return String(localized: "open tabs")
        case .listeningPort: return String(localized: "listening ports")
        case .recent: return String(localized: "recent")
        }
    }

    static let suggestionKinds: [ArtifactsSuggestionKind] = [.hostPrefix, .activeForward, .openTab, .listeningPort, .recent]

    static func groupedSuggestions(_ suggestions: [ArtifactsSuggestion]) -> [ArtifactsSuggestion] {
        suggestionKinds.flatMap { kind in suggestions.filter { $0.kind == kind } }
    }

    static func suggestionInput(_ intent: ArtifactsQuickOpenIntent) -> (input: String, hostID: String?)? {
        switch intent {
        case let .file(hostID, path): return (path, hostID)
        case let .directory(hostID, path): return (path.hasSuffix("/") ? path : path + "/", hostID)
        case let .page(hostID, scheme, port, path): return ("\(scheme)://localhost:\(port)\(path)", hostID)
        case let .search(text): return ("?" + text, nil)
        case .invalid: return nil
        }
    }

    static func suggestionInput(
        _ suggestion: ArtifactsSuggestion, input: String, currentHostID: String?
    ) -> (input: String, hostID: String?)? {
        // A host-prefix row represents the typed request. Resolve its cwd
        // again on submission, even before a queued cache invalidation lands.
        if suggestion.kind == .hostPrefix { return (input, currentHostID) }
        return suggestionInput(suggestion.intent)
    }

    /// A changed page path is navigation, even if the port already has a tab.
    /// Change suggestions must preserve the original immutable snapshot.
    static func canSelectSuggestion(_ suggestion: ArtifactsSuggestion, tab: ArtifactTab) -> Bool {
        guard suggestion.tabID == tab.id else { return false }
        switch (tab.target, suggestion.intent) {
        case (.change, _): return true
        case let (.file(path), .file(hostID, suggestedPath)):
            return hostID == tab.hostID && path == suggestedPath
        case let (.page(scheme, port, path), .page(hostID, suggestedScheme, suggestedPort, suggestedPath)):
            return hostID == tab.hostID && scheme == suggestedScheme && port == suggestedPort && path == suggestedPath
        default: return false
        }
    }

    static func adjacentTabID(tabs: [ArtifactTab], selectedID: String?, offset: Int) -> String? {
        guard !tabs.isEmpty else { return nil }
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return tabs.first?.id }
        let next = ((index + offset) % tabs.count + tabs.count) % tabs.count
        return tabs[next].id
    }

    static func nextSuggestionIndex(current: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0 else { return nil }
        let current = current.flatMap { (0..<count).contains($0) ? $0 : nil } ?? (offset > 0 ? -1 : count)
        return ((current + offset) % count + count) % count
    }

    // MARK: - The address field

    /// A tab's address as its field edits it: `localhost:8001/laptop.html`
    /// for a page, as the page shows it now, or `host:path` for a file.
    static func editableAddress(_ tab: ArtifactTab, webURL: URL? = nil) -> String {
        if case let .page(scheme, _, _) = tab.target {
            let location = location(tab, webURL: webURL)
            return scheme == "https" ? "https://localhost\(location)" : "localhost\(location)"
        }
        return "\(tab.hostLabel):\(tab.target.path)"
    }

    /// The edited tab's own row would switch to itself.
    static func addressSuggestions(_ suggestions: [ArtifactsSuggestion], placement: ArtifactOpenPlacement) -> [ArtifactsSuggestion] {
        guard case let .navigate(tabID) = placement else { return suggestions }
        return suggestions.filter { $0.tabID != tabID }
    }

    /// Return, or a picked row. An open tab's row switches to that tab as it
    /// is; everything else opens where the field says: a new tab, or the
    /// edited tab.
    static func addressAction(
        input: String, request: ArtifactAddressEditRequest, selected: ArtifactsSuggestion?,
        tabExists: (String) -> Bool
    ) -> ArtifactAddressAction {
        if let selected {
            if let id = selected.tabID, tabExists(id) { return .switchTo(tabID: id) }
            guard let destination = suggestionInput(selected, input: input, currentHostID: request.currentHostID) else {
                return .none
            }
            return .open(input: destination.input, hostID: destination.hostID)
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        if case .navigate = request.placement, !request.opensBeside,
           text == request.initialText.trimmingCharacters(in: .whitespacesAndNewlines) {
            return .keep
        }
        return .open(input: text, hostID: request.currentHostID)
    }

    /// `host:path` names a host by its label. When two hosts share the
    /// edited tab's label, its path still resolves on that tab's host.
    static func unambiguousAddress(
        _ input: String, hostID: String?, hosts: [ArtifactsQuickOpenHost]
    ) -> (input: String, hostID: String?) {
        guard let hostID, let label = hosts.first(where: { $0.id == hostID })?.label,
              hosts.filter({ $0.label.lowercased() == label.lowercased() }).count > 1,
              input.lowercased().hasPrefix(label.lowercased() + ":") else { return (input, hostID) }
        let path = String(input.dropFirst(label.count + 1))
        return (path.isEmpty ? "~/" : path, hostID)
    }

    /// A file tab's content restarts when it shows another file. A page's
    /// web view stays: its session loads the new address in place.
    static func contentIdentity(_ tab: ArtifactTab) -> String {
        if case .page = tab.target { return tab.id }
        return "\(tab.id)|\(tab.hostID)|\(tab.target.path)"
    }

    /// ⌘1–⌘8 pick that tab; ⌘9 the last, as browsers do.
    static func tabID(forDigit digit: Int, tabs: [ArtifactTab]) -> String? {
        guard (1...9).contains(digit), !tabs.isEmpty else { return nil }
        if digit == 9 { return tabs.last?.id }
        return tabs.indices.contains(digit - 1) ? tabs[digit - 1].id : nil
    }
}

/// The browser's chrome: which controls each layout shows. At any moment
/// there is exactly one + and at most one tab overview control.
enum ArtifactsChromeLayout: Equatable {
    /// iPad and other regular widths: the toolbar row, then the tab strip.
    case regular
    /// A phone's overview, its first page.
    case compactOverview
    /// A phone's open tab: its address bar and bottom toolbar.
    case compactTab
    /// A folded Duo's laptop pose: the tab on top, the overview on the desk.
    case laptopDesk
    /// Laptop pose with no tab on top: the title and the open field above
    /// the fold, the overview on the desk.
    case laptopOverview
    /// A Duo's rail: the system toolbar carries + over the phone stack.
    case railOverview
    case railTab
    /// The switcher sheet, over a phone's tab.
    case switcher
}

enum ArtifactsChromeControl: Hashable {
    case back, forward, address, reload, shareFile, newTab, overview, tabMenu, closeTab, backToOverview
    case tabStrip, overviewHeaderNewTab, deskOpenRow, titleOpenField, railNewTab, switcherGrid, previousTab, nextTab
}

enum ArtifactsChromePolicy {
    static func controls(_ layout: ArtifactsChromeLayout, showsOverview: Bool, hasTabs: Bool) -> Set<ArtifactsChromeControl> {
        switch layout {
        case .regular:
            var controls: Set<ArtifactsChromeControl> = [.back, .forward, .address, .reload, .newTab, .overview]
            if !showsOverview {
                controls.insert(.shareFile)
                controls.insert(.tabMenu)
                if hasTabs { controls.insert(.tabStrip) }
            }
            return controls
        case .compactOverview: return [.overviewHeaderNewTab]
        case .compactTab:
            return [.backToOverview, .address, .closeTab, .back, .forward, .reload, .previousTab, .nextTab,
                    .switcherGrid, .tabMenu]
        case .laptopDesk:
            // The overview lies on the desk already: no switcher sheet.
            return [.backToOverview, .address, .closeTab, .back, .forward, .reload, .previousTab, .nextTab,
                    .tabMenu, .deskOpenRow]
        case .laptopOverview: return [.titleOpenField]
        case .railOverview: return [.railNewTab]
        case .railTab:
            return [.railNewTab, .backToOverview, .address, .closeTab, .back, .forward, .reload, .previousTab,
                    .nextTab, .switcherGrid, .tabMenu]
        case .switcher: return [.overviewHeaderNewTab]
        }
    }

    static let newTabControls: Set<ArtifactsChromeControl> = [.newTab, .overviewHeaderNewTab, .deskOpenRow, .titleOpenField,
                                                              .railNewTab]
    static let overviewControls: Set<ArtifactsChromeControl> = [.overview, .switcherGrid]

    /// Whether the overview's header carries its own +: only where no
    /// toolbar does.
    static func overviewHeaderOffersNewTab(regular: Bool, railMode: Bool, onDesk: Bool) -> Bool {
        !regular && !railMode && !onDesk
    }
}

/// What a focused browser's chords can do right now.
struct ArtifactsShortcutContext: Equatable {
    var tabCount = 0
    var hasDisplayedTab = false
    var canRefresh = false
    var canGoBack = false
    var canGoForward = false
    var canReopen = false
    var showsPage = false
    var canShareFile = false
    /// A Duo context pane has no overview of its own.
    var hasOverview = true
}

enum ArtifactsShortcutPolicy {
    static func available(_ context: ArtifactsShortcutContext) -> Set<ArtifactsBrowserCommand> {
        var commands: Set<ArtifactsBrowserCommand> = [.newTab, .editAddress]
        if context.hasDisplayedTab {
            commands.insert(.closeTab)
            if context.canRefresh { commands.insert(.reload) }
            if context.canGoBack { commands.insert(.back) }
            if context.canGoForward { commands.insert(.forward) }
            if context.showsPage { commands.insert(.find) }
            if context.canShareFile { commands.insert(.shareFile) }
        }
        if context.canReopen { commands.insert(.reopenTab) }
        if context.tabCount > 1 || (context.tabCount == 1 && !context.hasDisplayedTab) {
            commands.insert(.previousTab)
            commands.insert(.nextTab)
        }
        for digit in 1...9 where context.tabCount >= (digit == 9 ? 1 : digit) {
            commands.insert(.selectTab(digit))
        }
        if context.hasOverview, context.tabCount > 0 { commands.insert(.overview) }
        return commands
    }
}
