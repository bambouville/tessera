import LocalAuthentication

enum BiometricResult: Sendable {
    case authenticated
    case userCancelled
    case unavailable(reason: String)
    case failed(reason: String)
}

enum BiometricGate {
    /// Prompts using .deviceOwnerAuthentication policy (Face ID first, falls back to passcode).
    /// reason is the user-facing string shown in the system sheet.
    static func evaluate(reason: String) async -> BiometricResult {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return map(error: error, fallback: .unavailable(reason: "Device owner authentication is unavailable."))
        }

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            return authenticated
                ? .authenticated
                : .failed(reason: "Authentication failed.")
        } catch {
            return map(error: error, fallback: .failed(reason: "Authentication failed."))
        }
    }

    private static func map(error: Error?, fallback: BiometricResult) -> BiometricResult {
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
