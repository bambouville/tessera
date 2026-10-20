import GameController
import PhotosUI
import SwiftUI
import TesseraCore
import UniformTypeIdentifiers

struct AgentComposerView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let thread: AgentThreadSnapshot
    let isCompact: Bool
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var composerFocused = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Menu {
                Button("File") {
                    model.prepareAttachments(for: thread, source: .file, composerWasFocused: composerFocused)
                }
                .accessibilityIdentifier("agent-center-v2-attach-file")
                Button("Photo") {
                    model.prepareAttachments(for: thread, source: .photo, composerWasFocused: composerFocused)
                }
                .accessibilityIdentifier("agent-center-v2-attach-photo")
            } label: {
                Group {
                    if isUploading {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier("agent-center-v2-upload-progress")
                    } else {
                        Image(systemName: "plus").font(.system(size: 17, weight: .regular))
                    }
                }
                .foregroundStyle(T.fgMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(AgentComposerButtonStyle())
            .disabled(isSending || isUploading || thread.binding == nil)
            .accessibilityIdentifier("agent-center-v2-attach")
            .accessibilityLabel(isUploading ? "uploading attachment" : "add attachment")
            AgentComposerTextView(
                threadID: thread.summary.id,
                text: Binding(
                    get: { model.draftBinding(for: thread.summary.id) },
                    set: { model.setDraft($0, for: thread.summary.id) }
                ),
                isFocused: $composerFocused,
                focusRequest: model.composerFocusRequest,
                consumeFocusRequest: { model.consumeComposerFocusRequest($0) },
                placeholder: placeholder,
                fontSize: composerFontSize,
                textColor: UIColor(T.fg),
                tintColor: UIColor(T.accent),
                onSend: { if hasDraft { model.sendDraft(for: thread) } }
            )
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if model.draftBinding(for: thread.summary.id).isEmpty {
                    Text(placeholder)
                        .font(.system(size: composerFontSize))
                        .foregroundStyle(T.fgDim)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 13)
            .onChange(of: composerFocused) { _, focused in
                if focused { model.keyboardFocus = .composer }
                else if model.keyboardFocus == .composer { model.keyboardFocus = .none }
            }
            Button {
                if hasDraft { model.sendDraft(for: thread) }
                else { model.onAction?(.beginDictation(thread.summary.id)) }
            } label: {
                Group {
                    if isSending {
                        ProgressView().controlSize(.small)
                            .accessibilityIdentifier("agent-center-v2-send-progress")
                    } else if showsSendShortcut {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .medium))
                            // Force Return's text glyph instead of iOS emoji presentation.
                            Text("⌘↩\u{FE0E}")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(T.fgMuted)
                                .accessibilityHidden(true)
                        }
                    } else {
                        Image(systemName: hasDraft ? "arrow.up" : "mic")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .foregroundStyle(hasDraft ? T.fg : T.fgMuted)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(AgentComposerButtonStyle())
            .disabled(isSending || isUploading)
            .accessibilityIdentifier(hasDraft || isSending ? "agent-center-v2-send" : "agent-center-v2-dictation")
            .accessibilityLabel(isSending ? "sending message" : hasDraft ? "send" : "dictate message")
            .accessibilityValue(showsSendShortcut ? "command return" : "")
            .contextMenu {
                if thread.summary.id.providerID == .codex, thread.summary.status == .working, hasDraft {
                    Button("Queue message") { model.sendDraft(for: thread, queueWhenWorking: true) }
                        .disabled(isSending || isUploading)
                }
            }
        }
        .padding(.trailing, 2)
        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(T.border, lineWidth: 1))
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, 7)
        .background(T.panelBg)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
        .onAppear { model.setComposerMounted(true, for: thread.summary.id) }
        .onChange(of: thread.summary.id) { oldID, newID in
            model.setComposerMounted(false, for: oldID)
            model.setComposerMounted(true, for: newID)
        }
        .onDisappear { model.setComposerMounted(false, for: thread.summary.id) }
    }

    private var isSending: Bool { model.pendingSends[thread.summary.id] != nil }
    private var isUploading: Bool { model.uploadingThreads.contains(thread.summary.id) }
    private var hasDraft: Bool { !model.draftBinding(for: thread.summary.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// ⌘↩ exists only on a hardware keyboard, on iPad and iPhone alike, so
    /// the hint appears only with one attached and only while the button sends.
    private var showsSendShortcut: Bool { hasDraft && !isSending && !isUploading && AgentHardwareKeyboard.shared.isConnected }
    /// Prose size scaled like `tesseraSansScaled`, shared by the UIKit text
    /// view and its placeholder so both render one font.
    private var composerFontSize: CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(
            for: AgentTranscriptTypography.proseSize(isPhone: CompactLayout.isPhone(horizontalSizeClass)),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        )
    }
    private var placeholder: String {
        switch thread.summary.status {
        case .waitingForInput: return String(localized: "answer above, or type to redirect")
        case .working: return String(localized: "message \(thread.summary.providerName)…")
        case .idle, .finished, .unavailable: return String(localized: "prompt \(thread.summary.providerName)…")
        }
    }
}

/// Observable GameController keyboard presence for the composer's shortcut
/// hint; `GCKeyboardShim` answers once, this follows connects and disconnects.
@MainActor @Observable
final class AgentHardwareKeyboard {
    static let shared = AgentHardwareKeyboard()
    private(set) var isConnected: Bool

    private init() {
        isConnected = GCKeyboardShim.isConnected
        #if DEBUG
        if ProcessInfo.processInfo.environment["TESSERA_AGENT_CENTER_V2_HARNESS_HARDWARE_KEYBOARD"] == "1" {
            isConnected = true
            return
        }
        #endif
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isConnected = GCKeyboardShim.isConnected }
            }
        }
    }
}

/// The composer's UIKit text view. SwiftUI's vertical `TextField` treats a
/// hardware Return as a submission: the field swallows the key-down and ends
/// editing on key-up, so Return can never add a line. A `UITextView` inserts
/// newlines natively for Return and ⇧Return, IME composition included, and
/// ⌘Return and ⌃Return send through priority key commands on the text view
/// itself (the terminal's pattern), ahead of any text-system handling.
struct AgentComposerTextView: UIViewRepresentable {
    let threadID: AgentThreadID
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: AgentCenterV2PresentationModel.ComposerFocusRequest?
    let consumeFocusRequest: (AgentCenterV2PresentationModel.ComposerFocusRequest) -> Bool
    let placeholder: String
    let fontSize: CGFloat
    let textColor: UIColor
    let tintColor: UIColor
    let onSend: () -> Void
    private static let maximumLines: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "agent-center-v2-composer"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        let switchedThread = context.coordinator.threadID != threadID
        // An unfinished composition belongs to the old thread's draft: commit
        // it while the coordinator still writes through that draft's binding.
        if switchedThread, view.markedTextRange != nil { view.unmarkText() }
        context.coordinator.parent = self
        view.onSend = onSend
        if view.font?.pointSize != fontSize { view.font = .systemFont(ofSize: fontSize) }
        view.textColor = textColor
        view.tintColor = tintColor
        view.accessibilityLabel = placeholder
        if switchedThread {
            context.coordinator.threadID = threadID
            view.text = text
        } else if view.text != text, view.markedTextRange == nil {
            // Never rewrite the text under an IME composition or a matching
            // edit; either would reset the caret.
            view.text = text
        }
        if let request = focusRequest, request.threadID == threadID,
           context.coordinator.lastFocusRequestID != request.id {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak view] in
                guard coordinator.threadID == request.threadID,
                      coordinator.lastFocusRequestID != request.id,
                      let view, view.window != nil,
                      coordinator.parent.consumeFocusRequest(request) else { return }
                coordinator.lastFocusRequestID = request.id
                view.becomeFirstResponder()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? max(uiView.bounds.width, 1)
        let lineHeight = (uiView.font ?? .systemFont(ofSize: fontSize)).lineHeight
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(min(max(fitting, lineHeight), lineHeight * Self.maximumLines)))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AgentComposerTextView
        var threadID: AgentThreadID
        var lastFocusRequestID: UUID?
        init(_ parent: AgentComposerTextView) {
            self.parent = parent
            threadID = parent.threadID
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
    }

    final class ComposerTextView: UITextView {
        var onSend: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let send = [UIKeyModifierFlags.command, .control].map { modifiers in
                let command = UIKeyCommand(title: "send agent message", action: #selector(sendFromKeyboard),
                                           input: "\r", modifierFlags: modifiers)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
            return (super.keyCommands ?? []) + send
        }

        @objc private func sendFromKeyboard() {
            // Commit an IME composition first, as Return would, so the
            // send carries what the field shows.
            if markedTextRange != nil { unmarkText() }
            onSend?()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Scrolling is only for drafts past five lines; a draft that fits
            // must not keep an offset from before the frame grew.
            if contentSize.height <= bounds.height + 0.5, contentOffset.y != 0 { contentOffset = .zero }
        }
    }
}

private struct AgentComposerButtonStyle: ButtonStyle {
    @Environment(\.designTokens) private var T
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? T.border : .clear, in: Circle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// UIKit's native browser also works when the surrounding SwiftUI content is
/// embedded in Tessera's custom presentation hierarchy.
struct AgentAttachmentDocumentPicker: UIViewControllerRepresentable {
    let onCompletion: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: ([URL]) -> Void
        private var completed = false
        init(onCompletion: @escaping ([URL]) -> Void) { self.onCompletion = onCompletion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
        private func finish(_ urls: [URL]) {
            guard !completed else { return }
            completed = true
            onCompletion(urls)
        }
    }
}

struct AgentAttachmentPhotoPicker: UIViewControllerRepresentable {
    let request: AgentCenterV2PresentationModel.AttachmentPickerRequest
    let onStartLoading: (@escaping () -> Void) -> Bool
    let onCompletion: (Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PHPickerViewController, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: AgentAttachmentPhotoPicker
        private var completed = false
        private var loadingTask: Task<Void, Never>?
        private var load: AgentAttachmentPhotoLoad?
        init(_ parent: AgentAttachmentPhotoPicker) { self.parent = parent }

        func cancel() {
            loadingTask?.cancel()
            load?.cancel()
            loadingTask = nil
            load = nil
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !completed else { return }
            completed = true
            guard !results.isEmpty else { parent.onCompletion(.success([])); return }
            let load = AgentAttachmentPhotoLoad(directory: parent.request.photoDirectory)
            self.load = load
            guard parent.onStartLoading({ [weak self] in self?.cancel() }) else { cancel(); return }
            picker.view.isUserInteractionEnabled = false
            let directory = parent.request.photoDirectory
            loadingTask = Task { @MainActor [self] in
                do {
                    var urls: [URL] = []
                    for result in results {
                        let provider = result.itemProvider
                        let name = provider.suggestedName
                        let url = try await load.loadFile(suggestedName: name) { completion in
                            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                                completion(url, error)
                            }
                        }
                        urls.append(url)
                    }
                    try Task.checkCancellation()
                    loadingTask = nil
                    self.load = nil
                    parent.onCompletion(.success(urls))
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    loadingTask = nil
                    self.load = nil
                    guard !Task.isCancelled else { return }
                    parent.onCompletion(.failure(error))
                }
            }
        }
    }
}

struct AgentLaunchSheet: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let mode: AgentCenterV2PresentationModel.LaunchMode
    let isCompact: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var T

    private var selectedTarget: AgentCenterV2PresentationModel.LaunchTarget? {
        model.launchTargets.first { $0.id == model.launchDraft.targetID }
    }

    private var availableProviders: [AgentProviderID] {
        let capability: AgentActionCapability = isFork ? .fork : .spawn
        return (selectedTarget?.providerIDs ?? []).filter {
            AgentProviderRegistry.builtIn.manifest(for: $0)?.actions.contains(capability) == true
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field("task") {
                        TextField(isFork ? "what should this branch do differently…" : "describe the task…", text: $model.launchDraft.task, axis: .vertical)
                            .lineLimit(3...8)
                            .fieldStyle(T)
                    }
                    field("name · optional") {
                        TextField(isFork ? "name this fork…" : "name this thread…", text: $model.launchDraft.name)
                            .fieldStyle(T)
                    }
                    field("host · live sessions only") {
                        AgentCenterV2FlowLayout(spacing: 7) {
                            ForEach(model.launchTargets) { target in
                                choice(target.title, detail: target.detail, selected: model.launchDraft.targetID == target.id) {
                                    model.launchDraft.targetID = target.id
                                    let capability: AgentActionCapability = isFork ? .fork : .spawn
                                    model.launchDraft.providerID = target.providerIDs.first {
                                        AgentProviderRegistry.builtIn.manifest(for: $0)?.actions.contains(capability) == true
                                    }
                                    model.launchDraft.directory = target.recentDirectories.first ?? ""
                                    model.launchDraft.windowID = target.windows.first?.id
                                    model.launchDraft.paneID = target.windows.first?.paneIDs.first
                                }
                            }
                        }
                    }
                    if !isFork {
                        field("agent") {
                            AgentCenterV2FlowLayout(spacing: 7) {
                                ForEach(availableProviders, id: \.self) { provider in
                                    choice(provider.rawValue, selected: model.launchDraft.providerID == provider) { model.launchDraft.providerID = provider }
                                }
                            }
                        }
                    }
                    field("directory · validated remote locations") {
                        if let directories = selectedTarget?.recentDirectories, !directories.isEmpty {
                            AgentCenterV2FlowLayout(spacing: 7) {
                                ForEach(directories, id: \.self) { directory in
                                    choice(directory, selected: model.launchDraft.directory == directory) { model.launchDraft.directory = directory }
                                }
                            }
                        } else {
                            Text("No validated remote location is available for this session.")
                                .font(Typography.tesseraMono(size: 10.5))
                                .foregroundStyle(T.fgDim)
                        }
                    }
                    field("placement") {
                        Picker("placement", selection: $model.launchDraft.placement) {
                            Text("new window").tag(AgentCenterV2PresentationModel.LaunchDraft.Placement.newWindow)
                            Text("split a pane").tag(AgentCenterV2PresentationModel.LaunchDraft.Placement.split)
                        }
                        .pickerStyle(.segmented)
                        if model.launchDraft.placement == .split {
                            Picker("window", selection: $model.launchDraft.windowID) {
                                ForEach(selectedTarget?.windows ?? []) { window in
                                    Text("window \(window.id) · \(window.title)").tag(Optional(window.id))
                                }
                            }
                            .padding(.top, 10)
                            Picker("pane", selection: $model.launchDraft.paneID) {
                                Text("new pane").tag(Optional<String>.none)
                                ForEach(selectedTarget?.windows.first(where: { $0.id == model.launchDraft.windowID })?.paneIDs ?? [], id: \.self) { paneID in
                                    Text("pane \(paneID)").tag(Optional(paneID))
                                }
                            }
                            .padding(.top, 8)
                            Picker("shape", selection: $model.launchDraft.axis) {
                                Text("split right").tag(AgentSplitAxis.right)
                                Text("split down").tag(AgentSplitAxis.down)
                            }
                            .pickerStyle(.segmented)
                            .padding(.top, 8)
                        }
                    }
                    field("isolation") {
                        Picker("isolation", selection: $model.launchDraft.isolation) {
                            Text("current branch").tag(AgentCenterV2PresentationModel.LaunchDraft.Isolation.currentWorktree)
                            Text("new worktree + branch").tag(AgentCenterV2PresentationModel.LaunchDraft.Isolation.newWorktree)
                        }
                        .pickerStyle(.segmented)
                        if model.launchDraft.isolation == .newWorktree {
                            TextField("branch name", text: $model.launchDraft.branch)
                                .fieldStyle(T)
                                .padding(.top, 8)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("summary")
                            .font(Typography.kicker)
                            .foregroundStyle(T.fgDim)
                        Text(summary)
                            .font(Typography.tesseraMono(size: 10.5))
                            .foregroundStyle(T.fgMuted)
                    }
                    .padding(.top, 13)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .navigationTitle(isFork ? "fork thread" : "new agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isFork ? "fork" : "launch") {
                        model.submitLaunch()
                        dismiss()
                    }
                    .disabled(!canLaunch)
                    .accessibilityIdentifier("agent-center-v2-submit-launch")
                }
            }
        }
        .presentationDetents(isCompact ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
    }

    private var isFork: Bool { if case .fork = mode { true } else { false } }
    private var canLaunch: Bool {
        !model.launchDraft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.launchDraft.targetID != nil
            && model.launchDraft.providerID.map { availableProviders.contains($0) } == true
            && AgentRemotePath(model.launchDraft.directory) != nil
            && (model.launchDraft.isolation == .currentWorktree || !model.launchDraft.branch.isEmpty)
    }
    private var summary: String {
        let kind = isFork ? "Fork" : "Launch"
        let provider = model.launchDraft.providerID?.rawValue ?? "agent"
        let target = selectedTarget?.title ?? "connected host"
        let place = model.launchDraft.placement == .newWindow ? "a new tmux window" : "a tmux split"
        let isolation = model.launchDraft.isolation == .currentWorktree ? "the current worktree" : "a new worktree"
        return "\(kind) \(provider) on \(target) in \(place), using \(isolation)."
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(Typography.kicker).foregroundStyle(T.fgDim)
            content()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
    }

    private func choice(_ title: String, detail: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let detail { Text(detail).foregroundStyle(selected ? T.accent : T.fgFaint).lineLimit(1) }
            }
            .font(Typography.tesseraMono(size: 10.5))
            .foregroundStyle(selected ? T.fg : T.fgMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: isCompact ? 44 : nil)
            .background(selected ? T.accentSoft : T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? T.accent.opacity(0.35) : T.border, lineWidth: 1))
        }
    }
}

private extension View {
    func fieldStyle(_ tokens: DesignTokens) -> some View {
        font(Typography.tesseraMono(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(tokens.inputBgSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tokens.border, lineWidth: 1))
    }
}
