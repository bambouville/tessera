import Testing
@testable import Tessera

struct ArtifactDiffParsingTests {
    @Test func parsesUnifiedHunksAndBothLineNumberColumns() {
        let parsed = ArtifactDiffParser.parse("""
        diff --git a/test.swift b/test.swift
        --- a/test.swift
        +++ b/test.swift
        @@ -41,3 +41,4 @@ final class Test {
             let same = 1
        -    let old = 2
        +    let new = 3
        +    let extra = 4
             }
        @@ -88 +100 @@ extension Test {
        -old
        +new
        """)
        #expect(parsed.addedLineCount == 3)
        #expect(parsed.removedLineCount == 2)
        #expect(parsed.lines.prefix(3).allSatisfy { $0.kind == .fileHeader })
        let changes = parsed.lines.filter { [.context, .added, .removed].contains($0.kind) }
        #expect(changes.map(\.oldLineNumber) == [41, 42, nil, nil, 43, 88, nil])
        #expect(changes.map(\.newLineNumber) == [41, nil, 42, 43, 44, nil, 100])
        #expect(changes[0].text == "    let same = 1")
        #expect(changes[1].text == "    let old = 2")
        #expect(parsed.lineNumberDigits == 3)
        #expect(Set(parsed.lines.map(\.id)).count == parsed.lines.count)
    }

    /// An agent edit known only by its old and new text starts at 0.
    @Test func aHunkWithNoPositionColoursItsLinesUnnumbered() {
        let parsed = ArtifactDiffParser.parse("@@ -0,1 +0,2 @@\n-old\n+new\n+extra\n")
        #expect(parsed.lines.map(\.kind) == [.hunk, .removed, .added, .added])
        #expect(parsed.lines.first?.text == "⋯")
        #expect(parsed.lines.allSatisfy { $0.oldLineNumber == nil && $0.newLineNumber == nil })
        // An edit that only removes, or only adds, is no position either.
        #expect(ArtifactDiffParser.parse("@@ -0,2 +0,0 @@\n-a\n-b\n").lines.first?.text == "⋯")
        #expect(ArtifactDiffParser.parse("@@ -0,0 +1,2 @@\n+a\n+b\n").lines.first?.text == "@@ -0,0 +1,2 @@")
        #expect(parsed.addedLineCount == 2)
        #expect(parsed.removedLineCount == 1)
    }

    @Test func zeroLengthRangesAndNoNewlineNoticesDoNotConsumeNumbers() {
        let parsed = ArtifactDiffParser.parse(#"""
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +first
        +second
        \ No newline at end of file
        diff --git a/old.txt b/old.txt
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -first
        -second
        \ No newline at end of file
        """#)
        #expect(parsed.addedLineCount == 2)
        #expect(parsed.removedLineCount == 2)
        #expect(parsed.lines.filter { $0.kind == .added }.map(\.newLineNumber) == [1, 2])
        #expect(parsed.lines.filter { $0.kind == .removed }.map(\.oldLineNumber) == [1, 2])
        #expect(parsed.lines.filter { $0.kind == .notice }.allSatisfy { $0.oldLineNumber == nil && $0.newLineNumber == nil })
    }

    @Test func markerLookingContentIsStillCodeInsideAHunk() {
        let parsed = ArtifactDiffParser.parse("@@ -1,2 +1,2 @@\n--- old text\n+++ new text\n \n")
        #expect(parsed.lines.map(\.kind) == [.hunk, .removed, .added, .context])
        #expect(parsed.lines[1].text == "-- old text")
        #expect(parsed.lines[2].text == "++ new text")
        #expect(parsed.lines[3].text.isEmpty)
        #expect(parsed.lines[3].oldLineNumber == 2)
        #expect(parsed.lines[3].newLineNumber == 2)
    }

    @Test func emptyCRLFAndBinaryDiffsPreserveReadableMetadata() {
        #expect(ArtifactDiffParser.parse("").lines.isEmpty)
        let parsed = ArtifactDiffParser.parse("@@ -1 +1 @@\r\n-a\r\n+b\r\n")
        #expect(parsed.lines.count == 3)
        #expect(parsed.lines.map(\.text) == ["@@ -1 +1 @@", "a", "b"])
        let binary = ArtifactDiffParser.parse("Binary files a/image.png and b/image.png differ\n")
        #expect(binary.lines.first?.kind == .metadata)
        #expect(binary.addedLineCount == 0)
        #expect(binary.removedLineCount == 0)
    }

    @Test func unicodeLineSeparatorsInsideSourceStayInTheSameDiffLine() {
        let code = "const s = \"one\u{2028}two\u{2029}three\u{0085}four\";"
        let parsed = ArtifactDiffParser.parse("@@ -0,0 +1 @@\n+" + code + "\n")
        #expect(parsed.lines.count == 2)
        #expect(parsed.lines.last?.kind == .added)
        #expect(parsed.lines.last?.text == code)
        #expect(parsed.lines.last?.newLineNumber == 1)
    }

    @Test func malformedAndOverflowingHunksNeverInventNumbers() {
        for header in ["@@ broken @@", "@@ -x +1 @@", "@@ -1, +1 @@", "@@ -1,-2 +1 @@", "@@ -999999999999999999999999 +1 @@", "@@ -\(Int.max) +1 @@", "@@@ -1 -1 +1 @@@"] {
            let parsed = ArtifactDiffParser.parse(header + "\n-old\n+new\n")
            #expect(parsed.lines.allSatisfy { $0.oldLineNumber == nil && $0.newLineNumber == nil })
            #expect(parsed.addedLineCount == 0)
            #expect(parsed.removedLineCount == 0)
        }
        let truncated = ArtifactDiffParser.parse("@@ -5,4 +7,4 @@\n same\ninvalid metadata\n+unknown\n")
        #expect(truncated.lines[1].oldLineNumber == 5)
        #expect(truncated.lines[2].kind == .metadata)
        #expect(truncated.lines[3].newLineNumber == nil)
    }

    @Test func thousandsOfLinesKeepSequentialNumbersWithoutTruncation() {
        let count = 5_000
        let source = "@@ -0,0 +1,\(count) @@\n" + (1...count).map { "+line \($0)\n" }.joined()
        let parsed = ArtifactDiffParser.parse(source)
        #expect(parsed.lines.count == count + 1)
        #expect(parsed.addedLineCount == count)
        #expect(parsed.removedLineCount == 0)
        #expect(parsed.lines.last?.newLineNumber == count)
        #expect(parsed.lines.last?.text == "line \(count)")
        #expect(parsed.lineNumberDigits == 4)
    }
}
