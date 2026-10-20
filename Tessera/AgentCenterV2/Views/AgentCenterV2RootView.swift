import SwiftUI
import UIKit
import TesseraCore

/// Native V2 shell. The caller supplies the existing Tessera sidebar so this
/// feature does not recreate session/host navigation.
struct AgentCenterV2RootView<Sidebar: View>: View {
    @Bindable var model: AgentCenterV2PresentationModel
    @State private var compactPath: [AgentCenterV2NavigationRoute] = []
    @State private var isNarrowComposition = false
    private let sidebar: Sidebar
    private let includesNavigationSidebar: Bool
    private let onNarrowComposition: (Bool) -> Void

    init(
        model: AgentCenterV2PresentationModel,
        includesNavigationSidebar: Bool = true,
        onNarrowComposition: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder sidebar: () -> Sidebar
    ) {
        self.model = model
        self.includesNavigationSidebar = includesNavigationSidebar
        self.onNarrowComposition = onNarrowComposition
        self.sidebar = sidebar()
    }

    var body: some View {
        GeometryReader { proxy in
            // ContentView owns the app's existing session sidebar and makes
            // its stable, full-shell collapse decision before this view sees
            // its inset width. The embedded V2 surface therefore needs only
            // 300pt for the list plus a useful detail minimum; the standalone
            // fixture retains the full mockup's sidebar + list + detail gate.
            let twoColumnThreshold: CGFloat = includesNavigationSidebar ? 920 : 620
            let usesTwoColumns = proxy.size.width >= twoColumnThreshold
            Group {
            if usesTwoColumns {
                HStack(spacing: 0) {
                    if includesNavigationSidebar {
                        sidebar
                            .frame(width: 240)
                        Divider()
                    }
                    AgentThreadListView(model: model, isCompact: false)
                        .frame(width: 300)
                    Divider()
                    AgentThreadDetailView(model: model, isCompact: false)
                }
            } else {
                AgentCenterV2NarrowRootView(model: model, path: $compactPath)
            }
            }
            .onAppear {
                model.setThreadDetailVisible(usesTwoColumns || !compactPath.isEmpty)
                isNarrowComposition = !usesTwoColumns
                onNarrowComposition(!usesTwoColumns)
            }
            .onChange(of: usesTwoColumns) { _, wide in
                model.setThreadDetailVisible(wide || !compactPath.isEmpty)
                isNarrowComposition = !wide
                onNarrowComposition(!wide)
            }
            .onChange(of: compactPath) { _, path in
                model.setThreadDetailVisible(usesTwoColumns || !path.isEmpty)
            }
        }
        .onDisappear { model.setThreadDetailVisible(false) }
        .background(Color.clear)
        .sheet(item: $model.launchMode) { mode in
            AgentLaunchSheet(model: model, mode: mode, isCompact: isNarrowComposition)
        }
        .sheet(item: $model.promptOverflow) { overflow in
            AgentPromptOverflowSheet(model: model, overflow: overflow)
        }
        .sheet(item: $model.attachmentPickerRequest, onDismiss: { model.attachmentPickerDidDismiss() }) { request in
            Group {
                switch request.source {
                case .file:
                    AgentAttachmentDocumentPicker { urls in model.completeAttachments(request, urls: urls) }
                case .photo:
                    AgentAttachmentPhotoPicker(request: request,
                        onStartLoading: { cancel in model.beginLoadingAttachmentPhotos(request, onCancel: cancel) },
                        onCompletion: { result in
                            switch result {
                            case .success(let urls): model.completeAttachments(request, urls: urls)
                            case .failure(let error):
                                model.failPhotoAttachments(request, error: error)
                            }
                        })
                }
            }
            .overlay {
                if model.loadingAttachmentPhotos {
                    VStack(spacing: 12) {
                        ProgressView()
                        Button("Cancel", role: .cancel) { model.cancelLoadingAttachmentPhotos() }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("agent-center-v2-cancel-photo-load")
                    }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .alert(
            "Agent Center",
            isPresented: Binding(
                get: { model.capabilityNotice != nil },
                set: { if !$0 { model.capabilityNotice = nil } }
            )
        ) {
            if model.sendAnywayCandidate != nil {
                Button("Send anyway") { model.sendAnyway() }
                    .accessibilityIdentifier("agent-center-send-anyway")
            }
            Button("OK", role: .cancel) { model.capabilityNotice = nil }
        } message: {
            Text(model.capabilityNotice ?? "")
        }
        .background(AgentCenterV2KeyboardCommands(model: model))
        .overlay(alignment: .topLeading) {
            #if DEBUG
            // Keep the production-shell navigation contract on a distinct
            // inert element. Applying the identifier to this root container
            // would overwrite the identifiers of every descendant control.
            Text("agent center")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("agent-center-page")
            #endif
        }
    }
}

private struct AgentPromptOverflowSheet: View {
    @Bindable var model: AgentCenterV2PresentationModel
    let overflow: AgentCenterV2PresentationModel.PromptOverflow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var T

    var body: some View {
        NavigationStack {
            List(overflow.prompt.options.filter { $0.acceptsText != true }.dropFirst(3)) { option in
                Button(option.label) {
                    model.keyboardFocus = .action
                    model.onAction?(.answer(threadID: overflow.threadID, token: overflow.prompt.token, goal: .option(option.id)))
                    dismiss()
                }
                .frame(minHeight: 44)
                .disabled(model.answeringPromptThreads.contains(overflow.threadID))
            }
            .navigationTitle(overflow.prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(T.accent)
    }
}

/// Commands avoid the known `⌘W`, `⌃Tab`, and `⌘`-arrow collisions. Bare
/// prompt digits are mounted only while this surface owns the command scope.
private struct AgentCenterV2KeyboardCommands: View {
    @Bindable var model: AgentCenterV2PresentationModel

    var body: some View {
        Group {
            command("search agent threads", key: "f", modifiers: [.command]) {
                model.requestSearchFocus()
            }
            command("new agent", key: "n", modifiers: [.command]) {
                model.openLaunch(.spawn)
            }
            if model.allowsListNavigationShortcuts {
                command("previous agent thread", key: .upArrow, modifiers: []) {
                    model.selectAdjacentThread(offset: -1)
                }
                command("next agent thread", key: .downArrow, modifiers: []) {
                    model.selectAdjacentThread(offset: 1)
                }
            }
            if model.allowsPromptDigitShortcuts {
                command("answer default agent prompt", key: "1", modifiers: []) {
                    model.answerPromptOption(0)
                }
                command("answer agent prompt option 2", key: "2", modifiers: []) { model.answerPromptOption(1) }
                command("answer agent prompt option 3", key: "3", modifiers: []) { model.answerPromptOption(2) }
                command("answer agent prompt option 4", key: "4", modifiers: []) { model.answerPromptOption(3) }
                command("answer agent prompt option 5", key: "5", modifiers: []) { model.answerPromptOption(4) }
                command("answer agent prompt option 6", key: "6", modifiers: []) { model.answerPromptOption(5) }
                command("answer agent prompt option 7", key: "7", modifiers: []) { model.answerPromptOption(6) }
                command("answer agent prompt option 8", key: "8", modifiers: []) { model.answerPromptOption(7) }
                command("answer agent prompt option 9", key: "9", modifiers: []) { model.answerPromptOption(8) }
            }
            // The composer's text view owns ⌘Return and ⌃Return (send) while
            // it is focused; Return and ⇧Return stay newlines there.
            if model.keyboardFocus != .composer && model.keyboardFocus != .promptAnswer {
                command("open exact agent terminal", key: .return, modifiers: [.command]) {
                    if let id = model.selectedThreadID {
                        model.onAction?(.openTerminal(id))
                    } else if let id = model.selectedCandidateID {
                        model.onAction?(.openCandidateTerminal(id))
                    }
                }
            }
            if model.threadDetailVisible && (model.keyboardFocus == .composer || model.keyboardFocus == .action) {
                command("interrupt agent", key: .escape, modifiers: []) {
                    model.interruptSelectedThread()
                }
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func command(
        _ title: String,
        key: KeyEquivalent,
        modifiers: EventModifiers,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

private struct AgentCenterV2NarrowRootView: View {
    @Bindable var model: AgentCenterV2PresentationModel
    @Binding var path: [AgentCenterV2NavigationRoute]

    var body: some View {
        NavigationStack(path: $path) {
            AgentThreadListView(
                model: model,
                isCompact: true,
                onOpenThread: { id in path = [.thread(id)] },
                onOpenCandidate: { id in path = [.candidate(id)] }
            )
            .navigationDestination(for: AgentCenterV2NavigationRoute.self) { _ in
                AgentThreadDetailView(model: model, isCompact: true)
            }
        }
        .onAppear { openPendingNotificationThreadIfNeeded() }
        .onChange(of: model.pendingNarrowThreadNavigation) { _, _ in
            openPendingNotificationThreadIfNeeded()
        }
    }

    private func openPendingNotificationThreadIfNeeded() {
        guard let threadID = model.pendingNarrowThreadNavigation else { return }
        path = [.thread(threadID)]
        model.consumeNarrowThreadNavigation(threadID)
    }
}

private enum AgentCenterV2NavigationRoute: Hashable {
    case thread(AgentThreadID)
    case candidate(AgentSourceCandidateID)
}
