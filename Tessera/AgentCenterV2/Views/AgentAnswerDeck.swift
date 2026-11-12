import SwiftUI
import TesseraCore

/// How Agent Center lays out its thread list and its thread.
enum AgentCenterLayout: Equatable {
    /// One at a time: the list, with a thread pushed over it.
    case narrow
    /// The list beside the thread, at regular width.
    case twoColumns
    /// A laptop-folded Duo: read up, choose down. The thread fills the top
    /// half above the fold and the list fills the desk below it.
    case laptop
}

/// A waiting agent's answers, wherever Agent Center offers them outside the
/// transcript's prompt card, and the poses that decide where they go.
@MainActor
enum AgentAnswerDeckPolicy {
    /// A row's one-tap answers: options that take no typed text, at most
    /// three. The rest wait in the overflow sheet.
    static let oneTapLimit = 3

    static func oneTapOptions(_ prompt: AgentActionPrompt) -> [TesseraCore.AgentPromptOption] {
        Array(untypedOptions(prompt).prefix(oneTapLimit))
    }

    static func overflowOptions(_ prompt: AgentActionPrompt) -> [TesseraCore.AgentPromptOption] {
        Array(untypedOptions(prompt).dropFirst(oneTapLimit))
    }

    static func overflows(_ prompt: AgentActionPrompt) -> Bool {
        untypedOptions(prompt).count > oneTapLimit
    }

    static func openControl(_ prompt: AgentActionPrompt) -> AgentPromptControl? {
        prompt.controls?.first { $0.kind == .open }
    }

    private static func untypedOptions(_ prompt: AgentActionPrompt) -> [TesseraCore.AgentPromptOption] {
        prompt.options.filter { $0.acceptsText != true }
    }

    /// The newest prompt: the first one in the last message that has one.
    static func latestPrompt(in messages: [AgentMessage]) -> AgentActionPrompt? {
        for message in messages.reversed() {
            for case .actionPrompt(let prompt) in message.blocks { return prompt }
        }
        return nil
    }

    static func isLaptop(_ fold: DuoFold?) -> Bool { fold?.splitsSideBySide == false }

    /// Laptop pose stacks the thread over the list across the whole width,
    /// even where the inner screen would fit two columns. Every other pose
    /// keeps its two-column threshold.
    static func layout(
        width: CGFloat, includesNavigationSidebar: Bool, railMode: Bool, laptop: Bool
    ) -> AgentCenterLayout {
        if laptop { return .laptop }
        return AgentRailPolicy.usesTwoColumns(
            width: width, includesNavigationSidebar: includesNavigationSidebar, railMode: railMode
        ) ? .twoColumns : .narrow
    }

    /// Two columns and laptop pose show the selected thread on screen with
    /// the list; the narrow stack shows one or the other.
    static func detailVisible(layout: AgentCenterLayout, pushed: Bool) -> Bool {
        layout != .narrow || pushed
    }

    /// The thread a detail shows on screen at the same time as the list:
    /// open beside it, not merely scrolled into view.
    static func threadShownBeside(layout: AgentCenterLayout, shown: AgentThreadID?) -> AgentThreadID? {
        layout == .narrow ? nil : shown
    }
}

/// A waiting row's one-tap answers fold away behind a chevron. They are open
/// by default, except on the row of the thread a detail shows beside the
/// list: its prompt is already on screen, so the row folds and points there.
/// The chevron folds or opens a row by hand for that prompt only, wherever
/// its thread is shown; the agent's next prompt arrives in its default state
/// again. Kept in memory only.
struct AgentRowAnswerFolds: Equatable {
    struct Key: Hashable {
        let thread: AgentThreadID
        let token: AgentActionToken
    }

    /// Rows folded or opened by hand: whether each was left open.
    private(set) var chosen: [Key: Bool] = [:]

    func isOpen(_ key: Key, shownBeside: Bool) -> Bool {
        chosen[key] ?? !shownBeside
    }

    /// The folded row of the thread shown beside says where its answers are.
    static func pointsToDetail(isOpen: Bool, shownBeside: Bool) -> Bool {
        shownBeside && !isOpen
    }

    mutating func flip(_ key: Key, shownBeside: Bool) {
        let open = !isOpen(key, shownBeside: shownBeside)
        // A thread waits on one prompt at a time: an older prompt's choice
        // is spent.
        chosen = chosen.filter { $0.key.thread != key.thread }
        chosen[key] = open
    }

    mutating func prune(retaining threadIDs: Set<AgentThreadID>) {
        let kept = chosen.filter { threadIDs.contains($0.key.thread) }
        if kept != chosen { chosen = kept }
    }
}

/// What rides the hinge in laptop pose, just above the fold.
enum AgentLaptopHingeRow: Equatable {
    /// The thread's composer: docked at the bottom of the viewer, and on the
    /// hinge with ⌨ while the keyboard covers the desk.
    case composer
    /// The list's search field. On the desk it would sit under the keyboard.
    case search
    /// Answering a prompt in words: the transcript's card takes the
    /// composer's place on the hinge, its options still in view.
    case promptCard
}

enum AgentLaptopPolicy {
    /// The software keyboard covers the desk: a session reports it, or the
    /// proposal ends above the fold's bottom. A hardware keyboard's shortcut
    /// bar leaves the desk standing.
    static func isTyping(keyboardUp: Bool, container: CGSize, fold: DuoFold) -> Bool {
        keyboardUp || DuoInputDeckLayout.keyboardCoversDesk(container: container, fold: fold)
    }

    static func hingeRow(
        searchOpen: Bool, focus: AgentCenterV2PresentationModel.KeyboardFocus, typing: Bool
    ) -> AgentLaptopHingeRow {
        if searchOpen { return .search }
        if typing && focus == .promptAnswer { return .promptCard }
        return .composer
    }

    /// While the query rides the hinge, its matches fill the top half.
    static func showsSearchMatchesAbove(row: AgentLaptopHingeRow, typing: Bool, query: String) -> Bool {
        row == .search && typing && !query.isEmpty
    }

    /// The desk below the fold, in a container the keyboard has not shortened.
    static func restingDeskHeight(container: CGSize, fold: DuoFold) -> CGFloat {
        max(0, container.height - fold.frame.maxY)
    }
}

/// Agent Center on a laptop-folded Duo: read up, choose down. The viewer
/// (the selected thread's header, transcript and prompts) fills the top half
/// with its composer docked at the bottom, just above the fold. The thread
/// list fills the desk and never takes input: replies, prompt answers and new
/// instructions all go through the viewer. While the software keyboard
/// covers the desk, the composer stays on the hinge with ⌨ and the list
/// steps aside, mounted and unseen, at the size it had.
struct AgentCenterV2LaptopView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let fold: DuoFold
    @Binding var answerFolds: AgentRowAnswerFolds
    @Environment(\.softwareKeyboardUp) private var sessionKeyboardUp
    @Environment(\.designTokens) private var T
    @State private var size: CGSize = .zero
    @State private var restingDeskHeight: CGFloat = 0
    @State private var searchOpen = false

    var body: some View {
        let typing = AgentLaptopPolicy.isTyping(keyboardUp: sessionKeyboardUp, container: size, fold: fold)
        let row = AgentLaptopPolicy.hingeRow(searchOpen: searchOpen, focus: model.keyboardFocus, typing: typing)
        DuoFoldedInputLayout(isEnabled: true, fold: fold, bar: .viewerComposer) {
            AgentThreadDetailView(model: model, isCompact: true, isLaptopViewer: true)
                .overlay {
                    if AgentLaptopPolicy.showsSearchMatchesAbove(row: row, typing: typing, query: model.searchQuery) {
                        AgentLaptopSearchMatches(model: model) { result in
                            model.openSearchResult(result)
                            AgentComposerView.hideKeyboard()
                        }
                    }
                }
        } deck: {
            VStack(spacing: 0) {
                if row == .search {
                    AgentThreadSearchHingeField(model: model) { searchOpen = false }
                }
                if row == .promptCard {
                    AgentLaptopAnswerHingeBar()
                }
                // Mounted throughout, so its draft, focus bookkeeping and
                // attachments survive search and a typed prompt answer.
                if let thread = model.selectedThreadForDetail {
                    AgentThreadComposerSlot(model: model, thread: thread, isCompact: true)
                        .frame(height: row == .composer ? nil : 0, alignment: .top)
                        .opacity(row == .composer ? 1 : 0)
                        .allowsHitTesting(row == .composer)
                        .accessibilityHidden(row != .composer)
                }
            }
        } desk: {
            AgentThreadListView(
                model: model, isCompact: true, isOnDesk: true, answerFolds: $answerFolds,
                shownBesideThreadID: model.selectedThreadForDetail?.summary.id
            )
            // No height of its own with the keyboard down, so it fills the
            // desk; while typing it keeps the desk's resting size under the
            // keyboard instead of collapsing and rebuilding its rows.
            .frame(minHeight: 0, idealHeight: typing ? restingDeskHeight : 0, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .background(T.panelBg)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { next in
            size = next
            if !AgentLaptopPolicy.isTyping(keyboardUp: sessionKeyboardUp, container: next, fold: fold) {
                let resting = AgentLaptopPolicy.restingDeskHeight(container: next, fold: fold)
                if restingDeskHeight != resting { restingDeskHeight = resting }
            }
        }
        // ⌘F, and ⌕ on the desk.
        .onChange(of: model.searchFocusRequest) { _, _ in searchOpen = true }
        .stackBoundary()
    }
}

/// The hinge while a prompt card above takes a typed answer: the composer
/// steps aside, so ⌨ here puts the keyboard away without sending.
private struct AgentLaptopAnswerHingeBar: View {
    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: AgentComposerView.hideKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-center-v2-answer-hide-keyboard")
            .accessibilityLabel("Hide keyboard")
        }
        .padding(.horizontal, 12)
        .background(T.panelBg)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
    }
}

/// The list's search field on the hinge in laptop pose. It edits the same
/// query as the list, which sends the search; it closes when it gives up
/// the keyboard.
struct AgentThreadSearchHingeField: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let onEnd: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.duoDeckPlacement) private var placement
    @Environment(\.designTokens) private var T

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(T.fgDim)
                .frame(width: 40, height: 44)
                .accessibilityHidden(true)
            TextField("search all transcripts", text: $model.searchQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .font(Typography.tesseraMono(size: 12))
                .frame(maxWidth: .infinity, minHeight: 44)
                .onSubmit {
                    model.onAction?(.search(model.searchQuery))
                    focused = false
                }
                .accessibilityIdentifier("agent-center-v2-search-hinge")
            if !model.searchQuery.isEmpty {
                Button("clear") { model.searchQuery = "" }
                    .font(Typography.tesseraMono(size: 10.5))
                    .foregroundStyle(T.fgDim)
                    .frame(minWidth: 44, minHeight: 44)
            }
            if placement?.keyboardUp == true {
                Button(action: AgentComposerView.hideKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(T.fgMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-center-v2-search-hide-keyboard")
                .accessibilityLabel("Hide keyboard")
            }
        }
        .padding(.trailing, 2)
        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(T.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(T.panelBg)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
        // After the field mounts, which focus requires.
        .task { focused = true }
        .onChange(of: model.searchFocusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                model.keyboardFocus = .search
            } else {
                if model.keyboardFocus == .search { model.keyboardFocus = .none }
                onEnd()
            }
        }
    }
}

/// Search matches over the viewer while the query rides the hinge: the
/// keyboard covers the list's own. A few matches sit just above the field.
private struct AgentLaptopSearchMatches: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let onOpen: (AgentSearchResult) -> Void
    @Environment(\.designTokens) private var T

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("transcript matches")
                        .font(Typography.kicker).foregroundStyle(T.fgDim)
                    Rectangle().fill(T.border).frame(height: 1)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 5)
                AgentThreadSearchResults(model: model, isCompact: true, onOpen: onOpen)
            }
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom, for: .alignment)
        // Opaque: the transcript underneath must not show through.
        .background(T.panelBg)
        .background(T.presentationBg)
        .accessibilityIdentifier("agent-center-v2-laptop-search-matches")
    }
}
