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
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private var silenceTimer: Timer?
    @ObservationIgnored private var lastChangeAt: Date?
    @ObservationIgnored private var willResignActiveObserver: NSObjectProtocol?
    @ObservationIgnored private var tapInstalled = false
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
        audioEngine?.stop()
        if tapInstalled {
            audioEngine?.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
        guard activeState == .idle else { return }

        let permissions = await requestPermissions()
        guard permissions == .granted else { return }

        guard let recognizer = Self.onDeviceRecognizer(logFallback: true) else {
            DiagnosticLogStore.appendSpeech("start refused reason=on-device-recognizer-unavailable")
            return
        }

        activeState = .listening
        startedAt = .now
        transcript = ""
        amplitude = 0
        lastChangeAt = .now
        self.recognizer = recognizer

        do {
            try configureAudioSession()
        } catch {
            DiagnosticLogStore.appendSpeech("start failed step=audio-session error='\(error)'")
            stop(commit: false)
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true

        audioEngine = engine
        recognitionRequest = request

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            DiagnosticLogStore.appendSpeech("start refused reason=no-input-channels")
            stop(commit: false)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let errorDescription = error.map { "\($0)" }
            Task { @MainActor [weak self] in
                self?.handleRecognitionUpdate(text: text, errorDescription: errorDescription)
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            let rms = Self.normalizedRMS(from: buffer)
            Task { @MainActor [weak self] in
                self?.publishAmplitude(rms)
            }
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            DiagnosticLogStore.appendSpeech("start failed step=audio-engine error='\(error)'")
            stop(commit: false)
            return
        }

        startSilenceTimerIfNeeded()
    }

    func stop(commit: Bool) {
        guard activeState != .idle || audioEngine != nil || recognitionTask != nil || recognitionRequest != nil else {
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
        silenceTimer?.invalidate()
        silenceTimer = nil

        let committedText = commit && !transcript.isEmpty ? transcript : nil

        recognitionTask?.cancel()
        recognitionTask = nil

        if let audioEngine {
            audioEngine.stop()
            if tapInstalled {
                audioEngine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }

        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
        audioEngine = nil
        lastChangeAt = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            DiagnosticLogStore.appendSpeech("stop teardown failed error='\(error)'")
        }

        activeState = .idle
        startedAt = nil
        amplitude = 0
        isStopping = false

        if let committedText {
            onCommit?(committedText)
        }
        transcript = ""
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
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
            return .denied(reason: "Speech recognition permission was denied.")
        case .restricted:
            return .denied(reason: "Speech recognition is restricted on this device.")
        case .notDetermined:
            return .unknown
        @unknown default:
            return .denied(reason: "Speech recognition permission is unavailable.")
        }
    }

    private func microphoneDeniedState() async -> DictationPermissionState? {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return nil
            case .denied:
                return .denied(reason: "Microphone permission was denied.")
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                return granted ? nil : .denied(reason: "Microphone permission was denied.")
            @unknown default:
                return .denied(reason: "Microphone permission is unavailable.")
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return nil
            case .denied:
                return .denied(reason: "Microphone permission was denied.")
            case .undetermined:
                let granted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
                return granted ? nil : .denied(reason: "Microphone permission was denied.")
            @unknown default:
                return .denied(reason: "Microphone permission is unavailable.")
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

    nonisolated private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Double {
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
