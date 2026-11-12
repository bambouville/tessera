#if DEBUG
import SwiftUI
import UIKit

struct DuoWorkspaceHarness: View {
    @Environment(\.designTokens) private var T
    @State private var state: DuoWorkspaceState
    @State private var railEdge: HorizontalEdge?
    @State private var hinge: DuoHingeState = .none
    @State private var fold: DuoFold?
    @State private var size: CGSize = .zero

    init() {
        var initial = DuoWorkspaceState()
        switch ProcessInfo.processInfo.environment["TESSERA_DUO_WORKSPACE_HARNESS_STATE"] {
        case "swapped": initial.swapped = true
        case "fullscreen": initial.fullScreen = true
        case "hidden": initial.contextHidden = true
        default: break
        }
        _state = State(initialValue: initial)
    }

    var body: some View {
        TabView {
            NavigationStack {
                DuoWorkspace(
                    state: $state, isEnabled: true, primaryTakesInput: true,
                    mainIdealWidth: DuoPaneGeometry.mainIdealWidth(columns: 80, cellWidth: 6.3, horizontalPadding: 20)
                ) {
                    DuoWorkspaceHarnessPanel(title: "primary · terminal", isSecondary: false)
                } secondary: {
                    DuoWorkspaceHarnessPanel(title: "secondary · context", isSecondary: true)
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "rail \(railDescription) · hinge \(hingeDescription)")
                        Text(verbatim: "fold \(fold.map { String(describing: $0.frame) } ?? "none")")
                        HStack(spacing: 16) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    state.toggleContext(arrangement: arrangement)
                                }
                            } label: { Label("context", systemImage: "book") }
                            .accessibilityIdentifier("duo-harness-context")
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { state.swap() }
                            } label: { Label("swap", systemImage: "arrow.left.arrow.right") }
                            .accessibilityIdentifier("duo-harness-swap")
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { state.toggleFullScreen() }
                            } label: {
                                Label(state.fullScreen ? LocalizedStringKey("exit full screen") : LocalizedStringKey("full screen"),
                                      systemImage: state.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            }
                            .accessibilityIdentifier("duo-harness-fullscreen")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .buttonStyle(.borderless)
                    }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(T.fg)
                    .padding(10)
                    .background(T.presentationBg.opacity(0.95))
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .onDuoRailEdgeChange { railEdge = $0 }
                .onDuoHingeChange { hinge = $0 }
                .onDuoFoldChange { fold = $0 }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .ignoresSafeArea(.container, edges: .top)
            }
            .tabItem { Label("sessions", systemImage: "terminal") }
        }
        .background(T.bg)
        .tint(T.fg)
        .accessibilityIdentifier("duo-workspace-harness")
    }

    private var arrangement: DuoPaneArrangement {
        DuoPaneGeometry.layout(DuoPaneRequest(
            container: size, fold: fold, contextHidden: false, fullScreen: false, swapped: state.swapped,
            mainTakesInput: !state.swapped, mainIdealWidth: 524
        )).arrangement
    }

    private var railDescription: String {
        switch railEdge {
        case .leading: return "leading"
        case .trailing: return "trailing"
        case nil: return "none"
        }
    }

    private var hingeDescription: String {
        switch hinge {
        case .none: return "none"
        case .moving: return "moving"
        case .settled(.closed): return "settled closed"
        case .settled(.partiallyOpen): return "settled partially open"
        case .settled(.fullyOpen): return "settled fully open"
        }
    }
}

private struct DuoWorkspaceHarnessPanel: View {
    @Environment(\.designTokens) private var T
    @Environment(\.displayScale) private var displayScale
    @Environment(\.duoWorkspace) private var workspace
    var title: String
    var isSecondary: Bool

    var body: some View {
        GeometryReader { proxy in
            let cellHeight = TerminalCellMetrics.cellSize(
                font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular), scale: displayScale
            ).height
            let columns = Int(max(0, proxy.size.width - 20) / 6.3)
            let rows = Int(max(0, proxy.size.height - 28) / cellHeight)
            ZStack {
                (isSecondary ? T.inputBgSoft : T.panelBg)
                VStack(spacing: 16) {
                    Text(verbatim: title).font(.system(size: 22, weight: .semibold))
                    Text(verbatim: String(format: "%.1f × %.1f pt", Double(proxy.size.width), Double(proxy.size.height)))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    Text(verbatim: "\(columns) × \(rows) cells")
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                    Text(verbatim: "10.5 pt · 6.3 pt cells")
                        .font(.system(size: 14, design: .monospaced))
                    Text(verbatim: "20 pt padding · 28 pt header")
                        .font(.system(size: 12, design: .monospaced))
                    if let workspace, workspace.offersFullScreen {
                        Button(action: workspace.toggleFullScreen) {
                            Label(workspace.isFullScreen ? LocalizedStringKey("exit full screen") : LocalizedStringKey("full screen"),
                                  systemImage: workspace.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .accessibilityIdentifier(isSecondary ? "duo-harness-secondary-fullscreen" : "duo-harness-primary-fullscreen")
                    }
                }
                .foregroundStyle(T.fg)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier(isSecondary ? "duo-harness-secondary" : "duo-harness-primary")
    }
}

/// The session rail host-free: the production toolbar over stub actions with
/// every item present, in the shell's tabs. `_COMPRESSION=automatic` shows
/// the system default, `_OPEN=find,files` starts those lit, `_REFUSE=find,files`
/// makes their taps do nothing, `_BADGE=1` badges the hosts tab, `_CONTEXT=1`
/// adds the book, and `_KEYBOARD=1` focuses a field to raise the keyboard.
struct DuoRailHarness: View {
    @Environment(\.designTokens) private var T
    @State private var tab = CompactRootTab.sessions
    @State private var findOpen: Bool
    @State private var filesOpen: Bool
    @State private var railEdge: HorizontalEdge?
    @State private var draft = ""
    @FocusState private var typing: Bool
    private let sessionID = UUID()
    private let prefersActions: Bool
    private let showsContext: Bool
    private let raisesKeyboard: Bool
    private let refused: [Substring]
    private let badged: Bool

    init() {
        let environment = ProcessInfo.processInfo.environment
        let open = (environment["TESSERA_DUO_RAIL_HARNESS_OPEN"] ?? "").split(separator: ",")
        _findOpen = State(initialValue: open.contains("find"))
        _filesOpen = State(initialValue: open.contains("files"))
        prefersActions = environment["TESSERA_DUO_RAIL_HARNESS_COMPRESSION"] != "automatic"
        showsContext = environment["TESSERA_DUO_RAIL_HARNESS_CONTEXT"] == "1"
        raisesKeyboard = environment["TESSERA_DUO_RAIL_HARNESS_KEYBOARD"] == "1"
        refused = (environment["TESSERA_DUO_RAIL_HARNESS_REFUSE"] ?? "").split(separator: ",")
        badged = environment["TESSERA_DUO_RAIL_HARNESS_BADGE"] == "1"
    }

    private var actions: SessionRailActions {
        SessionRailActions(
            sessionID: sessionID, canCreateTmuxWindow: true, findOpen: findOpen, filesOpen: filesOpen,
            hasForwarding: true, hasContinuity: true, filesPanel: nil, filesConnectUnprompted: false,
            openFilesInPlace: nil,
            openSwitcher: { NSLog("duo-rail-harness switcher") },
            createTmuxWindow: { NSLog("duo-rail-harness new window") },
            toggleFind: { refused.contains("find") ? NSLog("duo-rail-harness find refused") : findOpen.toggle() },
            toggleFiles: { refused.contains("files") ? NSLog("duo-rail-harness files refused") : filesOpen.toggle() },
            showForwarding: { NSLog("duo-rail-harness forwarding") },
            showContinuity: { NSLog("duo-rail-harness continuity") },
            disconnect: { NSLog("duo-rail-harness disconnect") }
        )
    }

    var body: some View {
        TabView(selection: $tab) {
            Color.clear
                .tag(CompactRootTab.hosts)
                .tabItem { Label("hosts", systemImage: "server.rack") }
                .badge(badged ? 2 : 0)
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: "rail \(railEdge.map { "\($0)" } ?? "none") · find \(findOpen) · files \(filesOpen)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    if raisesKeyboard {
                        TextField(String("keyboard"), text: $draft)
                            .focused($typing)
                            .foregroundStyle(.white)
                            .onAppear { typing = true }
                    }
                    Spacer()
                }
                .padding(.top, 40)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    RailSessionToolbar(
                        sessionID: sessionID,
                        actions: actions,
                        onBack: { NSLog("duo-rail-harness back") },
                        onOpenPalette: {},
                        onToggleContext: {},
                        showsContext: showsContext,
                        onNewHost: {}
                    )
                }
                .duoRailPrefersActions(prefersActions && RailShellPolicy.prefersRailActions(
                    sessionShown: true, otherTabBadged: badged
                ))
            }
            .tag(CompactRootTab.sessions)
            .tabItem { Label("sessions", systemImage: "rectangle.stack.fill") }
            Color.clear
                .tag(CompactRootTab.artifacts)
                .tabItem { Label("artifacts", systemImage: "square.stack.3d.up") }
            Color.clear
                .tag(CompactRootTab.settings)
                .tabItem { Label("settings", systemImage: "gearshape.fill") }
        }
        .tint(T.accent)
        .background(T.bg)
        .onDuoRailEdgeChange { railEdge = $0 }
        .accessibilityIdentifier("duo-rail-harness")
    }
}
#endif
