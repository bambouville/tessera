import Foundation

/// Single source for the app's version strings, read from the bundle.
public enum AppVersion {
    public static var marketing: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    public static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}
