// TesseraShareExtension/ShareItemTypePolicy.swift
// Which shared attachments Tessera accepts, and in what order it tries
// their representations.
//
// Kept pure and separate from the view controller so it can be tested, and
// so it stays in step with `Info.plist`'s NSExtensionActivationRule — the
// rule decides whether Tessera is *offered* in the share sheet, this decides
// what it does with what arrives. The two must accept the same things.

import Foundation
import UniformTypeIdentifiers

enum ShareItemTypePolicy {
    /// Content Tessera can stage and upload. Images and video only: the
    /// share sheet route exists to get camera-roll media onto a host without
    /// a round trip through Files.
    static func isSupported(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// Lower sorts first. Images outrank video so a Live Photo — which
    /// registers both a still and a movie — still arrives as the still,
    /// exactly as it did before video was accepted at all.
    static func score(_ identifier: String) -> Int {
        guard let type = UTType(identifier) else { return 100 }
        if type.conforms(to: .image) { return 0 }
        if type.conforms(to: .movie) { return 1 }
        return 100
    }

    /// Registered types worth trying, best first.
    static func preferredTypeIdentifiers(from registered: [String]) -> [String] {
        registered
            .filter(isSupported)
            .sorted { score($0) < score($1) }
    }
}
