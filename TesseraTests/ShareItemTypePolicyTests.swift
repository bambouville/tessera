import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Tessera

/// The share sheet only offers Tessera for attachments its activation rule
/// matches, and the extension then has to know what to do with what arrives.
/// These pin the second half; the rule itself lives in
/// `TesseraShareExtension/Info.plist` and must accept the same types.
struct ShareItemTypePolicyTests {

    @Test func acceptsPhotoTypes() {
        #expect(ShareItemTypePolicy.isSupported(UTType.jpeg.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.png.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.heic.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.gif.identifier))
    }

    /// The reported gap: a video shared straight from Photos was rejected,
    /// so it had to be saved to Files and uploaded from there.
    @Test func acceptsVideoTypes() {
        #expect(ShareItemTypePolicy.isSupported(UTType.movie.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.quickTimeMovie.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.mpeg4Movie.identifier))
        #expect(ShareItemTypePolicy.isSupported(UTType.video.identifier))
    }

    @Test func rejectsUnrelatedAndUnknownTypes() {
        #expect(!ShareItemTypePolicy.isSupported(UTType.plainText.identifier))
        #expect(!ShareItemTypePolicy.isSupported(UTType.pdf.identifier))
        #expect(!ShareItemTypePolicy.isSupported(UTType.fileURL.identifier))
        #expect(!ShareItemTypePolicy.isSupported("not.a.real.type"))
    }

    /// A Live Photo registers a still and a movie. It arrived as the still
    /// before video was accepted, and must keep doing so.
    @Test func prefersTheStillOfALivePhoto() {
        let registered = [UTType.quickTimeMovie.identifier, UTType.jpeg.identifier]
        #expect(ShareItemTypePolicy.preferredTypeIdentifiers(from: registered)
            == [UTType.jpeg.identifier, UTType.quickTimeMovie.identifier])
    }

    @Test func dropsUnsupportedRepresentationsAndKeepsVideoOrder() {
        let registered = [
            UTType.plainText.identifier,
            UTType.movie.identifier,
            UTType.fileURL.identifier,
            UTType.mpeg4Movie.identifier,
        ]
        #expect(ShareItemTypePolicy.preferredTypeIdentifiers(from: registered)
            == [UTType.movie.identifier, UTType.mpeg4Movie.identifier])
    }

    @Test func acceptsNothingFromAnEmptyProvider() {
        #expect(ShareItemTypePolicy.preferredTypeIdentifiers(from: []).isEmpty)
    }
}
