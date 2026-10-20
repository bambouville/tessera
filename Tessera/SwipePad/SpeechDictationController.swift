import Foundation
import AVFoundation
import Observation
import Speech
import UIKit

enum DictationPermissionState: Equatable {
    case unknown
    case granted
    case denied(reason: String)
}

enum DictationActiveState: Equatable {
    case idle
    case listening
    case finishing
}

@MainActor
@Observable
final class SpeechDictationController {
    var permissionState: DictationPermissionState = .unknown
    var activeState: DictationActiveState = .idle
    var transcript: String = ""
    var amplitude: Double = 0
    var startedAt: Date?
    var onCommit: ((String) -> Void)?

    private let appearance: AppearancePreferences
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var audioCapture: DictationAudioCapture?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var lastChangeAt: Date?
    @ObservationIgnored private var willResignActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var listeningID: UUID?
    @ObservationIgnored private var cancelSetup: (() -> Void)?
    @ObservationIgnored private var requestingPermissions = false
    @ObservationIgnored private var isStopping = false

    static var isOnDeviceAvailable: Bool {
        onDeviceRecognizer(logFallback: false) != nil
    }

    init(appearance: AppearancePreferences) {
        self.appearance = appearance
        willResignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeState == .listening else { return }
                self.stop(commit: false)
            }
        }
    }

    deinit {
        if let willResignActiveObserver {
            NotificationCenter.default.removeObserver(willResignActiveObserver)
        }
        silenceTimer?.invalidate()
        recognitionTask?.cancel()
        cancelSetup?()
        audioCapture?.cancel()
    }

    func requestPermissions() async -> DictationPermissionState {
        let speechStatus = await speechAuthorizationStatus()
        guard speechStatus == .authorized else {
            let state = speechPermissionState(for: speechStatus)
            permissionState = state
            return state
        }

        if let microphoneDeniedState = await microphoneDeniedState() {
            permissionState = microphoneDeniedState
            return microphoneDeniedState
        }

        permissionState = .granted
        return .granted
    }

    func start() async {
        guard activeState == .idle, !requestingPermissions else { return }
        requestingPermissions = true
        let permissions = await requestPermissions()
        requestingPermissions = false
        guard permissions == .granted, !Task.isCancelled else { return }

        guard let recognizer = Self.onDeviceRecognizer(logFallback: true) else {
            DiagnosticLogStore.appendSpeech("start refused reason=on-device-recognizer-unavailable")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let capture = DictationAudioCapture(request: request)
        await beginListening(cancel: { capture.cancel() }) { id in
            self.recognizer = recognizer
            self.recognitionRequest = request
            self.audioCapture = capture
            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let errorDescription = error.map { "\($0)" }
                Task { @MainActor [weak self] in
                    guard self?.listeningID == id else { return }
                    self?.handleRecognitionUpdate(text: text, errorDescription: errorDescription)
                }
            }
            return try await capture.start { [weak self] rms in
                Task { @MainActor [weak self] in
                    guard self?.listeningID == id else { return }
                    self?.publishAmplitude(rms)
                }
            }
        }
    }

    /// Shared with microphone-free ordering tests. A cancelled setup may
    /// finish later, but can never publish a start time or revive listening.
    func beginListening(
        cancel: @escaping () -> Void,
        setup: (UUID) async throws -> Date
    ) async {
        guard activeState == .idle else { return }
        let id = UUID()
        listeningID = id
        cancelSetup = cancel
        activeState = .listening
        startedAt = nil
        transcript = ""
        amplitude = 0
        lastChangeAt = nil
        await Task.yield()
        guard listeningID == id, !Task.isCancelled else {
            if listeningID == id { stop(commit: false) }
            return
        }
        do {
            let start = try await setup(id)
            guard listeningID == id else { return }
            guard !Task.isCancelled else {
                stop(commit: false)
                return
            }
            startedAt = start
            lastChangeAt = start
            startSilenceTimerIfNeeded()
        } catch {
            guard listeningID == id else { return }
            if !(error is CancellationError) {
                DiagnosticLogStore.appendSpeech("start failed error='\(error)'")
            }
            stop(commit: false)
        }
    }

    func stop(commit: Bool) {
        guard activeState != .idle || audioCapture != nil || recognitionTask != nil || recognitionRequest != nil else {
            if !commit {
                transcript = ""
            }
            amplitude = 0
            startedAt = nil
            return
        }
        guard !isStopping else { return }

        isStopping = true
        activeState = .finishing
        listeningID = nil
        cancelSetup?()
        cancelSetup = nil
        silenceTimer?.invalidate()
        silenceTimer = nil

        let committedText = commit && !transcript.isEmpty ? transcript : nil

        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = nil
        recognizer = nil
        audioCapture = nil
        lastChangeAt = nil

        activeState = .idle
        startedAt = nil
        amplitude = 0
        isStopping = false

        if let committedText {
            onCommit?(committedText)
        }
        transcript = ""
    }

    private func startSilenceTimerIfNeeded() {
        silenceTimer?.invalidate()
        guard appearance.voiceCommitOnSilence else { return }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForSilenceCommit()
            }
        }
    }

    private func checkForSilenceCommit() {
        guard activeState == .listening,
              appearance.voiceCommitOnSilence,
              !transcript.isEmpty,
              let lastChangeAt,
              Date.now.timeIntervalSince(lastChangeAt) > 1.2
        else {
            return
        }

        stop(commit: true)
    }

    private func handleRecognitionUpdate(text: String?, errorDescription: String?) {
        guard activeState == .listening else { return }

        if let text {
            if transcript != text {
                lastChangeAt = .now
            }
            transcript = text
        }

        if let errorDescription, !isStopping {
            DiagnosticLogStore.appendSpeech("recognition failed error='\(errorDescription)'")
            stop(commit: false)
        }
    }

    private func publishAmplitude(_ rms: Double) {
        guard activeState == .listening else { return }
        amplitude = min(1, max(0, rms * 0.4 + amplitude * 0.6))
    }

    private func speechAuthorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func speechPermissionState(for status: SFSpeechRecognizerAuthorizationStatus) -> DictationPermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied(reason: String(localized: "Speech recognition permission was denied."))
        case .restricted:
            return .denied(reason: String(localized: "Speech recognition is restricted on this device."))
        case .notDetermined:
            return .unknown
        @unknown default:
            return .denied(reason: String(localized: "Speech recognition permission is unavailable."))
        }
    }

    private func microphoneDeniedState() async -> DictationPermissionState? {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return nil
            case .denied:
                return .denied(reason: String(localized: "Microphone permission was denied."))
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                return granted ? nil : .denied(reason: String(localized: "Microphone permission was denied."))
            @unknown default:
                return .denied(reason: String(localized: "Microphone permission is unavailable."))
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return nil
            case .denied:
                return .denied(reason: String(localized: "Microphone permission was denied."))
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                return granted ? nil : .denied(reason: String(localized: "Microphone permission was denied."))
            @unknown default:
                return .denied(reason: String(localized: "Microphone permission is unavailable."))
            }
        }
    }

    private static func onDeviceRecognizer(logFallback: Bool) -> SFSpeechRecognizer? {
        let locale = Locale.autoupdatingCurrent
        if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition {
            return recognizer
        }

        if logFallback {
            DiagnosticLogStore.appendSpeech(
                "recognizer fallback fromLocale='\(locale.identifier)' toLocale=en-US"
            )
        }

        let fallbackLocale = Locale(identifier: "en-US")
        guard let fallback = SFSpeechRecognizer(locale: fallbackLocale), fallback.supportsOnDeviceRecognition else {
            return nil
        }
        return fallback
    }

    nonisolated fileprivate static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            return 0
        }

        let samples = channelData[0]
        let frameCount = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for index in 0..<frameCount {
            let sample = samples[index]
            sumSquares += sample * sample
        }

        let rms = sqrt(Double(sumSquares) / Double(frameCount))
        return min(1, max(0, 1 - exp(-rms * 18)))
    }
}

/// All app-wide AVAudioSession/engine mutations share this queue, including
/// the bell's launch-time ambient setup, cancelled dictation teardown, and
/// subsequent starts. No audio work blocks UI.
enum AudioSessionQueue {
    static let shared = DispatchQueue(label: "com.bambouville.Tessera.audio-session")
}

private final class DictationAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var sessionActive = false

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        if !wasCancelled { AudioSessionQueue.shared.async { self.tearDown() } }
    }

    func start(amplitude: @escaping @Sendable (Double) -> Void) async throws -> Date {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                AudioSessionQueue.shared.async {
                    var step = "audio-session"
                    do {
                        guard !self.isCancelled else { throw CancellationError() }
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                        self.sessionActive = true
                        try session.setActive(true)
                        guard !self.isCancelled else { throw CancellationError() }
                        step = "audio-engine"
                        let engine = AVAudioEngine()
                        self.engine = engine
                        let input = engine.inputNode
                        let format = input.outputFormat(forBus: 0)
                        guard format.channelCount > 0 else {
                            throw NSError(domain: "SpeechDictation", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "No input channels"])
                        }
                        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request = self.request] buffer, _ in
                            request?.append(buffer)
                            amplitude(SpeechDictationController.normalizedRMS(from: buffer))
                        }
                        self.tapInstalled = true
                        guard !self.isCancelled else { throw CancellationError() }
                        engine.prepare()
                        try engine.start()
                        let startedAt = Date.now
                        guard !self.isCancelled else { throw CancellationError() }
                        continuation.resume(returning: startedAt)
                    } catch {
                        self.tearDown()
                        if !(error is CancellationError) {
                            DiagnosticLogStore.appendSpeech("start failed step=\(step) error='\(error)'")
                        }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func tearDown() {
        engine?.stop()
        if tapInstalled {
            engine?.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = nil
        request.endAudio()
        if sessionActive {
            sessionActive = false
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                DiagnosticLogStore.appendSpeech("stop teardown failed error='\(error)'")
            }
        }
    }
}
