#if DEBUG
import SwiftUI
import TesseraCore
import Crypto

/// Real QR/TCP/crypto and production presentation, with public-only fixtures.
/// No remote connection or grant is made by this UI review harness.
struct PairingReviewHarness: View {
    @State private var coordinator = CrossDevicePairingCoordinator()
    @State private var started = false

    var body: some View {
        ZStack(alignment: .bottom) {
            CrossDevicePairingView(coordinator: coordinator)
            Text(verbatim: "QR review fixture · no remote access")
                .font(.caption2).foregroundStyle(.secondary).padding(8)
        }
        .environment(\.designTokens, DesignTokens.make(mode: .dark, accent: .blue))
        .preferredColorScheme(.dark)
        .task {
            guard !started else { return }
            started = true
            if UIDevice.current.userInterfaceIdiom == .pad {
                (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                    .requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft))
            }
            coordinator.configure(adapters: CrossDevicePairingPlatformAdapters(
                receiveDescriptor: { _, _ in nil },
                cancelDescriptor: { _ in },
                recipientKey: {
                    let key = Curve25519.Signing.PrivateKey()
                    let line = KeyStore.ed25519AuthorizedKeysLine(publicKey: key.publicKey, comment: "QR review")
                    let blob = String(line.split(separator: " ")[1])
                    return DevicePublicKeyDescriptorV2(id: UUID(), displayName: "Review iPad", algorithm: .ed25519,
                        sshBlob: blob, fingerprint: DevicePublicKeyValidator.fingerprint(forSSHBlob: Data(base64Encoded: blob)!),
                        protectionClaim: .softwareExportable)
                },
                exportManifest: { _ in Self.manifest },
                importManifest: { manifest, _ in manifest.hosts.map(\.id) },
                verifyGrants: { request in
                    request.acceptance.acceptedHostIDs.map {
                        BootstrapHostGrantResultV1(hostID: $0, status: .skipped)
                    }
                },
                recordAccess: { _, _, _ in },
                freshOwnerApproval: { _ in Date() }
            ))
            if ProcessInfo.processInfo.environment["TESSERA_QR_REVIEW"] == "receive" {
                coordinator.beginScanning()
            } else {
                coordinator.beginOrigin(purpose: .bootstrap)
            }
        }
    }

    static var manifest: BootstrapManifestV2 {
        let base = BootstrapNetworkHarness.fixtureManifest
        let names = ["Development", "Build server", "Staging", "Archive"]
        let hosts = names.enumerated().map { index, name in
            BootstrapHostDescriptor(
                id: UUID(uuidString: String(format: "B1000000-0000-0000-0000-%012d", index + 1))!,
                name: name, address: "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).invalid",
                user: "developer", transport: index < 2 ? .ssh : .mosh,
                launchMode: index % 2 == 0 ? .customCommand : .pinnedTmux,
                tmuxSessionName: index % 2 == 0 ? nil : "workspace",
                authenticationHint: .password, notes: "QR review fixture"
            )
        }
        return BootstrapManifestV2(hosts: hosts, jumpChains: [], appearance: base.appearance, settings: base.settings)
    }
}
#endif
