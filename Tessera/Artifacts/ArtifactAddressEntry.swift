import Observation
import SwiftUI
import TesseraArtifactsCore
import UIKit

/// What an address entry edits: the open field, which opens a new tab, or
/// a tab's own address, which navigates that tab.
struct ArtifactAddressEditRequest: Identifiable, Equatable {
    let id = UUID()
    let placement: ArtifactOpenPlacement
    let currentHostID: String?
    /// The field's text when it opens, all selected.
    let initialText: String
    /// An agent edit's tab: even its unchanged address opens beside it.
    var opensBeside = false
    /// A pose change keeps the draft with its original host and placement.
    fileprivate let draft = ArtifactAddressDraft()

    static func newTab(currentHostID: String?) -> Self {
        .init(placement: .newTab, currentHostID: currentHostID, initialText: "")
    }

    static func edit(_ tab: ArtifactTab, webURL: URL?) -> Self {
        .init(placement: .navigate(tabID: tab.id), currentHostID: tab.hostID,
              initialText: ArtifactsBrowserPresentation.editableAddress(tab, webURL: webURL),
              opensBeside: !ArtifactsReducer.canNavigateInPlace(tab))
    }
}

@Observable
fileprivate final class ArtifactAddressDraft: Equatable {
    var input: String?

    static func == (lhs: ArtifactAddressDraft, rhs: ArtifactAddressDraft) -> Bool { lhs === rhs }
}

/// What Return or a picked row does.
enum ArtifactAddressAction: Equatable {
    /// Nothing typed: the field stays as it is.
    case none
    /// The unchanged address of the tab being edited: editing just ends.
    case keep
    /// An open tab's row: show that tab as it is.
    case switchTo(tabID: String)
    /// Open the address, as a new tab or in the edited tab.
    case open(input: String, hostID: String?)
}

/// One address entry, shared by the toolbar's field and the phone's sheet.
@MainActor @Observable
final class ArtifactAddressEntry {
    let request: ArtifactAddressEditRequest
    var input: String {
        get { request.draft.input ?? request.initialText }
        set {
            guard newValue != input else { return }
            request.draft.input = newValue
            selectedIndex = nil
            message = nil
        }
    }
    var selectedIndex: Int?
    private(set) var message: String?
    private(set) var isOpening = false
    let suggestionSnapshot = ArtifactsQuickOpenSuggestionSnapshot()
    @ObservationIgnored private var openTask: Task<Void, Never>?

    init(_ request: ArtifactAddressEditRequest) {
        self.request = request
    }

    /// Typed in another field before a pose change moved it here.
    var carriesDraft: Bool { request.draft.input != nil }

    /// The edited tab's own row would switch to itself; it is left out.
    var suggestions: [ArtifactsSuggestion] {
        ArtifactsBrowserPresentation.addressSuggestions(suggestionSnapshot.suggestions, placement: request.placement)
    }

    var canSubmit: Bool {
        selectedIndex != nil || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateSuggestions(_ store: any ArtifactsBrowserStore) {
        let key = ArtifactsQuickOpenSuggestionKey(input: input, currentHostID: request.currentHostID,
                                                  storeID: ObjectIdentifier(store), revision: suggestionSnapshot.revision)
        suggestionSnapshot.update(key) {
            store.quickOpenSuggestions(key.input, currentHostID: key.currentHostID)
        }
        if let index = selectedIndex, !suggestions.indices.contains(index) { selectedIndex = nil }
    }

    func moveSelection(_ offset: Int) {
        selectedIndex = ArtifactsBrowserPresentation.nextSuggestionIndex(
            current: selectedIndex, count: suggestions.count, offset: offset
        )
    }

    /// Return: the highlighted row, or the typed address.
    func submit(_ store: any ArtifactsBrowserStore, onOpened: @escaping (String) -> Void, onKeep: @escaping () -> Void) {
        let selected = selectedIndex.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
        perform(ArtifactsBrowserPresentation.addressAction(
            input: input, request: request, selected: selected, tabExists: { store.tab($0) != nil }
        ), store: store, onOpened: onOpened, onKeep: onKeep)
    }

    func submit(_ suggestion: ArtifactsSuggestion, store: any ArtifactsBrowserStore,
                onOpened: @escaping (String) -> Void, onKeep: @escaping () -> Void) {
        perform(ArtifactsBrowserPresentation.addressAction(
            input: input, request: request, selected: suggestion, tabExists: { store.tab($0) != nil }
        ), store: store, onOpened: onOpened, onKeep: onKeep)
    }

    func cancel() {
        openTask?.cancel()
        openTask = nil
        suggestionSnapshot.stopObserving()
    }

    private func perform(_ action: ArtifactAddressAction, store: any ArtifactsBrowserStore,
                         onOpened: @escaping (String) -> Void, onKeep: @escaping () -> Void) {
        guard !isOpening else { return }
        switch action {
        case .none: return
        case .keep: onKeep()
        case let .switchTo(id):
            if store.state.selectedID != id { store.select(id) }
            onOpened(id)
        case let .open(value, hostID):
            let resolved = ArtifactsBrowserPresentation.unambiguousAddress(
                value, hostID: hostID, hosts: store.quickOpenHosts
            )
            let placement = request.placement
            isOpening = true
            message = nil
            openTask = Task { @MainActor [weak self] in
                let outcome = await store.quickOpen(resolved.input, currentHostID: resolved.hostID, placement: placement)
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                switch outcome {
                case let .opened(tabID):
                    if store.state.selectedID != tabID { store.select(tabID) }
                    onOpened(tabID)
                case let .directory(_, path):
                    self.message = String(localized: "browse \(path) in Files. directory navigation from quick open is not available yet.")
                case let .failed(reason):
                    self.message = reason
                }
            }
        }
    }
}

/// The address field itself. UIKit, so a programmatic focus can select the
/// whole address, as a browser's does, and Return, Esc and the arrows reach
/// it from a hardware keyboard.
struct ArtifactAddressField: UIViewRepresentable {
    @Environment(\.designTokens) private var T
    @Binding var text: String
    let placeholder: String
    /// A new token focuses the field and selects everything in it.
    let focusToken: UUID
    /// False for a draft carried over from another field: the caret goes
    /// after it, so typing goes on where it left off.
    var selectsAll = true
    var onSubmit: () -> Void
    /// Esc.
    var onCancel: () -> Void
    var onMove: (Int) -> Void
    /// The field lost focus: a tap elsewhere, or the keyboard went away.
    var onEndEditing: (() -> Void)?
    var identifier = "artifacts-address-field"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ArtifactAddressTextField {
        let field = ArtifactAddressTextField()
        field.delegate = context.coordinator
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        // Paths can hold spaces, which the URL keyboard cannot type.
        field.keyboardType = .default
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = identifier
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A text field hugs its height only weakly, so SwiftUI would let it
        // take the height the content below leaves, and the bar with it.
        field.setContentHuggingPriority(.required, for: .vertical)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: ArtifactAddressTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.text != text { field.text = text }
        let font = UIFont(name: "JetBrainsMono-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
        field.textColor = UIColor(T.fg)
        field.tintColor = UIColor(T.fg)
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(T.fgDim)])
        field.onEscape = { coordinator.parent?.onCancel() }
        field.onMove = { coordinator.parent?.onMove($0) }
        if coordinator.focusedToken != focusToken {
            coordinator.focusedToken = focusToken
            field.focus(selectingAll: selectsAll)
        }
    }

    static func dismantleUIView(_ field: ArtifactAddressTextField, coordinator: Coordinator) {
        coordinator.parent = nil
        field.onEscape = nil
        field.onMove = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ArtifactAddressField?
        var focusedToken: UUID?

        @objc func changed(_ field: UITextField) {
            parent?.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent?.onSubmit()
            return false
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent?.onEndEditing?()
        }
    }
}

final class ArtifactAddressTextField: UITextField {
    var onEscape: (() -> Void)?
    var onMove: ((Int) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        let up = UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upPressed))
        let down = UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downPressed))
        for command in [escape, up, down] { command.wantsPriorityOverSystemBehavior = true }
        return [escape, up, down] + (super.keyCommands ?? [])
    }

    @objc private func escapePressed() { onEscape?() }
    @objc private func upPressed() { onMove?(-1) }
    @objc private func downPressed() { onMove?(1) }

    /// Focus with the whole address selected, or the caret at its end. A
    /// field that is not in a window yet focuses as soon as it is.
    func focus(selectingAll: Bool) {
        pendingFocus = true
        pendingSelectAll = selectingAll
        focusIfPossible()
    }

    private var pendingFocus = false
    private var pendingSelectAll = true

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focusIfPossible()
    }

    private func focusIfPossible() {
        guard pendingFocus, window != nil else { return }
        pendingFocus = false
        _ = becomeFirstResponder()
        // UIKit places the caret after becoming first responder; select
        // on the next turn so the selection is the one that stays.
        let selectsAll = pendingSelectAll
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder else { return }
            self.selectedTextRange = self.textRange(from: selectsAll ? self.beginningOfDocument : self.endOfDocument,
                                                    to: self.endOfDocument)
        }
    }
}

/// The rows under an address field: switch to an open tab, or an address
/// to open. The sheet and the toolbar's dropdown share them.
@MainActor
struct ArtifactAddressSuggestionList: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let entry: ArtifactAddressEntry
    var showsHint = true
    let onPick: (ArtifactsSuggestion) -> Void

    var body: some View {
        let suggestions = entry.suggestions
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = entry.message {
                        Text(verbatim: message)
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                            .accessibilityIdentifier("artifacts-quick-open-message")
                    }
                    if suggestions.isEmpty, showsHint {
                        Text("enter a remote path or a localhost port; an open tab also works offline")
                            .font(Typography.tesseraMono(size: 11))
                            .foregroundStyle(T.fgDim)
                            .padding(16)
                    }
                    ForEach(ArtifactsBrowserPresentation.suggestionKinds, id: \.rawValue) { kind in
                        let indices = suggestions.indices.filter { suggestions[$0].kind == kind }
                        if !indices.isEmpty {
                            Text(verbatim: ArtifactsBrowserPresentation.suggestionHeading(kind))
                                .font(Typography.kicker)
                                .textCase(.uppercase)
                                .tracking(0.6)
                                .foregroundStyle(T.fgDim)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                            ForEach(indices, id: \.self) { index in
                                ArtifactAddressSuggestionRow(store: store, suggestion: suggestions[index], index: index,
                                                             isSelected: index == entry.selectedIndex,
                                                             isDisabled: entry.isOpening) { onPick(suggestions[index]) }
                                    .id(index)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: entry.selectedIndex) { _, index in
                if let index { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }
}

@MainActor
private struct ArtifactAddressSuggestionRow: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let suggestion: ArtifactsSuggestion
    let index: Int
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(T.fgMuted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: suggestion.title)
                        .font(Typography.tesseraMono(size: 12))
                        .foregroundStyle(T.fg)
                        .lineLimit(1)
                    Text(verbatim: suggestion.subtitle)
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if suggestion.tabID != nil {
                    Text("switch to tab")
                        .font(Typography.tesseraMono(size: 10))
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(1)
                }
                if isSelected {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 10))
                        .foregroundStyle(T.fgMuted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? T.inputBg : T.presentationBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("artifacts-suggestion-\(index)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        if let id = suggestion.tabID, let tab = store.tab(id) { return ArtifactsBrowserPresentation.kindSymbol(tab) }
        switch suggestion.kind {
        case .hostPrefix: return "server.rack"
        case .openTab: return "square.on.square"
        case .activeForward, .listeningPort: return "arrow.left.arrow.right"
        case .recent: return "clock"
        }
    }
}

/// The toolbar's dropdown while an address is edited in place: rows over
/// the page, and a tap anywhere else puts the address back.
@MainActor
struct ArtifactAddressDropdown: View {
    @Environment(\.designTokens) private var T
    let store: any ArtifactsBrowserStore
    let entry: ArtifactAddressEntry
    let onPick: (ArtifactsSuggestion) -> Void
    let onCancel: () -> Void
    /// Above the laptop's fold the rows run to the space's end rather than
    /// stopping short of it at the usual cap.
    var fillsSpace = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)
            if entry.message != nil || !entry.suggestions.isEmpty {
                if fillsSpace {
                    // Rows that fit keep their height; more scroll in the whole space.
                    ViewThatFits(in: .vertical) {
                        suggestionList.fixedSize(horizontal: false, vertical: true)
                        suggestionList
                    }
                } else {
                    suggestionList
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { entry.updateSuggestions(store) }
        .onChange(of: entry.input) { _, _ in entry.updateSuggestions(store) }
        .onChange(of: entry.suggestionSnapshot.revision) { _, _ in entry.updateSuggestions(store) }
    }

    private var suggestionList: some View {
        ArtifactAddressSuggestionList(store: store, entry: entry, showsHint: false, onPick: onPick)
            .background(T.presentationBg)
            .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 0.5) }
            .accessibilityIdentifier("artifacts-address-suggestions")
    }
}
