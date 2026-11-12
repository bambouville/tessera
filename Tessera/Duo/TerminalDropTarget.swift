import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TerminalDropDecision: Equatable {
    case none
    case text(String)
    case files([URL])
}

struct TerminalDropIdentity: Equatable {
    var sessionID: UUID
    var carrier: ObjectIdentifier
    var windowID: Int?
    var paneID: Int?
    var inputBox: ObjectIdentifier?
}

enum TerminalDropPayload {
    /// CRLF is one break; lone CR and LF each start a new line.
    /// The payload, including trailing empty lines, stays verbatim.
    static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                lines += 1
            } else if scalar == "\n", !previousWasCR {
                lines += 1
            }
            previousWasCR = scalar == "\r"
        }
        return lines
    }

    static func decision(texts: [String], files: [URL]) -> TerminalDropDecision {
        let localFiles = files.filter(\.isFileURL)
        if !localFiles.isEmpty { return .files(localFiles) }
        let text = texts.joined(separator: "\n")
        return text.isEmpty ? .none : .text(text)
    }

    static func isEnabled(connected: Bool, showsLaunchOverlay: Bool, authorityGated: Bool, isActive: Bool) -> Bool {
        isActive && connected && !showsLaunchOverlay && !authorityGated
    }

    @MainActor
    static func deliver(_ decision: TerminalDropDecision, isEnabled: Bool,
                        onText: (String) -> Void, onFiles: ([URL]) -> Void) -> Bool {
        guard isEnabled else { return false }
        switch decision {
        case .none: return false
        case .text(let text): onText(text)
        case .files(let files): onFiles(files)
        }
        return true
    }

    static func isFile(typeIdentifiers: [String]) -> Bool {
        if typeIdentifiers.contains(where: { UTType($0)?.conforms(to: .fileURL) == true }) { return true }
        // A file promise can have no URL. Plain text must not become an
        // upload of a synthesized file, even when it also offers data.
        return !typeIdentifiers.contains { UTType($0)?.conforms(to: .text) == true }
            && !typeIdentifiers.contains { UTType($0)?.conforms(to: .url) == true }
            && typeIdentifiers.contains { UTType($0)?.conforms(to: .data) == true }
    }
}

enum TerminalDropPreview: Equatable {
    case text(lines: Int?)
    case files

    var message: String {
        switch self {
        case .text(let lines):
            if let lines { return String(localized: "drop to paste · \(lines) lines") }
            return String(localized: "drop to paste")
        case .files: return String(localized: "Upload & paste path")
        }
    }
}

/// Copies are owned until handoff to the shipped Files pipeline. Cancellation
/// releases them immediately, even if a provider has not finished importing.
final class TerminalDropStaging: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var released = false

    init(stagedURL: URL) { self.url = stagedURL }

    static func copy(of source: URL) throws -> TerminalDropStaging {
        guard source.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        return TerminalDropStaging(stagedURL: try FilesPanelController.stageLocalCopy(of: source))
    }

    func take() -> URL {
        lock.lock()
        released = true
        lock.unlock()
        return url
    }

    func discard() {
        lock.lock()
        let shouldDelete = !released
        released = true
        lock.unlock()
        if shouldDelete { Self.discard([url]) }
    }

    /// Never remove a caller's original or a shared staging directory.
    static func discard(_ urls: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tessera-staging", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        for url in urls {
            let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            guard directory.deletingLastPathComponent().path == root.path,
                  UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit { discard() }
}

struct TerminalDropFile: Transferable {
    let staging: TerminalDropStaging

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            return TerminalDropFile(staging: try TerminalDropStaging.copy(of: url))
        }
        FileRepresentation(importedContentType: .item) { received in
            TerminalDropFile(staging: try TerminalDropStaging.copy(of: received.file))
        }
    }
}

private protocol TerminalDropRequest: AnyObject, Sendable {
    func cancel()
}

/// A provider can complete before returning Progress, or complete after cancel.
/// One lock owns the continuation in all three orders.
private final class TerminalDropLoad<Item>: TerminalDropRequest, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Item, Error>?
    private var progress: Progress?
    private var cancelled = false

    init(_ continuation: CheckedContinuation<Item, Error>) { self.continuation = continuation }

    func attach(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancelled
        if continuation != nil { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func complete(_ result: Result<Item, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        progress = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiting = continuation
        let pending = progress
        continuation = nil
        progress = nil
        lock.unlock()
        pending?.cancel()
        waiting?.resume(throwing: CancellationError())
    }
}

final class TerminalDropImportBatch: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var requests: [any TerminalDropRequest] = []
    private var staged: [TerminalDropStaging] = []

    func load<Item: Transferable>(_ type: Item.Type, from provider: NSItemProvider) async throws -> Item {
        try await load { completion in provider.loadTransferable(type: type, completionHandler: completion) }
    }

    func load<Item>(
        start: (@escaping @Sendable (Result<Item, Error>) -> Void) -> Progress
    ) async throws -> Item {
        try await withCheckedThrowingContinuation { continuation in
            let request = TerminalDropLoad(continuation)
            lock.lock()
            let shouldStart = !cancelled
            if shouldStart { requests.append(request) }
            lock.unlock()
            guard shouldStart else { request.cancel(); return }
            let progress = start { result in
                if case .success(let file as TerminalDropFile) = result {
                    self.retain(file.staging)
                }
                request.complete(result)
            }
            request.attach(progress)
        }
    }

    private func retain(_ copy: TerminalDropStaging) {
        lock.lock()
        let shouldDelete = cancelled
        if !shouldDelete { staged.append(copy) }
        lock.unlock()
        if shouldDelete { copy.discard() }
    }

    func takeFiles() -> [URL]? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        let urls = staged.map { $0.take() }
        staged.removeAll()
        return urls
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = requests
        let copies = staged
        requests.removeAll()
        staged.removeAll()
        lock.unlock()
        copies.forEach { $0.discard() }
        pending.forEach { $0.cancel() }
    }

    deinit { cancel() }
}

@MainActor
final class TerminalDropLifetime {
    enum Delivery: Equatable { case ready, invalidated, paneChanged }
    private var target: TerminalDropIdentity?
    private var isEnabled = false
    private var batches: [UUID: (batch: TerminalDropImportBatch, files: Bool)] = [:]

    /// Returns whether a pending text drop was refused because its pane changed.
    @discardableResult
    func update(isEnabled: Bool, target: TerminalDropIdentity) -> Bool {
        let changed = self.target != nil && self.target != target
        let refusedText = isEnabled && changed && batches.values.contains { !$0.files }
        if !isEnabled {
            invalidate()
        } else if changed {
            let textImports = batches.values.filter { !$0.files }.map(\.batch)
            for batch in textImports { finish(batch) }
        }
        self.isEnabled = isEnabled
        self.target = target
        return refusedText
    }

    func begin(files: Bool) -> TerminalDropImportBatch? {
        guard isEnabled else { return nil }
        let batch = TerminalDropImportBatch()
        batches[batch.id] = (batch, files)
        return batch
    }

    func accepts(_ batch: TerminalDropImportBatch, target: TerminalDropIdentity) -> Bool {
        guard isEnabled, let pending = batches[batch.id] else { return false }
        return pending.files || self.target == target
    }

    func delivery(
        _ batch: TerminalDropImportBatch, acceptedTarget: TerminalDropIdentity,
        currentTarget: TerminalDropIdentity
    ) -> Delivery {
        guard accepts(batch, target: acceptedTarget) else { return .invalidated }
        // Files keep the shipped temp-upload/path-injection behavior. Only
        // text promises are tied to the pane that accepted them.
        if batches[batch.id]?.files == true { return .ready }
        return currentTarget == acceptedTarget ? .ready : .paneChanged
    }

    func finish(_ batch: TerminalDropImportBatch) {
        batches.removeValue(forKey: batch.id)
        batch.cancel()
    }

    func invalidate() {
        let pending = batches.values.map(\.batch)
        batches.removeAll()
        pending.forEach { $0.cancel() }
    }
}

extension View {
    /// onText owns one mode-aware paste and input-mirror reset. onFiles takes
    /// staged copies through FilesPanelController.handleTerminalDrop's shared queue.
    func terminalDropTarget(
        isEnabled: Bool, target: @escaping () -> TerminalDropIdentity, failureMessage: Binding<String?>,
        onText: @escaping (String) -> Void, onFiles: @escaping ([URL]) -> Void
    ) -> some View {
        modifier(TerminalDropTargetModifier(
            isEnabled: isEnabled, target: target, failureMessage: failureMessage,
            onText: onText, onFiles: onFiles
        ))
    }
}

private struct TerminalDropTargetModifier: ViewModifier {
    @Environment(\.designTokens) private var T
    @Environment(\.displayScale) private var displayScale
    @State private var preview: TerminalDropPreview?
    @State private var lifetime = TerminalDropLifetime()

    let isEnabled: Bool
    let target: () -> TerminalDropIdentity
    @Binding var failureMessage: String?
    let onText: (String) -> Void
    let onFiles: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .text, .data], delegate: TerminalPayloadDropDelegate(
                isEnabled: isEnabled, preview: $preview, perform: receive
            ))
            .overlay(alignment: .top) {
                if isEnabled, let preview {
                    if preview == .files {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.up.doc")
                                .font(.system(size: 12, weight: .light))
                                .foregroundStyle(T.accent)
                            Text(verbatim: preview.message)
                                .font(Typography.tesseraMono(size: 11.5))
                                .foregroundStyle(T.fg)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(T.bg.opacity(0.92), in: Capsule())
                        .overlay(Capsule().stroke(T.accent, lineWidth: 1))
                        .frame(maxWidth: 420)
                        .padding(.top, 54)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("terminal-drop-highlight")
                    } else {
                        Text(verbatim: preview.message)
                            .font(Typography.tesseraMono(size: 12, weight: .medium))
                            .foregroundStyle(T.fg)
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(T.panelBg.opacity(0.65))
                            .background(.regularMaterial)
                            .overlay { Rectangle().stroke(T.borderStrong, lineWidth: 1 / displayScale) }
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("terminal-drop-highlight")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
            }
            .onChange(of: preview) { _, value in
                if let value { announce(value.message) }
            }
            .onChange(of: isEnabled, initial: true) { _, _ in updateLifetime() }
            .onChange(of: target()) { _, _ in updateLifetime() }
            .onDisappear {
                lifetime.invalidate()
                preview = nil
                failureMessage = nil
            }
    }

    private func updateLifetime() {
        preview = nil
        if lifetime.update(isEnabled: isEnabled, target: target()) {
            reportFailure(String(localized: "the pane changed; drop again"))
        } else if !isEnabled {
            failureMessage = nil
        }
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func reportFailure(_ message: String) {
        failureMessage = message
        DiagnosticLogStore.appendApp("terminal-drop failed: \(message)")
    }

    private func receive(_ providers: [NSItemProvider], files: Bool) {
        updateLifetime()
        failureMessage = nil
        guard let batch = lifetime.begin(files: files) else { return }
        let acceptedTarget = target()
        Task { @MainActor in
            defer { lifetime.finish(batch) }
            do {
                if files {
                    var unreadable = 0
                    for provider in providers {
                        do {
                            _ = try await batch.load(TerminalDropFile.self, from: provider)
                        } catch {
                            guard lifetime.accepts(batch, target: acceptedTarget) else { return }
                            unreadable += 1
                        }
                    }
                    guard canDeliver(batch, acceptedTarget: acceptedTarget, files: true),
                          let urls = batch.takeFiles() else { return }
                    if !urls.isEmpty {
                        _ = TerminalDropPayload.deliver(.files(urls), isEnabled: true, onText: onText, onFiles: onFiles)
                    }
                    if unreadable > 0 { reportFailure(String(localized: "Couldn't read \(unreadable) dropped files.")) }
                } else {
                    var texts: [String] = []
                    for provider in providers { texts.append(try await batch.load(String.self, from: provider)) }
                    guard canDeliver(batch, acceptedTarget: acceptedTarget, files: false) else { return }
                    let decision = TerminalDropPayload.decision(texts: texts, files: [])
                    if case .text(let text) = decision {
                        announce(TerminalDropPreview.text(lines: TerminalDropPayload.lineCount(in: text)).message)
                    }
                    _ = TerminalDropPayload.deliver(decision, isEnabled: true, onText: onText, onFiles: onFiles)
                }
            } catch {
                guard canDeliver(batch, acceptedTarget: acceptedTarget, files: files) else { return }
                reportFailure(String(localized: "could not read dropped item"))
            }
        }
    }

    private func canDeliver(
        _ batch: TerminalDropImportBatch, acceptedTarget: TerminalDropIdentity, files: Bool
    ) -> Bool {
        // Read the carrier now, too: a provider can finish before SwiftUI has
        // delivered the pane change to onChange.
        switch lifetime.delivery(batch, acceptedTarget: acceptedTarget, currentTarget: target()) {
        case .ready: return true
        case .invalidated: return false
        case .paneChanged:
            if !files { reportFailure(String(localized: "the pane changed; drop again")) }
            return false
        }
    }
}

private struct TerminalPayloadDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var preview: TerminalDropPreview?
    let perform: ([NSItemProvider], Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.fileURL, .text, .data])
    }

    func dropEntered(info: DropInfo) { updatePreview(info: info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isEnabled else { preview = nil; return DropProposal(operation: .forbidden) }
        updatePreview(info: info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { preview = nil }

    func performDrop(info: DropInfo) -> Bool {
        preview = nil
        guard isEnabled else { return false }
        let providers = eligibleProviders(info: info)
        let files = providers.filter { TerminalDropPayload.isFile(typeIdentifiers: $0.registeredTypeIdentifiers) }
        if !files.isEmpty {
            perform(files, true)
        } else {
            let texts = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.text.identifier) }
            guard !texts.isEmpty else { return false }
            perform(texts, false)
        }
        return true
    }

    private func eligibleProviders(info: DropInfo) -> [NSItemProvider] {
        info.itemProviders(for: [.fileURL, .text, .data]).filter {
            !$0.hasItemConformingToTypeIdentifier(RemoteFileItemProvider.localDragMarkerTypeIdentifier)
        }
    }

    private func updatePreview(info: DropInfo) {
        guard isEnabled else { preview = nil; return }
        let providers = eligibleProviders(info: info)
        guard !providers.isEmpty else { preview = nil; return }
        preview = providers.contains { TerminalDropPayload.isFile(typeIdentifiers: $0.registeredTypeIdentifiers) }
            ? .files : .text(lines: nil)
    }
}
