// Tessera/Files/RemoteFileItemProvider.swift
// Remote Files feature - drag-out file promise wrapper.
// Contracts: Tessera/Files/FilesContracts.swift

import Foundation
import UniformTypeIdentifiers

enum RemoteFileItemProvider {
    /// Marker stamped on drag-out providers so the panel's own drop
    /// target can recognize and skip in-app self-drops — releasing a
    /// row drag over the panel would otherwise download the file and
    /// re-upload it onto itself. `.ownProcess` visibility keeps the
    /// marker invisible to external drop targets.
    static let localDragMarkerTypeIdentifier = "com.bambouville.tessera.remote-file-drag"

    static func itemProvider(
        for entry: RemoteFileEntry,
        download: @escaping @Sendable (_ destination: URL) async throws -> Void
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        let fileName = entry.name
        let fileExtension = (fileName as NSString).pathExtension
        let type = UTType(filenameExtension: fileExtension) ?? .data

        provider.suggestedName = fileName
        provider.registerDataRepresentation(
            forTypeIdentifier: localDragMarkerTypeIdentifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }

        let registerPromise: (String) -> Void = { identifier in
            provider.registerFileRepresentation(
                forTypeIdentifier: identifier,
                fileOptions: [],
                visibility: .all
            ) { completionHandler in
                let progress = Progress(totalUnitCount: 1)

                Task {
                    do {
                        let fileManager = FileManager.default
                        let directory = fileManager.temporaryDirectory.appendingPathComponent(
                            UUID().uuidString,
                            isDirectory: true
                        )
                        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

                        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
                        try await download(destination)

                        progress.completedUnitCount = 1
                        DiagnosticLogStore.appendApp("drag-out promise fulfilled type=\(identifier)")
                        completionHandler(destination, false, nil)
                    } catch {
                        progress.completedUnitCount = 1
                        DiagnosticLogStore.appendApp(
                            "drag-out promise failed type=\(identifier): \(error.localizedDescription)")
                        completionHandler(nil, false, error)
                    }
                }

                return progress
            }
        }

        registerPromise(type.identifier)
        // Extension-less names fall back to bare public.data, which
        // Files.app's drop target refuses (its conformance check wants
        // a content type) — the drop dies silently before the promise
        // is ever requested. Advertise the same promise as
        // public.content too so the negotiation succeeds; the UTI is
        // only the drag contract, the bytes and name land verbatim.
        if !type.conforms(to: .content) {
            registerPromise(UTType.content.identifier)
        }

        return provider
    }

    static func itemProviderIfDraggable(
        for entry: RemoteFileEntry,
        download: @escaping @Sendable (_ destination: URL) async throws -> Void
    ) -> NSItemProvider? {
        switch entry.kind {
        case .file:
            return itemProvider(for: entry, download: download)
        case .directory, .symlink:
            return nil
        }
    }
}
