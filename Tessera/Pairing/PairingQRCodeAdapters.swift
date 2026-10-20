@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import TesseraCore
import UIKit

enum PairingQRCodeRenderError: Error, Equatable {
    case nonCanonicalText
    case imageCreationFailed
}

/// Core Image-only QR renderer. The input is parsed and re-encoded before any
/// pixels are produced, so an adapter can never render a normalized or altered
/// Pairing-v1 offer as though it were canonical.
enum PairingQRCodeRenderer {
    static func image(forCanonicalText text: String, side: Int? = nil) throws -> UIImage {
        let offer = try PairingQRTextCodecV1.decode(text)
        guard try PairingQRTextCodecV1.encode(offer) == text else {
            throw PairingQRCodeRenderError.nonCanonicalText
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            throw PairingQRCodeRenderError.imageCreationFailed
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let base = context.createCGImage(output, from: output.extent) else {
            throw PairingQRCodeRenderError.imageCreationFailed
        }
        guard let side else { return UIImage(cgImage: base) }
        let scale = max(1, side / max(base.width, base.height))
        let width = base.width * scale
        let height = base.height * scale
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PairingQRCodeRenderError.imageCreationFailed
        }
        bitmap.interpolationQuality = .none
        bitmap.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = bitmap.makeImage() else {
            throw PairingQRCodeRenderError.imageCreationFailed
        }
        return UIImage(cgImage: image)
    }
}

enum PairingQRCodeScannerStatus: Equatable {
    case idle
    case requestingPermission
    case ready
    case denied
    case unavailable
    case invalidManualText
}

/// Scanner-facing state, deliberately free of pairing flow ownership. A
/// coordinator supplies `onCanonicalText`; the model stops after exactly one
/// canonical QR or manual submission and can be restarted explicitly.
@MainActor
final class PairingQRCodeScannerModel: NSObject, ObservableObject {
    @Published private(set) var status: PairingQRCodeScannerStatus = .idle

    // AVFoundation documents start/stop/configuration as blocking. The
    // preview reads this reference, but every session mutation is serialized
    // on `sessionQueue`, never on SwiftUI's MainActor.
    nonisolated(unsafe) let session = AVCaptureSession()
    var onCanonicalText: ((String) -> Void)?

    nonisolated private let sessionQueue = DispatchQueue(label: "com.bambouville.tessera.pairing-camera")
    nonisolated(unsafe) private var didConfigureSession = false
    nonisolated private let lifecycle = PairingCameraLifecycle()
    private var didAcceptCode = false

    func start() {
        didAcceptCode = false
        let generation = lifecycle.begin()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(generation: generation)
        case .notDetermined:
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.lifecycle.isActive(generation) else { return }
                    if granted { self.configureAndStart(generation: generation) }
                    else { self.status = .denied }
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .unavailable
        }
    }

    func restart() {
        lifecycle.cancel()
        sessionQueue.async { [session] in session.stopRunning() }
        didAcceptCode = false
        start()
    }

    func cancel() {
        lifecycle.cancel()
        didAcceptCode = true
        sessionQueue.async { [session] in session.stopRunning() }
        status = .idle
    }

    /// Simulator and camera-denied fallback. The input must be exactly the
    /// shared codec's canonical representation; it is never logged or stored.
    @discardableResult
    func submitManualText(_ text: String) -> Bool {
        guard let canonical = canonicalText(from: text) else {
            status = .invalidManualText
            return false
        }
        accept(canonical)
        return true
    }

    nonisolated private func configureAndStart(generation: UInt64) {
        sessionQueue.async { [weak self] in
            self?.configureAndStartOnSessionQueue(generation: generation)
        }
    }

    nonisolated private func configureAndStartOnSessionQueue(generation: UInt64) {
        guard lifecycle.isActive(generation) else {
            session.stopRunning()
            return
        }
        guard !didConfigureSession else {
            session.startRunning()
            publish(.ready, generation: generation)
            return
        }
        guard let device = AVCaptureDevice.default(for: .video) else {
            publish(.unavailable, generation: generation)
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                publish(.unavailable, generation: generation)
                return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: sessionQueue)
            output.metadataObjectTypes = [.qr]
            didConfigureSession = true
            session.commitConfiguration()
            guard lifecycle.isActive(generation) else {
                session.stopRunning()
                return
            }
            session.startRunning()
            publish(.ready, generation: generation)
        } catch {
            publish(.unavailable, generation: generation)
        }
    }

    nonisolated private func publish(
        _ status: PairingQRCodeScannerStatus,
        generation: UInt64
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.lifecycle.isActive(generation) else { return }
            self.status = status
        }
    }

    private func accept(_ text: String) {
        guard !didAcceptCode else { return }
        didAcceptCode = true
        lifecycle.cancel()
        sessionQueue.async { [session] in session.stopRunning() }
        onCanonicalText?(text)
    }

    private func canonicalText(from text: String) -> String? {
        guard let offer = try? PairingQRTextCodecV1.decode(text),
              let canonical = try? PairingQRTextCodecV1.encode(offer),
              canonical == text else {
            return nil
        }
        return canonical
    }
}

/// Lock-backed because AVFoundation configuration and permission completions
/// arrive off-MainActor. A stale generation may stop a session but can never
/// restart it or publish a status after the SwiftUI scanner was dismissed.
private final class PairingCameraLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active = false

    func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if generation == 0 { generation = 1 }
        active = true
        return generation
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if generation == 0 { generation = 1 }
        active = false
    }

    func isActive(_ candidate: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == candidate
    }
}

extension PairingQRCodeScannerModel: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let text = object.stringValue else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let canonical = self.canonicalText(from: text) else { return }
            self.accept(canonical)
        }
    }
}

/// Presentation-only scanner wrapper. It leaves manual-entry controls and all
/// transaction UI to the caller, while making the camera preview full-screen
/// on iPhone and bounded/centered on iPad.
struct PairingQRCodeScannerView: View {
    @ObservedObject var model: PairingQRCodeScannerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { geometry in
            PairingQRCodeCameraPreview(session: model.session)
                .frame(
                    width: horizontalSizeClass == .compact ? geometry.size.width : min(geometry.size.width, 560),
                    height: horizontalSizeClass == .compact ? geometry.size.height : min(geometry.size.height, 560)
                )
                .clipShape(RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 0 : 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
    }
}

private struct PairingQRCodeCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
