#if DEBUG
import Crypto
import Foundation
import NIOSSH
import Observation
import SwiftData
import SwiftUI

/// DEBUG-only, two-process oracle for the real Bonjour bootstrap transport.
///
/// Every stateful coordinator boundary is replaced with deterministic,
/// public-only in-memory data. The harness therefore exercises discovery,
/// TCP framing, the encrypted handshake, SAS confirmation, manifest transfer,
/// grants, receipts, and acknowledgements without touching SwiftData,
/// Keychain, Secure Enclave, biometrics, or SSH.
@MainActor
@Observable
final class BootstrapNetworkHarness {
    enum Role: String {
        case origin
        case recipient

        var peer: Role { self == .origin ? .recipient : .origin }
    }

    enum Scenario: String {
        case transfer
        case rejection
        case rejectionReversed = "rejection-reversed"

        var isRejection: Bool { self != .transfer }

        var rejectingRole: Role {
            self == .rejectionReversed ? .origin : .recipient
        }
    }

    static let environmentKey = "TESSERA_BOOTSTRAP_NETWORK_HARNESS"
    static let scenarioEnvironmentKey = "TESSERA_BOOTSTRAP_NETWORK_HARNESS_SCENARIO"
    static let originServiceName = "Tessera Bootstrap Harness Origin"
    static let recipientServiceName = "Tessera Bootstrap Harness Recipient"

    let role: Role
    let scenario: Scenario
    let coordinator: BootstrapCoordinator
    private(set) var status = "Preparing nearby bootstrap harness"
    private(set) var terminalResult: String?

    private var hasStarted = false
    private var lastLoggedTranscriptHash: Data?
    private var firstCode: String?
    private var firstTranscriptHash: Data?
    private var didApprove = false
    private var didStartRetry = false
    private var didScheduleInitialRejection = false
    private var peerRejectionObservedAt: Date?
    private var peerRejectionAcknowledgedAt: Date?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BootstrapNetworkHarness? {
        guard let rawRole = environment[environmentKey],
              let role = Role(rawValue: rawRole.lowercased())
        else { return nil }
        let scenario = environment[scenarioEnvironmentKey]
            .flatMap(Scenario.init(rawValue:)) ?? .transfer
        return BootstrapNetworkHarness(role: role, scenario: scenario)
    }

    private init(role: Role, scenario: Scenario) {
        self.role = role
        self.scenario = scenario
        let manifest = Self.fixtureManifest
        let defaults = UserDefaults(
            suiteName: "com.bambouville.TesseraApp.bootstrap-network-harness.\(role.rawValue)"
        )!
        let importContainer = try! TesseraModelContainer.make(inMemory: true)
        let importContext = ModelContext(importContainer)
        let importAppearance = AppearancePreferences()
        let importKnownHosts = KnownHostsStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
                "tessera-bootstrap-network-harness-known-hosts-\(role.rawValue).json"
            ),
            now: { Date() }
        )
        coordinator = BootstrapCoordinator(
            service: NearbyTransferService(),
            firstOpenStore: BootstrapFirstOpenStore(defaults: defaults),
            biometricAuthorizer: { _ in .authenticated },
            manifestExporter: { manifest },
            manifestImporter: { received, peerName in
                try await BootstrapManifestAdapter.apply(
                    received,
                    fromPeer: peerName,
                    to: importContext,
                    appearance: importAppearance,
                    trustHints: BootstrapTrustHintStore(defaults: defaults),
                    provenance: BootstrapImportProvenanceStore(defaults: defaults),
                    knownHosts: importKnownHosts
                )
            },
            recipientKeyProvider: {
                let key = Self.fixturePublicKey
                return try BootstrapRecipientKey(storedKeyID: key.id, publicKey: key)
            },
            grantInstaller: { request in
                NSLog(
                    "[Tessera][BootstrapNetworkHarness] role=origin event=in-memory-grant host=%@",
                    request.hostID.uuidString
                )
            },
            originGrantRecorder: { _ in },
            recipientGrantRecorder: { _ in },
            recipientGrantIntentRecorder: { _ in },
            recipientGrantIntentRemover: { _ in }
        )
    }

    func run() async {
        guard !hasStarted else { return }
        hasStarted = true
        NSLog(
            "[Tessera][BootstrapNetworkHarness] role=%@ result=started",
            role.rawValue
        )

        switch role {
        case .origin:
            coordinator.startOffering(displayName: Self.originServiceName)
        case .recipient:
            coordinator.startRecipientDiscovery(displayName: Self.recipientServiceName)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        while !Task.isCancelled, clock.now < deadline {
            driveCurrentPhase()
            if terminalResult != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard !Task.isCancelled else {
            coordinator.cancel()
            return
        }
        fail("timed out after 180 seconds")
    }

    private func driveCurrentPhase() {
        status = Self.describe(coordinator.phase)
        switch coordinator.phase {
        case .browsing:
            if let peer = coordinator.discoveredPeers.first(where: {
                $0.displayName == Self.originServiceName
            }) ?? coordinator.discoveredPeers.first {
                NSLog(
                    "[Tessera][BootstrapNetworkHarness] role=recipient event=peer-selected name=%@",
                    peer.displayName
                )
                coordinator.selectPeer(peer)
            }

        case .compareCode(_, let peerName, let code):
            guard let transcriptHash = coordinator.activeHandshakeTranscriptHash,
                  lastLoggedTranscriptHash != transcriptHash else { return }
            lastLoggedTranscriptHash = transcriptHash
            let attempt = firstTranscriptHash == nil ? 1 : 2
            NSLog(
                "[Tessera][BootstrapNetworkHarness] role=%@ event=sas attempt=%ld code=%@ transcript=%@ peer=\"%@\"",
                role.rawValue,
                attempt,
                code,
                transcriptHash.base64EncodedString(),
                peerName
            )

            if attempt == 1 {
                firstCode = code
                firstTranscriptHash = transcriptHash
            } else {
                guard didStartRetry,
                      transcriptHash != firstTranscriptHash else {
                    fail("retry reused the first handshake transcript")
                    return
                }
                guard code != firstCode else {
                    fail("retry reused the first comparison code")
                    return
                }
                NSLog(
                    "[Tessera][BootstrapNetworkHarness] role=%@ event=retry-sas fresh=true previous=%@ code=%@",
                    role.rawValue,
                    firstCode ?? "missing",
                    code
                )
            }

            if scenario.isRejection, attempt == 1 {
                guard role == scenario.rejectingRole else { return }
                guard !didScheduleInitialRejection else { return }
                didScheduleInitialRejection = true
                // The acceptance scenario starts with the same SAS visibly
                // settled on both devices. Let the peer's 50 ms drive loop
                // observe attempt one before this role rejects; otherwise the
                // harness itself can race the peer's comparison-screen update
                // and misclassify the fresh retry as its first attempt.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard let self,
                          self.terminalResult == nil,
                          case .compareCode = self.coordinator.phase else { return }
                    NSLog(
                        "[Tessera][BootstrapNetworkHarness] role=%@ event=sas-rejected-local",
                        self.role.rawValue
                    )
                    self.coordinator.rejectCode()
                }
            } else {
                coordinator.confirmCodeMatches()
            }

        case .selectingGrants(let selection):
            guard role == .origin, !didApprove else { return }
            didApprove = true
            NSLog(
                "[Tessera][BootstrapNetworkHarness] role=origin event=approve selected=%ld",
                selection.selectedCount
            )
            coordinator.approveOriginTransfer()

        case .completed(let receipt):
            let installed = receipt.grantReceipt.results.filter {
                $0.status == .installed
            }.count
            let importedTrust: Int
            switch receipt.direction {
            case .sent:
                importedTrust = -1
            case .received(let importReceipt):
                importedTrust = importReceipt.insertedKnownHosts
            }
            complete("installed=\(installed) trusted=\(importedTrust)")

        case .failed(let message):
            if scenario.isRejection {
                if role == scenario.rejectingRole {
                    guard message == "You rejected the pairing code. No setup data was transferred." else {
                        fail(message)
                        return
                    }
                    guard !didStartRetry else { return }
                    didStartRetry = true
                    coordinator.retry()
                    NSLog(
                        "[Tessera][BootstrapNetworkHarness] role=%@ event=retry-started reason=local-rejection",
                        role.rawValue
                    )
                } else {
                    if let peerRejectionAcknowledgedAt {
                        guard Date().timeIntervalSince(peerRejectionAcknowledgedAt) >= 20,
                              !didStartRetry else { return }
                        didStartRetry = true
                        coordinator.retry()
                        NSLog(
                            "[Tessera][BootstrapNetworkHarness] role=%@ event=retry-started reason=peer-rejection",
                            role.rawValue
                        )
                        return
                    }
                    guard coordinator.peerRejectionNotice == message else {
                        fail("peer rejection did not produce its acknowledgement notice")
                        return
                    }
                    if peerRejectionObservedAt == nil {
                        peerRejectionObservedAt = Date()
                        NSLog(
                            "[Tessera][BootstrapNetworkHarness] role=%@ event=peer-rejection-notice visible=true",
                            role.rawValue
                        )
                        return
                    }
                    guard let peerRejectionObservedAt,
                          Date().timeIntervalSince(peerRejectionObservedAt) >= 60 else {
                        return
                    }
                    if peerRejectionAcknowledgedAt == nil {
                        coordinator.acknowledgePeerRejection()
                        peerRejectionAcknowledgedAt = Date()
                        NSLog(
                            "[Tessera][BootstrapNetworkHarness] role=%@ event=peer-rejection-notice acknowledged=true",
                            role.rawValue
                        )
                        return
                    }
                }
            } else {
                fail(message)
            }

        default:
            break
        }
    }

    private func complete(_ detail: String) {
        guard terminalResult == nil else { return }
        terminalResult = "COMPLETED · \(detail)"
        status = terminalResult!
        NSLog(
            "[Tessera][BootstrapNetworkHarness] role=%@ result=completed %@",
            role.rawValue,
            detail
        )
    }

    private func fail(_ message: String) {
        guard terminalResult == nil else { return }
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        terminalResult = "FAILED · \(sanitized)"
        status = terminalResult!
        NSLog(
            "[Tessera][BootstrapNetworkHarness] role=%@ result=failed error=%@",
            role.rawValue,
            sanitized
        )
        coordinator.cancel()
    }

    private static func describe(_ phase: BootstrapFlowPhase) -> String {
        switch phase {
        case .inactive: return "Inactive"
        case .welcome: return "Welcome"
        case .browsing: return "Browsing for the origin"
        case .offering: return "Offering over Bonjour"
        case .negotiating: return "Negotiating encrypted session"
        case .compareCode(_, _, let code): return "Comparing SAS \(code)"
        case .waitingForPeerCode(_, _, let code): return "Waiting for peer SAS \(code)"
        case .notifyingCodeRejection: return "Notifying peer of SAS rejection"
        case .awaitingRecipientPublicKey: return "Awaiting recipient public key"
        case .authorizingRecipientKey: return "Authorizing recipient device key"
        case .selectingGrants: return "Selecting in-memory grant"
        case .waitingForOriginApproval: return "Waiting for origin approval"
        case .authorizingOrigin: return "Authorizing in-memory transfer"
        case .transferring: return "Transferring encrypted manifest"
        case .completed: return "Completed"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private static let fixtureHostID = UUID(
        uuidString: "A1000000-0000-0000-0000-000000000001"
    )!

    private static let fixtureKnownHost: BootstrapKnownHostDescriptor = {
        let privateKey = Curve25519.Signing.PrivateKey()
        let authorizedKeysLine = KeyStore.ed25519AuthorizedKeysLine(
            publicKey: privateKey.publicKey,
            comment: "bootstrap-network-harness"
        )
        let keyString = authorizedKeysLine.split(separator: " ").prefix(2)
            .joined(separator: " ")
        let publicKey = try! NIOSSHPublicKey(openSSHPublicKey: keyString)
        return BootstrapKnownHostDescriptor(
            hostID: fixtureHostID,
            fingerprint: KnownHostsStore.fingerprint(of: publicKey),
            keyString: keyString,
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }()

    private static let fixtureManifest = BootstrapManifest(
        hosts: [
            BootstrapHostDescriptor(
                id: fixtureHostID,
                name: "Nearby harness host",
                address: "bootstrap.invalid",
                user: "harness",
                transport: .ssh,
                launchMode: .autoTmux,
                authenticationHint: .publicKey,
                hostKeyFingerprint: fixtureKnownHost.fingerprint
            )
        ],
        jumpChains: [],
        knownHosts: [fixtureKnownHost],
        appearance: BootstrapAppearanceSettings(
            colorScheme: "dark",
            accent: "blue",
            customAccentRGB: 0x0A84FF,
            monospacedFontName: "JetBrainsMono-Regular",
            terminalFontSize: 14,
            chromeMaterial: "frosted",
            cursorStyle: "block",
            cursorBlink: true,
            terminalThemeID: "default"
        ),
        settings: BootstrapGeneralSettings(
            scrollbackLines: 10_000,
            modifierBehavior: "oneShot",
            bellSoundEnabled: false,
            bellVisualEnabled: true,
            bellNotificationEnabled: false,
            accessoryBarKeys: [],
            filesReaperDays: 7,
            filesDefaultDestination: "temp"
        )
    )

    private static let fixturePublicKey: EnrollmentPublicKey = {
        var point = Data([0x04])
        point.append(Data(repeating: 0x5A, count: 64))
        var blob = Data()
        appendSSHString(Data(EnrollmentPublicKeyAlgorithm.secureEnclaveP256.rawValue.utf8), to: &blob)
        appendSSHString(Data("nistp256".utf8), to: &blob)
        appendSSHString(point, to: &blob)
        return EnrollmentPublicKey(
            id: UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!,
            displayName: "Nearby harness public key",
            algorithm: .secureEnclaveP256,
            blob: blob.base64EncodedString(),
            fingerprint: EnrollmentPublicKey.fingerprint(forSSHBlob: blob),
            protection: .secureEnclave
        )
    }()

    private static func appendSSHString(_ value: Data, to blob: inout Data) {
        var length = UInt32(value.count).bigEndian
        blob.append(Data(bytes: &length, count: 4))
        blob.append(value)
    }
}

struct BootstrapNetworkHarnessView: View {
    let harness: BootstrapNetworkHarness

    @ViewBuilder
    var body: some View {
        if harness.scenario.isRejection {
            BootstrapFlowView(coordinator: harness.coordinator)
                .task { await harness.run() }
        } else {
            VStack(spacing: 16) {
                Image(systemName: harness.terminalResult == nil ? "iphone.and.arrow.forward.inward" : "checkmark.circle")
                    .font(.system(size: 40))
                Text("Nearby Bootstrap Network Harness")
                    .font(.headline)
                Text("Role: \(harness.role.rawValue)")
                    .font(Typography.tesseraMono(size: 15))
                Text("Scenario: \(harness.scenario.rawValue)")
                    .font(Typography.tesseraMono(size: 15))
                Text(harness.status)
                    .multilineTextAlignment(.center)
                    .font(Typography.tesseraMono(size: 17))
            }
            .padding(32)
            .task { await harness.run() }
        }
    }
}
#endif
