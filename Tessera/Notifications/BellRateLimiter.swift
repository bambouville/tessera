import Foundation

actor BellRateLimiter {
    private var lastAdmitAt: [String: Date] = [:]

    func admit(key: String) async -> Bool {
        let interval = Date.now.timeIntervalSince(lastAdmitAt[key] ?? .distantPast)
        guard interval >= 2.0 else { return false }
        lastAdmitAt[key] = .now
        return true
    }
}
