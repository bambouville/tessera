import Foundation
import TmuxControlCore

public enum TmuxTargetValidation {
    public static let maximumSessionNameBytes = TmuxSessionName.maximumUTF8Length

    public static func isSafeSessionName(_ name: String) -> Bool {
        TmuxSessionName.isValid(name)
    }

    public static func isSessionID(_ value: String) -> Bool {
        SessionId(wireValue: value) != nil
    }

    public static func isWindowID(_ value: String) -> Bool {
        WindowId(wireValue: value) != nil
    }

    public static func isPaneID(_ value: String) -> Bool {
        PaneId(wireValue: value) != nil
    }

    public static func parseNumericID(
        _ value: String,
        prefix: Character,
        maximumDigits: Int
    ) -> UInt64? {
        guard value.first == prefix else { return nil }
        let digits = value.dropFirst()
        guard !digits.isEmpty,
              digits.count <= maximumDigits,
              digits.allSatisfy(\.isNumber)
        else { return nil }
        return UInt64(digits)
    }

    public static func displaySessionQuery(name: String) throws -> String {
        let validated: TmuxSessionName
        do {
            validated = try TmuxSessionName(validating: name)
        } catch {
            throw TmuxTargetError.invalidSessionName
        }
        return TmuxFixedQuery.displaySessionAttachment(validated)
    }
}

public enum TmuxTargetError: Error, Equatable, Sendable {
    case invalidSessionName
    case invalidSessionID
    case invalidWindowID
    case invalidPaneID
}
