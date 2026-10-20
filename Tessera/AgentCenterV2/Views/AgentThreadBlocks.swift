import Foundation
import SwiftUI
import TesseraCore
import UIKit

enum AgentTranscriptTypography {
    static func proseSize(isPhone: Bool) -> CGFloat { isPhone ? 15.5 : 14 }
}

struct AgentMessageView: View, Equatable {
    let message: AgentMessage
    @Bindable var model: AgentCenterV2PresentationModel
    let promptActionsAvailable: Bool
    let isCompact: Bool

    /// Unchanged rows skip body evaluation when the transcript re-renders
    /// for scroll position, paging or a newer row elsewhere.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.model === rhs.model &&
            lhs.promptActionsAvailable == rhs.promptActionsAvailable && lhs.isCompact == rhs.isCompact
    }
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var promptDetailExpanded = false
    @State private var promptTextOpen = false
    @State private var promptText = ""
    @FocusState private var promptTextFocused: Bool

    private var isPhone: Bool { CompactLayout.isPhone(horizontalSizeClass) }

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { pair in
                blockView(pair.element)
            }
            if let time = message.displayTime {
                Text(time, style: .time)
                    .font(Typography.tesseraMono(size: 9))
                    .foregroundStyle(T.fgFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AgentBlock) -> some View {
        switch block {
        case .text(let text):
            proseBlock(text)
        case .thinking(let text):
            DisclosureGroup {
                AgentMarkdownText(source: text, isPhone: isPhone)
                    .foregroundStyle(T.fgDim)
                    .textSelection(.enabled)
                    .padding(.top, 5)
            } label: {
                Text("thinking · tap to expand")
                    .font(Typography.tesseraMono(size: isPhone ? 13 : 11.5))
                    .foregroundStyle(T.fgFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        case .toolCall(let name, let preview):
            AgentToolCard(icon: "wrench.adjustable", title: name, preview: preview)
        case .toolResult(let preview, let truncated):
            AgentToolCard(icon: "terminal", title: truncated ? "result · truncated" : "result", preview: preview)
        case .edit(let path, let diff):
            AgentEditCard(path: path, diff: diff)
        case .permission(let title), .question(let title):
            passivePrompt(title)
        case .queuedMessage(let text):
            Text(text)
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
                .padding(10)
                .background(T.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.amber.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        case .workflow(let title):
            labeledCard(icon: "checklist", title: "workflow", detail: title)
        case .subagent(let id, let type):
            labeledCard(icon: "point.3.connected.trianglepath.dotted", title: type ?? "subagent", detail: id)
        case .compactSummary(let text):
            DisclosureGroup {
                AgentMarkdownText(source: text, isPhone: isPhone)
                    .foregroundStyle(T.fgDim)
                    .textSelection(.enabled)
                    .padding(.top, 5)
            } label: {
                Text("context compacted · tap to expand")
                    .font(Typography.tesseraMono(size: isPhone ? 13 : 11.5))
                    .foregroundStyle(T.fgFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(T.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        case .systemEvent(let detail):
            Text(detail)
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgFaint)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(T.border).frame(width: 2) }
        case .completion(let detail):
            HStack(spacing: 9) {
                Image(systemName: "checkmark").foregroundStyle(T.green)
                Text(detail ?? "finished").foregroundStyle(T.fgMuted)
            }
            .font(Typography.tesseraMono(size: 11))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.green.opacity(0.28), lineWidth: 1))
        case .attachment(let name, let mediaType):
            labeledCard(icon: "paperclip", title: mediaType ?? "attachment", detail: name)
        case .actionPrompt(let prompt):
            actionPrompt(prompt)
        case .workflowTasks(let tasks):
            AgentWorkflowTasksView(tasks: tasks)
        case .subagentGroup(let subagents):
            AgentSubagentGroupView(subagents: subagents, onOpen: { model.select($0) })
        case .unknown(let type):
            labeledCard(icon: "questionmark.circle", title: "unsupported event", detail: type)
        }
    }

    @ViewBuilder
    private func proseBlock(_ text: String) -> some View {
        let prose = AgentMarkdownText(source: text, isPhone: isPhone)
            .foregroundStyle(T.fg)
            .lineSpacing(3)
            .textSelection(.enabled)

        if message.role == .user {
            prose
                .padding(11)
                .background(T.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(T.accent.opacity(0.35), lineWidth: 1)
                }
                // Five relative columns preserve the mockup's 80% bubble cap
                // on phone widths without measuring geometry. iPad bubbles
                // retain the established 520pt conversational maximum.
                .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                    min(width * 0.8, 520)
                }
        } else {
            prose.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func passivePrompt(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised").foregroundStyle(T.amber)
            Text(title).foregroundStyle(T.fgMuted)
        }
        .font(Typography.tesseraMono(size: 11))
        .padding(11)
        .background(T.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.amber.opacity(0.3), lineWidth: 1))
    }

    private func actionPrompt(_ prompt: AgentActionPrompt) -> some View {
        let vertical = prompt.kind.map { [AgentPromptKind.question, .multiSelect, .review].contains($0) } == true
            || prompt.options.contains { $0.detail != nil }
        let available = promptActionsAvailable && !(model.selectedThreadID.map { model.answeringPromptThreads.contains($0) } ?? false)
        return VStack(alignment: .leading, spacing: 10) {
            if prompt.kind == .deferred {
                // Collapsed async questions: the count is the whole message.
                Group {
                    if prompt.pendingCount == 1 { Text("1 question waiting") }
                    else { Text("\(prompt.pendingCount ?? 0) questions waiting") }
                }
                .font(Typography.tesseraMono(size: 11, weight: .medium))
                .foregroundStyle(T.fg)
                Text("Codex keeps working while they wait")
                    .font(Typography.tesseraMono(size: 10)).foregroundStyle(T.fgDim)
            } else {
                Text(prompt.title)
                    .font(Typography.tesseraMono(size: 11, weight: .medium))
                    .foregroundStyle(T.fg)
                if let progress = prompt.progress {
                    Text(progress).font(Typography.tesseraMono(size: 10)).foregroundStyle(T.fgDim)
                }
                if let question = prompt.question {
                    Text(question).font(Typography.tesseraMono(size: 11, weight: .medium)).foregroundStyle(T.fg)
                }
            }
            if prompt.isBlocking == false && prompt.kind != nil && ![.permission, .deferred].contains(prompt.kind) {
                Text("The agent keeps working while this waits")
                    .font(Typography.tesseraMono(size: 10)).foregroundStyle(T.fgDim)
            }
            if let detail = prompt.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text(detail)
                        .font(Typography.tesseraMono(size: 10.5))
                        .foregroundStyle(T.fgMuted)
                        .lineLimit(promptDetailExpanded ? nil : 8)
                        .textSelection(.enabled)
                    if detail.components(separatedBy: "\n").count > 8 || detail.count > 240 {
                        Button(promptDetailExpanded ? "less" : "more") { promptDetailExpanded.toggle() }
                            .font(Typography.tesseraMono(size: 10))
                            .frame(minHeight: isCompact ? 44 : 38)
                    }
                }
                .padding(9)
                .background(T.bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let entry = prompt.entry, !entry.text.isEmpty {
                Text("In the terminal: \(entry.text)")
                    .font(Typography.tesseraMono(size: 10)).foregroundStyle(T.fgDim).lineLimit(1)
            }
            if !promptActionsAvailable {
                Text("Open Terminal to answer after the live agent binding is verified.")
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgDim)
            }
            if vertical {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(prompt.options) { option in promptOption(option, prompt: prompt, available: available, vertical: true) }
                }
            } else {
                AgentCenterV2FlowLayout(spacing: 7) {
                    ForEach(prompt.options) { option in promptOption(option, prompt: prompt, available: available, vertical: false) }
                }
            }
            if promptTextOpen || prompt.kind == .textEntry && prompt.options.isEmpty {
                HStack(spacing: 7) {
                    TextField("Your answer", text: $promptText)
                        .focused($promptTextFocused)
                        .textFieldStyle(.plain)
                        .font(Typography.tesseraMono(size: 11))
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                        .accessibilityIdentifier("agent-center-v2-answer-text")
                        .disabled(!available)
                        .onSubmit { sendPromptText(prompt, available: available) }
                    Button("Send") { sendPromptText(prompt, available: available) }
                        .font(Typography.tesseraMono(size: 10.5, weight: .medium))
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!available || AgentPromptAnswerPlanner.sanitizedText(promptText).isEmpty)
                        .accessibilityIdentifier("agent-center-v2-answer-send")
                }
                .onChange(of: promptTextFocused) { _, focused in
                    if focused { model.keyboardFocus = .promptAnswer }
                    else if model.keyboardFocus == .promptAnswer {
                        model.keyboardFocus = .none
                        model.updatePromptKeyboardFocus()
                    }
                }
            }
            if let controls = prompt.controls {
                HStack(spacing: 7) {
                    ForEach(controls, id: \.kind) { control in
                        Button {
                            answer(prompt, goal: .control(control.kind))
                        } label: {
                            Text(Self.controlLabel(control.kind))
                                .font(Typography.tesseraMono(size: 10.5, weight: control.kind == .open ? .medium : .regular))
                                .foregroundStyle(control.kind == .cancel ? T.fgDim : T.fg)
                                .frame(minWidth: 44, minHeight: isCompact ? 44 : 38)
                                .padding(.horizontal, 8)
                                .background(control.kind == .open ? T.accentSoft : T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.border, lineWidth: 1))
                        }
                        .disabled(!available)
                        .accessibilityIdentifier("agent-center-v2-answer-control-\(control.kind.rawValue)")
                    }
                }
            }
        }
        .padding(12)
        .background(T.inputBgSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(T.border, lineWidth: 1))
        .onChange(of: prompt.token.rawValue) { _, _ in
            promptText = ""
            promptTextOpen = false
            promptTextFocused = false
            promptDetailExpanded = false
        }
    }

    @ViewBuilder
    private func promptOption(_ option: TesseraCore.AgentPromptOption, prompt: AgentActionPrompt,
                              available: Bool, vertical: Bool) -> some View {
        Button {
            if option.acceptsText == true {
                promptText = ""
                promptTextOpen = true
                promptTextFocused = true
            } else {
                answer(prompt, goal: .option(option.id))
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                if prompt.kind == .multiSelect {
                    Image(systemName: option.isChecked == true ? "checkmark.square" : "square")
                        .foregroundStyle(T.fgMuted)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.role == .chat ? "Chat about this" : option.label)
                        .font(Typography.tesseraMono(size: 10.5, weight: option.isDefault ? .medium : .regular))
                        .foregroundStyle(option.role == .chat ? T.fgDim : option.isDefault ? T.fg : T.fgMuted)
                    if let detail = option.detail {
                        Text(detail).font(Typography.tesseraMono(size: 10)).foregroundStyle(T.fgDim)
                    }
                }
                if vertical { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: vertical ? .infinity : nil, minHeight: isCompact ? 44 : 38, alignment: .leading)
            .background(option.isDefault ? T.accentSoft : T.inputBgSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(option.isDefault ? T.accent.opacity(0.35) : T.border, lineWidth: 1))
        }
        .accessibilityIdentifier("agent-center-v2-answer-\(option.id)")
        .accessibilityLabel("answer \(option.label)")
        .disabled(!available)
    }

    private static func controlLabel(_ kind: AgentPromptControlKind) -> LocalizedStringKey {
        switch kind {
        case .open: "Answer"
        case .next: "Next"
        case .skip: "Skip"
        case .cancel: "Cancel"
        }
    }

    private func answer(_ prompt: AgentActionPrompt, goal: AgentPromptAnswerGoal) {
        model.keyboardFocus = .action
        guard let threadID = model.selectedThreadID else { return }
        model.onAction?(.answer(threadID: threadID, token: prompt.token, goal: goal))
    }

    private func sendPromptText(_ prompt: AgentActionPrompt, available: Bool) {
        guard available, !AgentPromptAnswerPlanner.sanitizedText(promptText).isEmpty else { return }
        answer(prompt, goal: .text(promptText))
        promptTextFocused = false
    }

    private func labeledCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon).foregroundStyle(T.accent)
            Text(title).foregroundStyle(T.fgMuted)
            Text(detail).foregroundStyle(T.fgDim).lineLimit(1)
        }
        .font(Typography.tesseraMono(size: 10.5))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

/// Shared Core owns parsing and sanitisation. This view only maps its typed
/// document tree to native SwiftUI, so terminal output and tool cards cannot
/// accidentally acquire Markdown interpretation on the Apple surface.
private struct AgentMarkdownText: View {
    let document: AgentMarkdownDocument
    let isPhone: Bool
    @Environment(\.designTokens) private var T

    init(source: String, isPhone: Bool) {
        let started = Date()
        document = AgentMarkdownDocument.parse(source)
        self.isPhone = isPhone
        AgentCenterV2PerformanceDiagnostics.shared.record("markdownParseSync", since: started)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, node in
                block(node)
            }
            if document.truncated { Text("…").foregroundStyle(T.fgDim) }
        }
    }

    // Erase at the recursive boundary. Otherwise the opaque type contains
    // itself through nested lists/quotes and the SwiftUI type checker stalls.
    private func block(_ node: AgentMarkdownNode) -> AnyView {
        AnyView(blockContent(node))
    }

    @ViewBuilder
    private func blockContent(_ node: AgentMarkdownNode) -> some View {
        switch node.kind {
        case .paragraph:
            inlineText(node.children)
                .tesseraSansScaled(size: AgentTranscriptTypography.proseSize(isPhone: isPhone), relativeTo: .body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .heading:
            inlineText(node.children)
                .tesseraSansScaled(size: headingSize(node.level), relativeTo: headingTextStyle(node.level))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .quote:
            VStack(alignment: .leading, spacing: 7) { blocks(node.children) }
            .padding(.leading, 11)
            .overlay(alignment: .leading) { Rectangle().fill(T.border).frame(width: 2) }
            .foregroundStyle(T.fgMuted)
        case .unorderedList:
            list(node, ordered: false)
        case .orderedList:
            list(node, ordered: true)
        case .listItem:
            listItem(node, marker: "•")
        case .codeBlock:
            codeBlock(node)
        case .thematicBreak:
            Rectangle().fill(T.border).frame(height: 1).padding(.vertical, 4)
        case .table:
            table(node)
        case .tableRow, .tableCell:
            inlineText(node.children)
                .tesseraSansScaled(size: AgentTranscriptTypography.proseSize(isPhone: isPhone), relativeTo: .body)
        case .text, .strong, .emphasis, .strikethrough, .inlineCode, .link,
             .softBreak, .lineBreak, .image:
            inlineText([node])
                .tesseraSansScaled(size: AgentTranscriptTypography.proseSize(isPhone: isPhone), relativeTo: .body)
        }
    }

    @ViewBuilder
    private func blocks(_ nodes: [AgentMarkdownNode]) -> some View {
        ForEach(Array(nodes.enumerated()), id: \.offset) { _, child in
            block(child)
        }
    }

    private func list(_ node: AgentMarkdownNode, ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { index, child in
                listItem(
                    child,
                    marker: ordered ? "\((node.start ?? 1) + index)." : "•"
                )
            }
        }
    }

    private func listItem(_ node: AgentMarkdownNode, marker: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(node.checked.map { $0 ? "☑" : "☐" } ?? marker)
                .font(Typography.tesseraMono(size: isPhone ? 13 : 11.5))
                .foregroundStyle(node.checked == true ? T.green : T.fgDim)
                .frame(minWidth: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                blocks(node.children)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(_ node: AgentMarkdownNode) -> some View {
        let source = node.text ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let language = node.language, !language.isEmpty {
                    Text(language)
                        .font(Typography.tesseraMono(size: isPhone ? 10.5 : 9.5, weight: .medium))
                        .foregroundStyle(T.fgDim)
                }
                Spacer()
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": source]], options: [.localOnly: true])
                } label: {
                    Label("copy", systemImage: "doc.on.doc")
                }
                .font(Typography.tesseraMono(size: isPhone ? 10.5 : 9.5))
                .foregroundStyle(T.fgMuted)
                .accessibilityLabel("Copy code")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(Typography.tesseraMono(size: isPhone ? 13 : 12))
                    .foregroundStyle(T.fg)
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border, lineWidth: 1))
    }

    private func table(_ node: AgentMarkdownNode) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, row in
                    GridRow(alignment: .top) {
                        ForEach(Array(row.children.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell.children)
                                .tesseraSansScaled(size: isPhone ? 14 : 12.5, relativeTo: .body)
                                .fontWeight(cell.level == 1 ? .semibold : .regular)
                                .frame(minWidth: isPhone ? 120 : 140, alignment: cellAlignment(cell.alignment))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .overlay(alignment: .trailing) { Rectangle().fill(T.border).frame(width: 1) }
                        }
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
                }
            }
            .background(T.inputBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(T.border, lineWidth: 1))
    }

    private func inlineText(_ nodes: [AgentMarkdownNode]) -> Text {
        Text(inlineAttributed(nodes))
    }

    private func inlineAttributed(_ nodes: [AgentMarkdownNode]) -> AttributedString {
        let started = Date()
        defer { AgentCenterV2PerformanceDiagnostics.shared.record("nativeTextSync", since: started) }
        return nodes.reduce(into: AttributedString()) { result, node in
            result += inlineAttributed(node)
        }
    }

    private func inlineAttributed(_ node: AgentMarkdownNode) -> AttributedString {
        switch node.kind {
        case .text:
            return AttributedString(node.text ?? "")
        case .softBreak:
            return AttributedString(" ")
        case .lineBreak:
            return AttributedString("\n")
        case .image:
            guard !node.children.isEmpty else { return AttributedString("[image: image]") }
            return AttributedString("[image: ") + inlineAttributed(node.children) + AttributedString("]")
        case .strong, .emphasis, .strikethrough, .inlineCode, .link:
            var content = node.kind == .inlineCode
                ? AttributedString(node.text ?? "")
                : inlineAttributed(node.children)
            switch node.kind {
            case .strong, .emphasis, .strikethrough:
                let intent: InlinePresentationIntent = node.kind == .strong ? .stronglyEmphasized : node.kind == .emphasis ? .emphasized : .strikethrough
                for run in Array(content.runs) {
                    content[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
                }
            case .inlineCode:
                content.inlinePresentationIntent = .code
                content.font = .system(size: isPhone ? 14 : 12.5, design: .monospaced)
            case .link:
                if let url = sanitizedURL(node.destination) { content.link = url }
            default: break
            }
            return content
        case .paragraph, .heading, .quote, .unorderedList, .orderedList,
             .listItem, .codeBlock, .thematicBreak, .table, .tableRow, .tableCell:
            return inlineAttributed(node.children)
        }
    }

    private func headingSize(_ level: Int?) -> CGFloat {
        switch level ?? 1 {
        case 1: isPhone ? 22 : 20
        case 2: isPhone ? 19 : 17.5
        case 3: isPhone ? 17 : 15.5
        default: isPhone ? 16 : 14.5
        }
    }

    private func headingTextStyle(_ level: Int?) -> UIFont.TextStyle {
        switch level ?? 1 {
        case 1: .title3
        case 2: .headline
        default: .body
        }
    }

    private func cellAlignment(_ alignment: String?) -> Alignment {
        switch alignment {
        case "center": .center
        case "right": .trailing
        default: .leading
        }
    }

    private func sanitizedURL(_ destination: String?) -> URL? {
        guard let destination,
              let url = URL(string: destination),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }
}

struct AgentToolRunView: View, Equatable {
    let run: AgentToolRun
    let expanded: Bool
    let onToggle: () -> Void
    @Environment(\.designTokens) private var T

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.run == rhs.run && lhs.expanded == rhs.expanded
    }

    var body: some View {
        Button { onToggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(T.fgDim)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.summaryTitle).foregroundStyle(T.fg)
                    if let latest = run.latestSummary {
                        Text(latest).foregroundStyle(T.fgMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(T.fgMuted)
            }
            .font(Typography.tesseraMono(size: 10.5))
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityIdentifier("agent-tool-run-\(run.id)")
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

private struct AgentToolCard: View {
    let icon: String
    let title: String
    let preview: String
    @State private var expanded = false
    @Environment(\.designTokens) private var T

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(preview)
                .font(Typography.tesseraMono(size: 10.5))
                .foregroundStyle(T.fgMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 14).foregroundStyle(T.fgDim)
                Text(title).foregroundStyle(T.fgMuted)
                Text(preview).foregroundStyle(T.fg).lineLimit(1)
            }
            .font(Typography.tesseraMono(size: 10.5))
        }
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

private struct AgentEditCard: View {
    let path: String?
    let diff: String?
    @State private var expanded = false
    @Environment(\.designTokens) private var T

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let diff {
                Text(diff)
                    .font(Typography.tesseraMono(size: 10))
                    .foregroundStyle(T.fgMuted)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "pencil.line").foregroundStyle(T.accent)
                Text(path ?? "edit").foregroundStyle(T.fgMuted).lineLimit(1)
                Spacer()
                Text(diff == nil ? "summary" : "diff").foregroundStyle(T.fgFaint)
            }
            .font(Typography.tesseraMono(size: 10.5))
        }
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

private struct AgentWorkflowTasksView: View {
    let tasks: [AgentWorkflowTask]
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("workflow"); Spacer(); Text("\(tasks.filter { $0.state == .completed }.count) of \(tasks.count)") }
                .font(Typography.tesseraMono(size: 10))
                .foregroundStyle(T.fgDim)
                .padding(10)
                .overlay(alignment: .bottom) { Rectangle().fill(T.border).frame(height: 1) }
            ForEach(tasks) { task in
                HStack(spacing: 9) {
                    Image(systemName: task.state == .completed ? "checkmark.square.fill" : task.state == .working ? "circle.dotted" : "square")
                        .foregroundStyle(task.state == .completed ? T.green : task.state == .working ? T.amber : T.fgDim)
                    Text(task.title).foregroundStyle(task.state == .completed ? T.fgDim : T.fgMuted)
                    Spacer()
                    if let owner = task.owner { Text(owner).foregroundStyle(T.fgFaint) }
                }
                .font(Typography.tesseraMono(size: 10.5))
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}

private struct AgentSubagentGroupView: View {
    let subagents: [AgentSubagentSummary]
    let onOpen: (AgentThreadID) -> Void
    @Environment(\.designTokens) private var T
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        DisclosureGroup("subagents · \(subagents.count)") {
            ForEach(subagents) { subagent in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Circle().fill(color(for: subagent)).frame(width: 6, height: 6)
                        Text(subagent.type ?? subagent.id).foregroundStyle(T.fgMuted)
                        Spacer()
                        if let threadID = subagent.threadID {
                            Button("open") { onOpen(threadID) }.foregroundStyle(T.accent)
                        }
                    }
                    if let summary = subagent.summary {
                        AgentMarkdownText(source: summary, isPhone: CompactLayout.isPhone(horizontalSizeClass))
                            .foregroundStyle(T.fgDim)
                            .textSelection(.enabled)
                    }
                }
                .font(Typography.tesseraMono(size: 10.5))
                .padding(.top, 7)
            }
        }
        .font(Typography.tesseraMono(size: 10.5))
        .foregroundStyle(T.fgMuted)
        .padding(10)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(T.border, lineWidth: 1))
    }

    private func color(for subagent: AgentSubagentSummary) -> Color {
        switch subagent.status {
        case .working, .finished: return T.green
        case .waitingForInput: return T.amber
        case .idle, .unavailable: return T.fgFaint
        }
    }
}

struct AgentChangesView: View {
    let changes: AgentChangeSummary
    @Environment(\.designTokens) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text("\(changes.edits.count) files").foregroundStyle(T.fgMuted)
                if let added = changes.authoritativeTotals.linesAdded { Text("+\(added)").foregroundStyle(T.green) }
                if let removed = changes.authoritativeTotals.linesRemoved { Text("−\(removed)").foregroundStyle(T.red) }
                Spacer()
                Text("provider totals").foregroundStyle(T.fgFaint)
            }
            .font(Typography.tesseraMono(size: 10.5))
            if changes.edits.isEmpty {
                Text("no file changes in this thread yet.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
            } else {
                ForEach(changes.edits) { edit in
                    AgentEditCard(path: edit.path, diff: edit.diff)
                }
            }
        }
        .padding(12)
        .background(T.inputBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(T.border, lineWidth: 1))
    }
}
