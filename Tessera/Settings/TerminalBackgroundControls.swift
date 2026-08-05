// Tessera/Settings/TerminalBackgroundControls.swift
// Shared controls for picking/tuning a terminal background picture — used
// by ThemeSettingsView (global) and HostDetailView (per-host override). The
// owner supplies current values + mutation closures, so global writes land
// on AppearancePreferences and per-host writes on HostTerminalBackgroundStore
// without this view knowing which.
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct TerminalBackgroundImageControls: View {
    @Environment(\.designTokens) private var T

    let imageID: String?
    let dim: Double
    let blur: Double
    let fillMode: TerminalBackgroundFillMode
    /// The terminal theme the picture composites with — preview colors,
    /// letterbox fill, and scrim tint all come from it.
    let theme: TerminalTheme
    /// Raw picked image bytes (Photos or Files). The owner imports via
    /// TerminalBackgroundImageStore and persists the new id.
    let onImport: (Data) -> Void
    let onRemove: () -> Void
    let onDimChanged: (Double) -> Void
    /// Fired on slider release only — the variant file is already rendered
    /// when this runs, so the owner can persist immediately and the live
    /// backdrop swaps to a ready file.
    let onBlurChanged: (Double) -> Void
    let onFillModeChanged: (TerminalBackgroundFillMode) -> Void

    @State private var photoItem: PhotosPickerItem? = nil
    @State private var showFileImporter = false
    /// Non-nil while the blur slider is mid-drag (and until the release
    /// commit lands) — drives the live preview-card blur without touching
    /// persisted state per tick.
    @State private var draggingBlur: Double? = nil

    /// The preview card is ~5× smaller than the session canvas, so a raw
    /// SwiftUI `.blur(radius:)` at the slider's point value would read far
    /// stronger than the pre-rendered variant does full-screen. Scale it
    /// down so the 150pt card approximates the real result.
    private static let previewBlurScale: Double = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageID, let image = TerminalBackgroundImageStore.image(id: imageID) {
                previewCard(imageID: imageID, image: image)
            }

            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    pickerLabel("choose photo")
                }
                .buttonStyle(.plain)

                Btn("choose file", style: .default, compact: true) {
                    showFileImporter = true
                }

                if imageID != nil {
                    Btn("remove", style: .danger, compact: true, action: onRemove)
                }
            }

            if imageID == nil {
                Text("pick a picture from photos or files — it's downsampled and stored inside the app; the original is never referenced again.")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                dimRow
                blurRow
                fillRow
            }
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task { @MainActor in
                defer { photoItem = nil }
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    NSLog("[TerminalBackground] photo pick: loadTransferable failed")
                    return
                }
                onImport(data)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                NSLog("[TerminalBackground] file pick: unreadable %@", url.lastPathComponent)
                return
            }
            onImport(data)
        }
    }

    // MARK: - Pieces

    /// Mirrors Btn's compact default style — PhotosPicker needs a plain
    /// label view, not a Button.
    private func pickerLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.tesseraMono(size: 13))
            .foregroundStyle(T.fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(T.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.border, lineWidth: 1)
            )
    }

    private func previewCard(imageID: String, image: UIImage) -> some View {
        VStack(spacing: 0) {
            ZStack {
                theme.bg
                // Live blur on the 150pt preview only — cheap at this size
                // and gives per-tick drag feedback. The session backdrop
                // always renders the pre-blurred variant file instead.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fillMode == .fill ? .fill : .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .blur(radius: (draggingBlur ?? blur) * Self.previewBlurScale)
                theme.bg.opacity(dim)
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ ls -la")
                        .foregroundStyle(theme.fg)
                    Text("drwxr-xr-x  projects/")
                        .foregroundStyle(theme.accent)
                    Text("-rw-r--r--  readme.md")
                        .foregroundStyle(theme.fg.opacity(0.6))
                }
                .font(Typography.tesseraMono(size: 11))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            }
            .frame(height: 150)
            .clipped()

            HStack(spacing: 8) {
                Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))")
                    .foregroundStyle(T.fgMuted)
                Spacer(minLength: 8)
                if let bytes = TerminalBackgroundImageStore.byteCount(id: imageID) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " stored")
                        .foregroundStyle(T.fgDim)
                }
            }
            .font(Typography.tesseraMono(size: 11))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(T.panelBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(T.border, lineWidth: 1)
        )
        // The aspect-fill image overflows its 150pt frame; .clipped() trims
        // the pixels but NOT the hit-test region, so the invisible overflow
        // was swallowing taps on the mode buttons declared above this card.
        // The card is purely decorative — remove it from hit-testing.
        .allowsHitTesting(false)
    }

    private var dimRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("dim")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                Spacer()
                Text("\(Int((dim * 100).rounded()))%")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
            }
            Slider(
                value: Binding(get: { dim }, set: onDimChanged),
                in: 0...0.85
            )
            .tint(T.accent)
            Text("higher keeps text readable; 0% shows the photo untouched.")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var blurRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("blur")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
                Spacer()
                Text("\(Int((draggingBlur ?? blur).rounded())) pt")
                    .font(Typography.tesseraMono(size: 11))
                    .foregroundStyle(T.fgMuted)
            }
            Slider(
                value: Binding(
                    get: { draggingBlur ?? blur },
                    set: { draggingBlur = $0 }
                ),
                in: AppearancePreferences.terminalBackgroundBlurRange,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing, let value = draggingBlur else { return }
                    commitBlur(value)
                }
            )
            .tint(T.accent)
        }
    }

    /// Render the variant off-main first, then persist — the session
    /// backdrop keeps showing the previous variant during the render and
    /// swaps to a ready file, never blocking a frame on CoreImage.
    private func commitBlur(_ value: Double) {
        guard let imageID else {
            draggingBlur = nil
            return
        }
        Task {
            await Task.detached(priority: .userInitiated) {
                _ = TerminalBackgroundImageStore.image(id: imageID, blur: value)
            }.value
            onBlurChanged(value)
            draggingBlur = nil
            Task.detached(priority: .background) {
                TerminalBackgroundImageStore.pruneVariants(of: imageID, keepingBlur: value)
            }
        }
    }

    private var fillRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("fill")
                .font(Typography.tesseraMono(size: 11))
                .foregroundStyle(T.fgMuted)
            HStack(spacing: 8) {
                fillButton(.fill, label: "fill")
                fillButton(.fit, label: "fit")
            }
            .frame(maxWidth: 220)
        }
    }

    private func fillButton(_ mode: TerminalBackgroundFillMode, label: String) -> some View {
        let isSelected = fillMode == mode
        return Btn(
            style: isSelected ? .primary : .default,
            full: true,
            action: { onFillModeChanged(mode) }
        ) {
            Text(label)
                .font(Typography.tesseraMono(size: 13, weight: isSelected ? .semibold : .regular))
        }
    }
}
