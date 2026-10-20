import Foundation
import TesseraProtocolCore
import TmuxControlCore

public struct MacLocalEndpointSnapshot: Equatable, Sendable {
    public let hostID: UUID
    public let user: String
    public let addressCandidates: Set<String>
    public let sshHostKeyFingerprints: Set<String>

    public init(
        hostID: UUID,
        user: String,
        addressCandidates: Set<String>,
        sshHostKeyFingerprints: Set<String>
    ) {
        self.hostID = hostID
        self.user = user
        self.addressCandidates = Set(addressCandidates.map(Self.normalizeAddress))
        self.sshHostKeyFingerprints = Set(
            sshHostKeyFingerprints.map(Self.normalizeFingerprint)
        )
    }

    static func normalizeAddress(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
    }

    static func normalizeFingerprint(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct MacLocalTmuxAttachIntent: Equatable, Sendable {
    public let descriptor: ContinuationDescriptorV1
    public let sessionName: TmuxSessionName
    public let matchedByStableHostID: Bool

    public init(
        descriptor: ContinuationDescriptorV1,
        sessionName: TmuxSessionName,
        matchedByStableHostID: Bool
    ) {
        self.descriptor = descriptor
        self.sessionName = sessionName
        self.matchedByStableHostID = matchedByStableHostID
    }
}

public enum MacLocalContinuationRejection: Error, Equatable, Sendable {
    case localUserMismatch
    case localHostKeyMismatch
    case localRouteUnsupported
    case localSessionMissing
}

public enum MacLocalContinuationDisposition: Equatable, Sendable {
    case local(MacLocalTmuxAttachIntent)
    case remote(ContinuationDescriptorV1)
    case rejected(MacLocalContinuationRejection)
}

/// Classifies an incoming mobile continuation without trusting a hostname or
/// host-key hint on its own. The platform adapter still has to prove the exact
/// local tmux session exists before it may launch iTerm2.
public enum MacLocalContinuationResolver {
    public static func resolve(
        encodedDescriptor bytes: Data,
        local: MacLocalEndpointSnapshot
    ) throws -> MacLocalContinuationDisposition {
        resolve(try ContinuationActivityCodec.decode(bytes), local: local)
    }

    public static func resolve(
        _ descriptor: ContinuationDescriptorV1,
        local: MacLocalEndpointSnapshot
    ) -> MacLocalContinuationDisposition {
        guard descriptor.via.isEmpty else {
            if descriptor.hostID == local.hostID {
                return .rejected(.localRouteUnsupported)
            }
            return .remote(descriptor)
        }
        guard let rawSessionName = descriptor.tmuxSessionName,
              let sessionName = try? TmuxSessionName(validating: rawSessionName) else {
            if descriptor.hostID == local.hostID {
                return .rejected(.localSessionMissing)
            }
            return .remote(descriptor)
        }

        let userMatches = descriptor.user == local.user
        if descriptor.hostID == local.hostID {
            guard userMatches else { return .rejected(.localUserMismatch) }
            if let fingerprint = descriptor.hostKeyFingerprint,
               !local.sshHostKeyFingerprints.isEmpty,
               !local.sshHostKeyFingerprints.contains(
                   MacLocalEndpointSnapshot.normalizeFingerprint(fingerprint)
               ) {
                return .rejected(.localHostKeyMismatch)
            }
            return .local(
                MacLocalTmuxAttachIntent(
                    descriptor: descriptor,
                    sessionName: sessionName,
                    matchedByStableHostID: true
                )
            )
        }

        let address = MacLocalEndpointSnapshot.normalizeAddress(descriptor.address)
        guard local.addressCandidates.contains(address) else {
            return .remote(descriptor)
        }
        guard userMatches else { return .rejected(.localUserMismatch) }
        guard let fingerprint = descriptor.hostKeyFingerprint,
              local.sshHostKeyFingerprints.contains(
                  MacLocalEndpointSnapshot.normalizeFingerprint(fingerprint)
              ) else {
            return .rejected(.localHostKeyMismatch)
        }
        return .local(
            MacLocalTmuxAttachIntent(
                descriptor: descriptor,
                sessionName: sessionName,
                matchedByStableHostID: false
            )
        )
    }
}

public enum MacGridAuthorityStampFactory {
    public static func wireValue(
        deviceID: UUID,
        generation: UInt64,
        displayName: String = "Mac"
    ) -> String {
        TmuxGridAuthorityStamp(
            identity: TmuxGridAuthorityIdentity(
                id: deviceID.uuidString,
                displayName: displayName
            ),
            generation: generation
        ).wireValue
    }
}
