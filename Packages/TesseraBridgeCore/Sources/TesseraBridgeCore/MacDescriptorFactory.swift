import Foundation
import TesseraDomainCore
import TesseraProtocolCore

public struct MacContinuationConfiguration: Equatable, Sendable {
    public let hostID: UUID
    public let displayName: String
    public let user: String
    public let address: String
    public let port: UInt16
    public let tmuxSessionName: String
    public let hostKeyFingerprint: String?

    public init(
        hostID: UUID,
        displayName: String,
        user: String,
        address: String,
        port: UInt16 = 22,
        tmuxSessionName: String,
        hostKeyFingerprint: String? = nil
    ) {
        self.hostID = hostID
        self.displayName = displayName
        self.user = user
        self.address = address
        self.port = port
        self.tmuxSessionName = tmuxSessionName
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

public enum MacDescriptorFactoryError: Error, Equatable, Sendable {
    case emptyDisplayName
    case fieldTooLong(field: String, maximumUTF8Length: Int)
    case addressContainsWhitespace
    case nonRoutableAddress
    case invalidTmuxSessionName
}

public enum MacDescriptorFactory {
    public static let maximumDisplayNameBytes = 255
    public static let maximumEndpointFieldBytes = 255

    public static func makeDescriptor(
        from configuration: MacContinuationConfiguration
    ) throws -> ContinuationDescriptorV1 {
        let displayName = configuration.displayName.trimmed
        let user = configuration.user.trimmed
        let address = configuration.address.trimmed
        let tmuxSessionName = configuration.tmuxSessionName.trimmed
        let fingerprint = configuration.hostKeyFingerprint?.trimmed.nilIfEmpty

        guard !displayName.isEmpty else {
            throw MacDescriptorFactoryError.emptyDisplayName
        }
        try checkLength(
            displayName,
            field: "displayName",
            maximum: maximumDisplayNameBytes
        )
        try checkLength(user, field: "user", maximum: maximumEndpointFieldBytes)
        try checkLength(address, field: "address", maximum: maximumEndpointFieldBytes)
        guard !address.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
        else {
            throw MacDescriptorFactoryError.addressContainsWhitespace
        }
        guard !isNonRoutable(address) else {
            throw MacDescriptorFactoryError.nonRoutableAddress
        }
        guard TmuxTargetValidation.isSafeSessionName(tmuxSessionName) else {
            throw MacDescriptorFactoryError.invalidTmuxSessionName
        }

        let sharedEndpoint = HostEndpoint(
            user: user,
            address: address,
            port: configuration.port
        )
        _ = try sharedEndpoint.validated()

        let descriptor = ContinuationDescriptorV1(
            endpoint: ContinuationEndpointV1(
                hostID: configuration.hostID,
                name: displayName,
                user: user,
                address: address,
                port: Int(configuration.port),
                transport: .ssh,
                hostKeyFingerprint: fingerprint
            ),
            launchMode: .pinnedTmux,
            tmuxSessionName: tmuxSessionName,
            via: []
        )
        try descriptor.validate()
        return descriptor
    }

    public static func makePublicationBytes(
        from configuration: MacContinuationConfiguration
    ) throws -> Data {
        try ContinuationActivityCodec.encode(makeDescriptor(from: configuration))
    }

    private static func checkLength(
        _ value: String,
        field: String,
        maximum: Int
    ) throws {
        guard value.utf8.count <= maximum else {
            throw MacDescriptorFactoryError.fieldTooLong(
                field: field,
                maximumUTF8Length: maximum
            )
        }
    }

    private static func isNonRoutable(_ address: String) -> Bool {
        let normalized = address.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if normalized == "localhost"
            || normalized == "::1"
            || normalized == "::"
            || normalized == "0.0.0.0"
            || normalized == "*" {
            return true
        }
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.first == "127"
    }
}

extension MacDescriptorFactoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDisplayName:
            "Enter a name for this Mac."
        case .fieldTooLong(let field, let maximum):
            "\(field) must be at most \(maximum) bytes."
        case .addressContainsWhitespace:
            "The SSH address cannot contain whitespace."
        case .nonRoutableAddress:
            "Choose an SSH address reachable from the iPhone or iPad, not a loopback or wildcard address."
        case .invalidTmuxSessionName:
            "Use a tmux session name containing only letters, numbers, period, underscore, or hyphen."
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
