import Foundation
import ImageIO
import UniformTypeIdentifiers
import TesseraCore

/// Native ingress is device-local. Every asynchronous step retains the exact
/// conversation, carrier and registration captured before opening the picker.
@MainActor
final class AgentComposerAttachments {
    struct Target {
        let threadID: AgentThreadID
        let binding: AgentTerminalBinding
        let registrationID: UUID
        let generation: UInt64
    }

    private let model: AgentCenterV2PresentationModel
    private let targetFor: (AgentThreadSnapshot) -> Target?
    private let isCurrent: (Target) -> Bool
    private let upload: (AgentTerminalBinding, URL) async throws -> String
    private var selections: [UUID: Target] = [:]
    private var tasks: [AgentThreadID: (id: UUID, task: Task<Void, Never>)] = [:]

    init(
        model: AgentCenterV2PresentationModel,
        targetFor: @escaping (AgentThreadSnapshot) -> Target?,
        isCurrent: @escaping (Target) -> Bool,
        upload: @escaping (AgentTerminalBinding, URL) async throws -> String
    ) {
        self.model = model
        self.targetFor = targetFor
        self.isCurrent = isCurrent
        self.upload = upload
        model.onPrepareAttachments = { [weak self] thread in self?.prepare(thread) }
        model.onCompleteAttachments = { [weak self] request, urls in self?.complete(request, urls: urls) }
    }

    private func prepare(_ thread: AgentThreadSnapshot) -> AgentCenterV2PresentationModel.AttachmentPickerRequest? {
        guard tasks[thread.summary.id] == nil, let target = targetFor(thread), isCurrent(target) else { return nil }
        let request = AgentCenterV2PresentationModel.AttachmentPickerRequest(id: UUID(), threadID: thread.summary.id)
        selections[request.id] = target
        return request
    }

    private func complete(_ request: AgentCenterV2PresentationModel.AttachmentPickerRequest, urls: [URL]) {
        // Delegate completion and interactive sheet dismissal can both arrive.
        guard let target = selections.removeValue(forKey: request.id), !urls.isEmpty else {
            if tasks[request.threadID]?.id != request.id { removePhotoCopies(for: request) }
            return
        }
        guard isCurrent(target), tasks[target.threadID] == nil else {
            removePhotoCopies(for: request)
            model.reportUnavailable("Attachment cancelled: the original terminal changed.")
            return
        }
        model.uploadingThreads.insert(target.threadID)
        let task = Task { [self] in
            defer {
                removePhotoCopies(for: request)
                if tasks[target.threadID]?.id == request.id {
                    tasks.removeValue(forKey: target.threadID)
                    model.uploadingThreads.remove(target.threadID)
                }
            }
            for url in urls {
                do {
                    try Task.checkCancellation()
                    guard isCurrent(target) else {
                        model.reportUnavailable("Upload stopped: the original terminal changed.")
                        return
                    }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let staged = try await Task.detached { try FilesPanelController.stageLocalCopy(of: url) }.value
                    defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
                    try Task.checkCancellation()
                    guard isCurrent(target) else {
                        model.reportUnavailable("Upload stopped: the original terminal changed.")
                        return
                    }
                    let path = try await upload(target.binding, staged)
                    try Task.checkCancellation()
                    guard !path.isEmpty, !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        model.reportUnavailable("The upload returned an unsupported file path.")
                        return
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .withoutEscapingSlashes
                    let quoted = String(decoding: try encoder.encode(path), as: UTF8.self)
                    guard isCurrent(target) else {
                        model.reportUnavailable("File uploaded to \(quoted); the terminal changed, so no draft was changed.")
                        return
                    }
                    let draft = model.draftBinding(for: target.threadID)
                    model.setDraft([draft, quoted].filter { !$0.isEmpty }.joined(separator: "\n"), for: target.threadID)
                    model.restoreComposerFocus(after: request)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, isCurrent(target) else { return }
                    model.reportUnavailable("File upload failed: \(error.localizedDescription)")
                    return
                }
            }
        }
        tasks[target.threadID] = (request.id, task)
    }

    private func removePhotoCopies(for request: AgentCenterV2PresentationModel.AttachmentPickerRequest) {
        if request.source == .photo { try? FileManager.default.removeItem(at: request.photoDirectory) }
    }

    func cancelAll() {
        model.cancelLoadingAttachmentPhotos()
        selections.removeAll()
        let active = tasks.values.map(\.task)
        tasks.removeAll()
        model.uploadingThreads.removeAll()
        model.attachmentPickerRequest = nil
        active.forEach { $0.cancel() }
    }
}

/// Serializes provider callbacks, cancellation and copying. A provider may
/// never call back after Progress.cancel(), so cancellation resumes our waiter
/// itself. Late callbacks cannot recreate the request's temporary directory.
final class AgentAttachmentPhotoLoad: @unchecked Sendable {
    typealias Completion = (URL?, Error?) -> Void
    private final class Pending {
        let continuation: CheckedContinuation<URL, Error>
        var progress: Progress?
        init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }
    }

    private let lock = NSLock()
    private let directory: URL
    private var cancelled = false
    private var pending: Pending?

    init(directory: URL) { self.directory = directory }

    func loadFile(suggestedName: String?, start: (@escaping Completion) -> Progress) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let item = Pending(continuation)
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = item
                lock.unlock()
                let progress = start { [self] url, error in
                    lock.lock()
                    let live = pending === item && !cancelled
                    lock.unlock()
                    guard live else { return }
                    // The provider's URL is valid only inside this callback,
                    // so copy (and transcode) here, but outside the lock: a
                    // main-thread Cancel must not wait on a large photo.
                    let result: Result<URL, Error> = Result {
                        if let error { throw error }
                        guard let url else { throw AgentAttachmentPhotos.failure() }
                        return try AgentAttachmentPhotos.copyImage(at: url, suggestedName: suggestedName, to: directory)
                    }
                    lock.lock()
                    guard pending === item, !cancelled else {
                        lock.unlock()
                        // Cancelled mid-copy: cancel() already resumed the
                        // waiter; drop whatever the copy recreated.
                        try? FileManager.default.removeItem(at: directory)
                        return
                    }
                    pending = nil
                    lock.unlock()
                    continuation.resume(with: result)
                }
                lock.lock()
                let shouldCancel = cancelled
                if pending === item { item.progress = progress }
                lock.unlock()
                if shouldCancel { progress.cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let item = pending
        pending = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        item?.progress?.cancel()
        item?.continuation.resume(throwing: CancellationError())
    }
}

extension TransferQueue {
    /// Reuses the same unique private path, atomic upload and cancellation
    /// cleanup as Files. The staged local copy stays alive through finalization.
    func uploadAgentAttachment(localURL: URL) async throws -> String {
        try Task.checkCancellation()
        let item = enqueuePasteUpload(localURL: localURL)
        return try await withTaskCancellationHandler {
            await item.awaitFinished()
            try Task.checkCancellation()
            guard case .completed = item.phase, let path = item.resolvedRemotePath else {
                if case .failed(let message) = item.phase {
                    throw NSError(domain: "TesseraAttachment", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                throw CancellationError()
            }
            return path
        } onCancel: {
            Task { @MainActor in self.cancel(item, reason: .user) }
        }
    }
}

/// Provider files expire when their callback returns; own the copy before then.
enum AgentAttachmentPhotos {
    static func copyImage(at url: URL, suggestedName: String?, to directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) else { throw failure() }
        let type = identifier as String
        let extensions = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg",
            UTType.gif.identifier: "gif", UTType.webP.identifier: "webp"]
        let originalName = (suggestedName ?? url.lastPathComponent) as NSString
        let stem = ((originalName.lastPathComponent as NSString).deletingPathExtension)
        let name = stem.isEmpty ? "Photo" : stem
        let destinationDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(name).appendingPathExtension(extensions[type] ?? "jpg")
        do {
            if extensions[type] != nil {
                try FileManager.default.copyItem(at: url, to: destination)
            } else {
                guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw failure()
                }
                var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
                if let input = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let orientation = input[kCGImagePropertyOrientation] {
                    properties[kCGImagePropertyOrientation] = orientation
                }
                CGImageDestinationAddImageFromSource(output, source, 0, properties as CFDictionary)
                guard CGImageDestinationFinalize(output) else { throw failure() }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
    }

    static func failure() -> NSError {
        NSError(domain: "TesseraAttachment", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The selected photo could not be loaded."])
    }
}
