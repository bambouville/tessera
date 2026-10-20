import Foundation
import TesseraAppleContinuity
import TesseraBridgeCore

@MainActor
final class BridgeModel: ObservableObject {
    @Published var displayName: String
    @Published var user: String
    @Published var address: String
    @Published var port: Int
    @Published var tmuxSessionName: String
    @Published var hostKeyFingerprint: String

    @Published private(set) var isPublishing = false
    @Published private(set) var status = "Not publishing"
    @Published private(set) var descriptorJSON = ""
    @Published private(set) var continuationStreamCount = 0
    @Published private(set) var publicationGeneration = 0
    @Published private(set) var incomingStatus = "No incoming continuation"
    @Published private(set) var isHandlingIncoming = false

    let publicationTimeoutMinutes = 5

    private let hostID: UUID
    private let identityErrorDescription: String?
    private let publisher = AppleContinuationActivityPublisher()
    private let defaults: UserDefaults
    private let localContinuationService: LocalContinuationService
    private var timeoutTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        localContinuationService: LocalContinuationService? = nil
    ) {
        self.defaults = defaults
        self.localContinuationService = localContinuationService
            ?? LocalContinuationService(defaults: defaults)
        #if DEBUG
        let reverseHarnessSession = ProcessInfo.processInfo.environment[
            "TESSERA_BRIDGE_REVERSE_HARNESS_SESSION"
        ]
        #endif
        do {
            hostID = try BridgeIdentityStore.loadOrCreate(
                migrating: defaults.string(forKey: Keys.hostID)
            )
            identityErrorDescription = nil
            defaults.removeObject(forKey: Keys.hostID)
        } catch {
            #if DEBUG
            if reverseHarnessSession?.isEmpty == false {
                hostID = UUID(uuidString: "D7BD69E6-227D-4F13-B328-EC1013BC9281")!
                identityErrorDescription = nil
                NSLog("[TesseraBridge] Reverse harness using ephemeral Mac identity")
            } else {
                hostID = UUID()
                identityErrorDescription = error.localizedDescription
            }
            #else
            hostID = UUID()
            identityErrorDescription = error.localizedDescription
            #endif
        }

        let processHostName = ProcessInfo.processInfo.hostName
        let suggestedAddress = processHostName.contains(".")
            ? processHostName
            : "\(processHostName).local"
        displayName = defaults.string(forKey: Keys.displayName)
            ?? Host.current().localizedName
            ?? "This Mac"
        user = defaults.string(forKey: Keys.user) ?? NSUserName()
        address = defaults.string(forKey: Keys.address) ?? suggestedAddress
        port = defaults.object(forKey: Keys.port) as? Int ?? 22
        tmuxSessionName = defaults.string(forKey: Keys.tmuxSessionName)
            ?? "tessera-phase0"
        hostKeyFingerprint = defaults.string(forKey: Keys.hostKeyFingerprint) ?? ""

        publisher.configure(
            enabled: true,
            applicationActive: true,
            locked: false,
            onContinuationStreams: { [weak self] input, output in
                self?.receiveContinuationStreams(input: input, output: output)
            }
        )

        if let identityErrorDescription {
            status = identityErrorDescription
            incomingStatus = identityErrorDescription
            NSLog("[TesseraBridge] Mac identity unavailable")
        }

        #if DEBUG
        if let harnessSession = reverseHarnessSession, !harnessSession.isEmpty {
            tmuxSessionName = harnessSession
            NSLog("[TesseraBridge] Reverse continuation harness requested")
            Task { [weak self] in
                await Task.yield()
                self?.simulateIncomingLocalContinuation()
            }
        }
        #endif
    }

    func publish() {
        do {
            let configuration = try currentConfiguration()
            let bytes = try MacDescriptorFactory.makePublicationBytes(
                from: configuration
            )
            let publication = AppleContinuationPublication(
                descriptorData: bytes,
                title: "\(displayName.trimmingCharacters(in: .whitespacesAndNewlines)) — Continue in Tessera",
                targetContentIdentifier: hostID.uuidString
            )

            try publisher.publish(publication)
            descriptorJSON = String(data: bytes, encoding: .utf8) ?? ""
            publicationGeneration = publisher.publicationGeneration
            isPublishing = publisher.isPublishing
            status = "Ready for Handoff for \(publicationTimeoutMinutes) minutes"
            persistFields()
            scheduleTimeout()
            NSLog(
                "[TesseraBridge] Published continuation generation=%ld descriptorBytes=%ld",
                publicationGeneration,
                bytes.count
            )
        } catch {
            isPublishing = false
            status = error.localizedDescription
            NSLog("[TesseraBridge] Publication rejected: %@", error.localizedDescription)
        }
    }

    @discardableResult
    func receive(_ activity: NSUserActivity) -> Bool {
        guard identityErrorDescription == nil else {
            incomingStatus = identityErrorDescription
                ?? "The Mac identity is unavailable in Keychain."
            return false
        }
        guard activity.activityType == AppleContinuationActivityContract.activityType,
              let bytes = activity.userInfo?[AppleContinuationActivityContract.descriptorKey]
                as? Data else {
            incomingStatus = "Incoming Handoff activity is missing its continuation descriptor"
            return false
        }
        handleIncomingDescriptor(bytes)
        return true
    }

    #if DEBUG
    func simulateIncomingLocalContinuation() {
        do {
            let bytes = try MacDescriptorFactory.makePublicationBytes(
                from: currentConfiguration()
            )
            handleIncomingDescriptor(bytes)
        } catch {
            incomingStatus = error.localizedDescription
            NSLog("[TesseraBridge] Reverse continuation harness preparation failed")
        }
    }
    #endif

    func stopPublishing(reason: String = "Publishing stopped") {
        timeoutTask?.cancel()
        timeoutTask = nil
        publisher.clearPublication()
        isPublishing = false
        status = reason
        NSLog("[TesseraBridge] Continuation publication stopped")
    }

    private func receiveContinuationStreams(
        input: InputStream,
        output: OutputStream
    ) {
        continuationStreamCount += 1
        status = "Continuation stream received; enrollment handling arrives in Phase 3"
        NSLog(
            "[TesseraBridge] Received Apple continuation stream count=%ld",
            continuationStreamCount
        )
        input.close()
        output.close()
    }

    private func handleIncomingDescriptor(_ bytes: Data) {
        guard !isHandlingIncoming else {
            incomingStatus = "Another continuation is already opening"
            return
        }
        isHandlingIncoming = true
        incomingStatus = "Validating incoming session…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await localContinuationService.continueSession(
                    encodedDescriptor: bytes,
                    localHostID: hostID,
                    configuredAddress: address
                )
                incomingStatus = "Opened \(result.sessionName) in iTerm2"
                NSLog(
                    "[TesseraBridge] Continued local tmux id=%@ stableHostID=%@",
                    result.sessionID,
                    result.matchedByStableHostID ? "yes" : "no"
                )
            } catch {
                incomingStatus = error.localizedDescription
                NSLog(
                    "[TesseraBridge] Incoming continuation failed reason=%@",
                    Self.incomingFailureCode(error)
                )
            }
            isHandlingIncoming = false
        }
    }

    private static func incomingFailureCode(_ error: Error) -> String {
        guard let error = error as? LocalContinuationServiceError else {
            return "descriptor-or-platform-error"
        }
        switch error {
        case .remoteHost: return "remote-host"
        case .rejected(.localUserMismatch): return "local-user-mismatch"
        case .rejected(.localHostKeyMismatch): return "local-host-key-mismatch"
        case .rejected(.localRouteUnsupported): return "local-route-unsupported"
        case .rejected(.localSessionMissing): return "local-session-missing"
        case .tmuxUnavailable: return "tmux-unavailable"
        case .tmuxSessionUnavailable: return "tmux-session-unavailable"
        case .invalidTmuxResponse: return "invalid-tmux-response"
        case .iTermUnavailable: return "iterm-unavailable"
        case .attachScriptUnavailable: return "attach-script-unavailable"
        case .iTermLaunchFailed: return "iterm-launch-failed"
        case .iTermAttachUnverified: return "iterm-attach-unverified"
        case .commandFailed: return "command-failed"
        }
    }

    private func currentConfiguration() throws -> MacContinuationConfiguration {
        if let identityErrorDescription {
            throw BridgeInputError.identityUnavailable(identityErrorDescription)
        }
        guard let validatedPort = UInt16(exactly: port), validatedPort > 0 else {
            throw BridgeInputError.invalidPort
        }
        return MacContinuationConfiguration(
            hostID: hostID,
            displayName: displayName,
            user: user,
            address: address,
            port: validatedPort,
            tmuxSessionName: tmuxSessionName,
            hostKeyFingerprint: hostKeyFingerprint
        )
    }

    private func scheduleTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64((self?.publicationTimeoutMinutes ?? 5) * 60)
                    * 1_000_000_000
            )
            guard !Task.isCancelled else { return }
            self?.stopPublishing(reason: "Publication expired")
        }
    }

    private func persistFields() {
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(user, forKey: Keys.user)
        defaults.set(address, forKey: Keys.address)
        defaults.set(port, forKey: Keys.port)
        defaults.set(tmuxSessionName, forKey: Keys.tmuxSessionName)
        defaults.set(hostKeyFingerprint, forKey: Keys.hostKeyFingerprint)
    }

    private enum Keys {
        static let hostID = "phaseZero.hostID"
        static let displayName = "phaseZero.displayName"
        static let user = "phaseZero.user"
        static let address = "phaseZero.address"
        static let port = "phaseZero.port"
        static let tmuxSessionName = "phaseZero.tmuxSessionName"
        static let hostKeyFingerprint = "phaseZero.hostKeyFingerprint"
    }
}

private enum BridgeInputError: LocalizedError {
    case invalidPort
    case identityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "Enter an SSH port from 1 through 65535."
        case .identityUnavailable(let description):
            description
        }
    }
}
