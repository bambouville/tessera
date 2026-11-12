import SwiftUI

/// Laptop pose: a phone folded part way in portrait, its lower half lying
/// flat as a desk. The shell has no tab bar there. Its sections move to the
/// top of the title's ⌄ menu (the ⌘K switcher), so the desk keeps its height.
enum LaptopShellPolicy {
    /// A settled fold across the screen, with no rail. The rail (open flat)
    /// keeps its own sections.
    static func isLaptopPose(isPhone: Bool, railEdge: HorizontalEdge?, fold: DuoFold?) -> Bool {
        isPhone && railEdge == nil && fold?.splitsSideBySide == false
    }

    /// The tab bar's sections, in its order.
    static func sections(agentCenterEnabled: Bool) -> [CompactRootTab] {
        agentCenterEnabled
            ? [.hosts, .sessions, .agents, .artifacts, .settings]
            : [.hosts, .sessions, .artifacts, .settings]
    }

    enum SectionChange: Equatable {
        /// The section is already on screen.
        case stay
        /// From a tab's own page: what its tab would do.
        case selectTab(CompactRootTab)
        /// A session or host editor covers the tab it belongs to. Leave it
        /// (a session keeps running), then show the section.
        case leave(to: SidebarItem?, tab: CompactRootTab)
    }

    static func change(
        to tab: CompactRootTab,
        currentTab: CompactRootTab,
        currentSelection: SidebarItem?,
        agentCenterEnabled: Bool
    ) -> SectionChange {
        let tab = RailNavigationPolicy.visibleTab(tab, agentCenterEnabled: agentCenterEnabled)
        let current = RailNavigationPolicy.visibleTab(currentTab, agentCenterEnabled: agentCenterEnabled)
        guard tab != current else { return .stay }
        switch currentSelection {
        case .session, .host:
            return .leave(to: destination(of: tab), tab: tab)
        default:
            return .selectTab(tab)
        }
    }

    /// The selection a tab shows from its root. Hosts and sessions are the
    /// TabView's own pages.
    static func destination(of tab: CompactRootTab) -> SidebarItem? {
        switch tab {
        case .hosts, .sessions: return nil
        case .agents: return .agents
        case .artifacts: return .artifacts
        case .settings: return .settings
        }
    }
}

/// Where the switcher hangs in laptop pose: from the title, across the
/// screen, and above the fold, so neither the hinge nor the desk carries any
/// of it.
enum LaptopPaletteLayout {
    static let margin: CGFloat = 10
    /// Below a screen's top bar or title.
    static let titleClearance: CGFloat = 52
    static let foldClearance: CGFloat = 8

    static func width(container: CGFloat) -> CGFloat {
        max(0, container - 2 * margin)
    }

    /// `top` and `foldTop` are global.
    static func maxHeight(top: CGFloat, foldTop: CGFloat) -> CGFloat {
        max(0, foldTop - foldClearance - top)
    }
}

/// A half-height sheet would end on the hinge in laptop pose. It rests on the
/// desk instead, its top at the fold's bottom.
enum LaptopSheetLayout {
    /// Below this the desk can't hold a sheet's header and a few rows.
    static let minimumDeskHeight: CGFloat = 200

    /// `safeBottom` and `fold` are in window coordinates. A height detent
    /// leaves out the bottom safe area, so the desk ends at the safe area's.
    static func deskHeight(safeBottom: CGFloat, fold: DuoFold?) -> CGFloat? {
        guard let fold, !fold.splitsSideBySide else { return nil }
        let desk = safeBottom - fold.frame.maxY
        return desk >= minimumDeskHeight ? desk : nil
    }

    /// How far a part-height sheet's top misses where its detent puts it.
    /// iOS moves such a sheet again after laying it out, by a margin no API
    /// reports: measured, 8 pt up on iOS 27's Duo and 8.6 pt down on an iOS
    /// 27.0 iPhone. A larger miss is a reading of the other detent, or of a
    /// keyboard's bar under the sheet.
    static let maximumMiss: CGFloat = 24
    /// A correction that does not land stops trying.
    static let maximumCorrections = 3
    /// Only a top that holds this long is where the sheet rests, not a
    /// presentation still moving or a drag.
    static let settleDelay: Duration = .milliseconds(350)

    /// The correction to the desk's detent, from where the sheet's top
    /// rested.
    struct Calibration: Equatable {
        var desk: CGFloat
        var offset: CGFloat
        var corrections = 0
    }

    /// The last correction, for the next sheet: the miss belongs to the
    /// system and the desk, not to one sheet, so the next opens where this
    /// one came to rest instead of jumping there. It may correct again.
    @MainActor static var rememberedCalibration: Calibration?

    @MainActor static func remember(_ calibration: Calibration?) {
        guard let calibration else { return }
        rememberedCalibration = Calibration(desk: calibration.desk, offset: calibration.offset)
    }

    /// The desk's detent with `calibration` applied, if it is this desk's.
    static func restingDesk(desk: CGFloat?, calibration: Calibration?) -> CGFloat? {
        guard let desk else { return nil }
        guard let calibration, calibration.desk == desk else { return desk }
        return desk + calibration.offset
    }

    /// `top` and `foldBottom` are in window coordinates; a top below the
    /// fold's bottom asks for a taller detent.
    static func calibration(after top: CGFloat, foldBottom: CGFloat, desk: CGFloat,
                            current: Calibration?) -> Calibration? {
        let applied = current?.desk == desk ? current : nil
        let miss = top - foldBottom
        guard abs(miss) > 0.5, (applied?.corrections ?? 0) < maximumCorrections else { return current }
        let offset = (applied?.offset ?? 0) + miss
        guard abs(offset) <= maximumMiss else { return current }
        return Calibration(desk: desk, offset: offset, corrections: (applied?.corrections ?? 0) + 1)
    }

    static func detents(_ detents: Set<PresentationDetent>, desk: CGFloat?) -> Set<PresentationDetent> {
        guard let desk, detents.contains(.medium) else { return detents }
        var resting = detents
        resting.remove(.medium)
        resting.insert(.height(desk))
        return resting
    }
}

extension View {
    /// `presentationDetents`, with `.medium` on the desk in laptop pose.
    func laptopSheetDetents(_ detents: Set<PresentationDetent>) -> some View {
        modifier(LaptopSheetDetents(detents: detents))
    }
}

extension EnvironmentValues {
    /// Laptop pose: the desk's height below the fold, from the shell. A
    /// sheet can't measure it: resting on the desk, it no longer spans the
    /// hinge it would read.
    @Entry var laptopDeskHeight: CGFloat? = nil
    /// Laptop pose: the fold's bottom in window coordinates, where a sheet
    /// resting on the desk puts its top.
    @Entry var laptopFoldBottom: CGFloat? = nil
}

private struct LaptopSheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>
    @Environment(\.laptopDeskHeight) private var desk
    @Environment(\.laptopFoldBottom) private var foldBottom
    /// The sheet's own top in the window, above any safe area inside it.
    @State private var sheetTop: CGFloat?
    @State private var calibration = LaptopSheetLayout.rememberedCalibration

    private struct Reading: Equatable {
        var top: CGFloat?
        var desk: CGFloat?
        var foldBottom: CGFloat?
    }

    func body(content: Content) -> some View {
        content
            .presentationDetents(LaptopSheetLayout.detents(
                detents, desk: LaptopSheetLayout.restingDesk(desk: desk, calibration: calibration)
            ))
            .background {
                if desk != nil, foldBottom != nil, detents.contains(.medium) {
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.frame(in: .global).minY - proxy.safeAreaInsets.top, initial: true) { _, top in
                            if sheetTop != top { sheetTop = top }
                        }
                    }
                    .ignoresSafeArea(.keyboard)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: Reading(top: sheetTop, desk: desk, foldBottom: foldBottom)) {
                guard let top = sheetTop, let desk, let foldBottom, detents.contains(.medium) else { return }
                do { try await Task.sleep(for: LaptopSheetLayout.settleDelay) } catch { return }
                let next = LaptopSheetLayout.calibration(after: top, foldBottom: foldBottom, desk: desk, current: calibration)
                guard calibration != next else { return }
                calibration = next
                LaptopSheetLayout.remember(next)
            }
    }
}

extension CompactRootTab {
    /// The tab bar's label, for the sections that stand in for it.
    var sectionTitle: LocalizedStringKey {
        switch self {
        case .hosts: return "hosts"
        case .sessions: return "sessions"
        case .agents: return "agents"
        case .artifacts: return "artifacts"
        case .settings: return "settings"
        }
    }

    /// The tab bar's symbol.
    var sectionSymbol: String {
        switch self {
        case .hosts: return "server.rack"
        case .sessions: return "rectangle.stack.fill"
        case .agents: return "sparkles"
        case .artifacts: return "square.stack.3d.up"
        case .settings: return "gearshape.fill"
        }
    }

    /// Stable accessibility token, never the localized label.
    var sectionIdentifier: String {
        switch self {
        case .hosts: return "hosts"
        case .sessions: return "sessions"
        case .agents: return "agents"
        case .artifacts: return "artifacts"
        case .settings: return "settings"
        }
    }
}

extension View {
    /// On a compact tab's content: laptop pose runs it to the bottom edge.
    func laptopTabBarHidden(_ hidden: Bool) -> some View {
        toolbarVisibility(hidden ? .hidden : .automatic, for: .tabBar)
    }
}

extension EnvironmentValues {
    /// The title's ⌄ in laptop pose, where it is the only way to another
    /// section. Nil elsewhere: the rail has its own ▾, and the tab bar its
    /// sections.
    var duoTitleSwitcher: DuoSwitcherAction? {
        duoRailMode ? nil : duoOpenSwitcher
    }
}

/// A page title that opens the switcher in laptop pose, like a session's
/// host name and its ⌄. Elsewhere it is the plain title.
struct DuoTitleSwitcher<Title: View>: View {
    @Environment(\.designTokens) private var T
    @Environment(\.duoTitleSwitcher) private var openSwitcher
    let identifier: String
    var isEnabled = true
    @ViewBuilder let title: Title

    /// Grows the target to 44 pt around a shorter title without moving it.
    private static var slop: CGFloat { 10 }

    var body: some View {
        if isEnabled, let openSwitcher {
            Button { openSwitcher() } label: {
                HStack(spacing: 8) {
                    title
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(T.fgMuted)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Self.slop)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -Self.slop)
            .accessibilityHint(Text("switcher"))
            .accessibilityIdentifier(identifier)
        } else {
            title
        }
    }
}
