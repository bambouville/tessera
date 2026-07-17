// Tessera/Terminal/TerminalBackground.swift
// Custom terminal background pictures. Model + storage only — the UIKit
// backdrop lives in TerminalBackdropView.swift, the SwiftUI controls in
// Settings/TerminalBackgroundControls.swift.
//
// Storage design:
// - The picture file lives in Application Support/TerminalBackgrounds/,
//   downsampled + re-encoded on import so the original photo is never
//   referenced again (no lingering Photos access, bounded memory).
// - The global choice persists on AppearancePreferences (UserDefaults).
// - Per-host overrides persist in a single UserDefaults JSON blob keyed by
//   host UUID (the HostOSDetectionState pattern) — deliberately NOT a new
//   PersistedHost column, which would trip the iOS 26 SwiftData
//   [String]-array lightweight-migration crash (tags lives on that model).
import SwiftUI
import UIKit
import ImageIO
import CoreImage

enum TerminalBackgroundFillMode: String, Codable, CaseIterable {
    /// Aspect-fill crop to the canvas (default).
    case fill
    /// Aspect-fit; letterbox bars show the theme background color.
    case fit
}

/// Fully resolved background for one terminal canvas. `nil` (at use sites)
/// means the classic solid theme color.
struct ResolvedTerminalBackground: Equatable {
    var imageID: String
    /// 0…0.85 — opacity of the theme-bg-colored scrim between picture and
    /// text (iTerm2 "blending"). 0 shows the photo untouched.
    var dim: Double
    var fillMode: TerminalBackgroundFillMode
    /// Gaussian blur radius in points (0 = off). Pre-rendered once into a
    /// sibling variant file — the terminal render path never blurs live.
    var blur: Double = 0

    /// Host override → global → solid color.
    static func resolve(
        hostID: UUID?,
        appearance: AppearancePreferences,
        hostStore: HostTerminalBackgroundStore
    ) -> ResolvedTerminalBackground? {
        if let hostID {
            let override = hostStore.override(for: hostID)
            switch override.mode {
            case .color:
                return nil
            case .image:
                // Image mode with nothing picked yet (or a file lost to a
                // partial restore) falls back to global so a half-configured
                // host never renders differently from the default. The check
                // stays on the BASE id — blur variants are always re-derivable
                // from it.
                if let id = override.imageID,
                   TerminalBackgroundImageStore.image(id: id) != nil {
                    return ResolvedTerminalBackground(
                        imageID: id,
                        dim: override.dim,
                        fillMode: override.fillMode,
                        blur: override.blur
                    )
                }
            case .inherit:
                break
            }
        }
        return appearance.globalTerminalBackground
    }
}

extension AppearancePreferences {
    /// The global background, or nil when the user wants the theme color
    /// (or picked "custom image" but hasn't imported one yet, or the stored
    /// file is missing — silent solid-color fallback, setting kept).
    var globalTerminalBackground: ResolvedTerminalBackground? {
        guard terminalBackgroundUsesImage,
              let id = terminalBackgroundImageID,
              TerminalBackgroundImageStore.image(id: id) != nil else { return nil }
        return ResolvedTerminalBackground(
            imageID: id,
            dim: terminalBackgroundDim,
            fillMode: TerminalBackgroundFillMode(rawValue: terminalBackgroundFillMode) ?? .fill,
            blur: terminalBackgroundBlur
        )
    }
}

// MARK: - Picture files

/// Owns the picture files in Application Support/TerminalBackgrounds/.
/// Every import mints a fresh UUID filename, so files are single-referenced
/// (one per slot: the global slot or one host's slot) and safe to delete
/// when their slot is replaced or cleared.
enum TerminalBackgroundImageStore {
    /// iPad Pro 12.9" long edge — no on-screen benefit beyond this.
    static let maxPixelSize = 2732

    private static let cache = NSCache<NSString, UIImage>()

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminalBackgrounds", isDirectory: true)
    }

    struct Imported {
        let id: String
        let pixelWidth: Int
        let pixelHeight: Int
        let byteCount: Int
    }

    /// Downsample (EXIF orientation baked in) + re-encode as JPEG. Returns
    /// nil when the data isn't a decodable image or the write fails.
    static func importImage(data: Data) -> Imported? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }

        let id = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: directory.appendingPathComponent(id), options: .atomic)
        } catch {
            return nil
        }
        cache.setObject(image, forKey: id as NSString)
        return Imported(id: id, pixelWidth: cg.width, pixelHeight: cg.height, byteCount: jpeg.count)
    }

    static func image(id: String) -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(id).path) else {
            return nil
        }
        // `UIImage(contentsOfFile:)` is lazy — force the bitmap decode once
        // here instead of at every first draw of the backdrop.
        let prepared = image.preparingForDisplay() ?? image
        cache.setObject(prepared, forKey: id as NSString)
        return prepared
    }

    // MARK: - Blur variants

    /// One CIContext for all variant renders — creating one per render is the
    /// expensive part of CoreImage.
    private static let ciContext = CIContext(options: nil)

    /// Filename of the pre-blurred sibling for `id` at `blur` points
    /// (`<stem>-b<radius>.jpg`); the base id itself when the radius rounds
    /// to zero.
    static func variantID(id: String, blur: Double) -> String {
        let radius = Int(blur.rounded())
        guard radius > 0 else { return id }
        let stem = (id as NSString).deletingPathExtension
        return "\(stem)-b\(radius).jpg"
    }

    /// All stored blur-variant filenames derived from base `id`.
    static func variants(of id: String) -> [String] {
        let prefix = (id as NSString).deletingPathExtension + "-b"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }
    }

    /// The picture at `blur` points: the pre-rendered variant when one exists,
    /// rendered on demand from the base otherwise (covers imports made before
    /// the blur feature and cold caches). Falls back to the unblurred base if
    /// the render fails, and to nil only when the base file itself is gone.
    static func image(id: String, blur: Double) -> UIImage? {
        let variant = variantID(id: id, blur: blur)
        guard variant != id else { return image(id: id) }

        if let hit = cache.object(forKey: variant as NSString) { return hit }
        if let stored = UIImage(contentsOfFile: directory.appendingPathComponent(variant).path) {
            let prepared = stored.preparingForDisplay() ?? stored
            cache.setObject(prepared, forKey: variant as NSString)
            return prepared
        }

        guard let base = image(id: id) else { return nil }
        guard let rendered = renderBlurred(base: base, radius: Int(blur.rounded())),
              let jpeg = rendered.jpegData(compressionQuality: 0.85)
        else { return base }
        try? jpeg.write(to: directory.appendingPathComponent(variant), options: .atomic)
        let prepared = rendered.preparingForDisplay() ?? rendered
        cache.setObject(prepared, forKey: variant as NSString)
        return prepared
    }

    /// CIAffineClamp → CIGaussianBlur → crop back to the original extent —
    /// the clamp extends edge pixels outward so the blur doesn't pull in
    /// transparent black and vignette the borders.
    private static func renderBlurred(base: UIImage, radius: Int) -> UIImage? {
        guard let cg = base.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: input.extent)
        guard let output = ciContext.createCGImage(blurred, from: input.extent) else { return nil }
        return UIImage(cgImage: output)
    }

    /// Drop every variant of `id` except the one for `blur` — called after a
    /// new radius is committed so stale renders don't accumulate.
    static func pruneVariants(of id: String, keepingBlur blur: Double) {
        let keep = variantID(id: id, blur: blur)
        for variant in variants(of: id) where variant != keep {
            cache.removeObject(forKey: variant as NSString)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(variant))
        }
    }

    // MARK: - Pre-warm

    /// Force-decode the pictures that will actually back canvases this run
    /// (the in-use blur variant, not just the base) into the cache, off-main,
    /// so the first session mount is a cache hit instead of a ~50ms main-
    /// thread JPEG decode inside SwiftUI body evaluation.
    static func prewarm(_ requests: [(id: String, blur: Double)]) {
        guard !requests.isEmpty else { return }
        Task.detached(priority: .background) {
            for request in requests {
                #if DEBUG
                let start = CFAbsoluteTimeGetCurrent()
                let ok = image(id: request.id, blur: request.blur) != nil
                NSLog(
                    "[TerminalBackground] prewarm id=%@ blur=%d ok=%d took=%.1fms",
                    request.id,
                    Int(request.blur.rounded()),
                    ok ? 1 : 0,
                    (CFAbsoluteTimeGetCurrent() - start) * 1000
                )
                #else
                _ = image(id: request.id, blur: request.blur)
                #endif
            }
        }
    }

    static func delete(id: String) {
        for variant in variants(of: id) {
            cache.removeObject(forKey: variant as NSString)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(variant))
        }
        cache.removeObject(forKey: id as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id))
    }

    static func byteCount(id: String) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(id).path
        )
        return (attrs?[.size] as? NSNumber)?.intValue
    }
}

// MARK: - Per-host overrides

enum HostTerminalBackgroundMode: String, Codable {
    /// Follow settings → themes (the default for every host).
    case inherit
    /// Always the theme's solid color, even when a global image is set.
    case color
    /// This host's own picture.
    case image
}

struct HostTerminalBackgroundOverride: Codable, Equatable {
    var mode: HostTerminalBackgroundMode = .inherit
    var imageID: String? = nil
    var dim: Double = 0.5
    var fillMode: TerminalBackgroundFillMode = .fill
    var blur: Double = 0

    init(
        mode: HostTerminalBackgroundMode = .inherit,
        imageID: String? = nil,
        dim: Double = 0.5,
        fillMode: TerminalBackgroundFillMode = .fill,
        blur: Double = 0
    ) {
        self.mode = mode
        self.imageID = imageID
        self.dim = dim
        self.fillMode = fillMode
        self.blur = blur
    }

    /// Hand-written so every field decodes with `decodeIfPresent` + default.
    /// Synthesized Codable uses plain `decode`, which would make every blob
    /// persisted before a field was added throw — silently resetting ALL
    /// per-host overrides on the first launch after an update.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(
            HostTerminalBackgroundMode.self, forKey: .mode
        ) ?? .inherit
        imageID = try container.decodeIfPresent(String.self, forKey: .imageID)
        dim = try container.decodeIfPresent(Double.self, forKey: .dim) ?? 0.5
        fillMode = try container.decodeIfPresent(
            TerminalBackgroundFillMode.self, forKey: .fillMode
        ) ?? .fill
        blur = try container.decodeIfPresent(Double.self, forKey: .blur) ?? 0
    }
}

/// All per-host background overrides, one JSON blob in UserDefaults. Tiny
/// (a handful of hosts × ~100 bytes) so whole-map writes are fine.
@Observable
final class HostTerminalBackgroundStore {
    static let defaultsKey = "tessera.pref.hostTerminalBackgrounds"

    private(set) var overrides: [String: HostTerminalBackgroundOverride] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(
               [String: HostTerminalBackgroundOverride].self, from: data
           ) {
            overrides = decoded
        }
    }

    func override(for hostID: UUID) -> HostTerminalBackgroundOverride {
        overrides[hostID.uuidString] ?? HostTerminalBackgroundOverride()
    }

    /// Persists the override; deletes the previously stored picture file when
    /// this update stops referencing it (files are single-referenced).
    func set(_ override: HostTerminalBackgroundOverride, for hostID: UUID) {
        let key = hostID.uuidString
        if let oldID = overrides[key]?.imageID, oldID != override.imageID {
            TerminalBackgroundImageStore.delete(id: oldID)
        }
        if override == HostTerminalBackgroundOverride() {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = override
        }
        persist()
    }

    /// Full cleanup for a deleted host.
    func removeOverride(for hostID: UUID) {
        let key = hostID.uuidString
        guard let old = overrides.removeValue(forKey: key) else { return }
        if let id = old.imageID { TerminalBackgroundImageStore.delete(id: id) }
        persist()
    }

    private func persist() {
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
