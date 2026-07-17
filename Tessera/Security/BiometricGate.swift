import LocalAuthentication

enum BiometricResult: Sendable {
    case authenticated
    case userCancelled
    case unavailable(reason: String)
    case failed(reason: String)
}

/// An evaluated LocalAuthentication context. Protected Keychain reads and
/// Secure Enclave key reconstruction must reuse this exact context so the OS
/// access-control check is part of key use, rather than an unrelated app-level
/// prompt immediately before an unprotected read.
final class BiometricAuthorization: @unchecked Sendable {
    let context: LAContext

    init(context: LAContext) {
        self.context = context
    }
}

enum BiometricAuthorizationResult: @unchecked Sendable {
    case authenticated(BiometricAuthorization)
    case userCancelled
    case unavailable(reason: String)
    case failed(reason: String)

    var result: BiometricResult {
        switch self {
        case .authenticated:
            return .authenticated
        case .userCancelled:
            return .userCancelled
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}

enum BiometricGate {
    /// Tessera's product policy is owner presence, not biometric-only: Face ID
    /// is preferred and the device passcode remains an allowed fallback.
    static func evaluate(reason: String) async -> BiometricResult {
        (await evaluateForKeyUse(reason: reason)).result
    }

    /// Returns the successfully evaluated LAContext so a protected Keychain or
    /// Secure Enclave operation can bind its OS-enforced ACL check to the same
    /// authorization. Cancellation invalidates the context and dismisses an
    /// in-progress system sheet.
    static func evaluateForKeyUse(reason: String) async -> BiometricAuthorizationResult {
        let evaluation = BiometricEvaluation(reason: reason)
        return await withTaskCancellationHandler {
            await evaluation.run()
        } onCancel: {
            evaluation.cancel()
        }
    }

    fileprivate static func map(
        error: Error?,
        fallback: BiometricAuthorizationResult
    ) -> BiometricAuthorizationResult {
        guard let error else { return fallback }
        let nsError = error as NSError
        let reason = nsError.localizedDescription

        switch LAError.Code(rawValue: nsError.code) {
        case .userCancel, .systemCancel, .appCancel:
            return .userCancelled
        case .biometryNotEnrolled, .biometryNotAvailable, .passcodeNotSet:
            return .unavailable(reason: reason)
        case .authenticationFailed:
            return .failed(reason: reason)
        default:
            return .failed(reason: reason)
        }
    }
}

private final class BiometricEvaluation: @unchecked Sendable {
    private let context = LAContext()
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func cancel() {
        context.invalidate()
    }

    func run() async -> BiometricAuthorizationResult {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return BiometricGate.map(
                error: error,
                fallback: .unavailable(
                    reason: "Device owner authentication is unavailable."
                )
            )
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            guard authenticated else {
                return .failed(reason: "Authentication failed.")
            }
            return .authenticated(BiometricAuthorization(context: context))
        } catch {
            return BiometricGate.map(
                error: error,
                fallback: .failed(reason: "Authentication failed.")
            )
        }
    }
}
