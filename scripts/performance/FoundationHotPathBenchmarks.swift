import Foundation

private let sanitizationPatterns: [(String, String)] = [
    (
        #"(?i)\b(currentProfile|title)=.*?(?=\s+[A-Za-z][A-Za-z0-9_-]*=|$)"#,
        "$1=<redacted>"
    ),
    (
        #"(?i)\b(commandLine|command|preview|payload|prompt|summary|target|endpoint|user|address|remoteHost|names|process|profile|session|spec|matchProcess|pane_current_command|path|env|environment|error)=('.*?'|\".*?\"|[^\s]+)"#,
        "$1=<redacted>"
    ),
    (
        #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
        "<uuid>"
    ),
    (#"\S+@\S+"#, "<redacted-endpoint>"),
    (#"failed\([^)]*\)"#, "failed(<redacted>)"),
    (#" {2,}"#, " "),
]

private let cachedSanitizationRules: [(NSRegularExpression, String)] =
    sanitizationPatterns.map {
        (try! NSRegularExpression(pattern: $0.0), $0.1)
    }

@inline(never)
private func sanitizeCompilingRules(_ message: String) -> String {
    var value = normalized(message)
    for (pattern, template) in sanitizationPatterns {
        let expression = try! NSRegularExpression(pattern: pattern)
        value = replacingMatches(in: value, expression: expression, template: template)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

@inline(never)
private func sanitizeWithCachedRules(_ message: String) -> String {
    var value = normalized(message)
    for (expression, template) in cachedSanitizationRules {
        value = replacingMatches(in: value, expression: expression, template: template)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalized(_ message: String) -> String {
    message
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}

private func replacingMatches(
    in string: String,
    expression: NSRegularExpression,
    template: String
) -> String {
    expression.stringByReplacingMatches(
        in: string,
        range: NSRange(location: 0, length: (string as NSString).length),
        withTemplate: template
    )
}

@inline(never)
private func timestampWithNewFormatter() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

private let cachedTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

@inline(never)
private func timestampWithCachedFormatter() -> String {
    cachedTimestampFormatter.string(from: Date())
}

private func makeKnownHostsFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}

@inline(never)
private func datesWithNewFormatter(_ dates: [Date]) -> [String] {
    dates.map { date in
        makeKnownHostsFormatter().string(from: date)
    }
}

@inline(never)
private func datesWithCachedFormatter(
    _ dates: [Date],
    formatter: DateFormatter
) -> [String] {
    dates.map { formatter.string(from: $0) }
}

private enum MouseMode {
    case anyEvent
}

private struct ScrollPositionShape {
    let contentOffset: Double
    let viewportHeight: Double
    let contentHeight: Double
    let lineHeight: Double
    let usesAlternateBuffer: Bool
    let mouseMode: String
}

@inline(never)
private func captureScrollPositionShape(_ count: Int) -> Int {
    var checksum = 0
    for index in 0..<count {
        let value = ScrollPositionShape(
            contentOffset: Double(index),
            viewportHeight: 100,
            contentHeight: 200,
            lineHeight: 10,
            usesAlternateBuffer: false,
            mouseMode: String(describing: MouseMode.anyEvent)
        )
        checksum &+= Int(value.contentOffset)
        checksum &+= Int(value.viewportHeight + value.contentHeight + value.lineHeight)
        checksum &+= value.usesAlternateBuffer ? 1 : 0
        checksum &+= value.mouseMode.utf8.count
    }
    return checksum
}

private func timed(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let elapsed = start.duration(to: .now)
    return Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1e15
}

private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
}

private func measurePair(
    repeats: Int,
    before: () -> Void,
    after: () -> Void
) -> (before: Double, after: Double, beforeSamples: [Double], afterSamples: [Double]) {
    var beforeSamples: [Double] = []
    var afterSamples: [Double] = []
    for iteration in 0..<repeats {
        if iteration.isMultiple(of: 2) {
            beforeSamples.append(timed(before))
            afterSamples.append(timed(after))
        } else {
            afterSamples.append(timed(after))
            beforeSamples.append(timed(before))
        }
    }
    return (
        median(beforeSamples),
        median(afterSamples),
        beforeSamples,
        afterSamples
    )
}

private func sampleText(_ samples: [Double]) -> String {
    samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
}

private let repeats = 5
private let diagnosticIterations = 10_000
private let messages = [
    "terminal-output-burst surface=ssh wallMs=620.1 ingressChunks=812 ingressBytes=831488 rendererMs=31.2 source='pane-output' pane=%7 window=@2 generation=92",
    "connect result=failed durationMs=132 error='user@example.com refused endpoint=10.0.0.2 command=ssh'",
    "current-refresh sid=019fe90a-89f8-7112-a56f-391f3e6c4b16 reason=output result=resolved title=secret title profile=codex",
]

// Prewarm lazy Foundation state, then prove exact deterministic equivalence.
_ = sanitizeWithCachedRules(messages[0])
_ = timestampWithCachedFormatter()
for message in messages {
    precondition(sanitizeCompilingRules(message) == sanitizeWithCachedRules(message))
    let result = measurePair(
        repeats: repeats,
        before: {
            for _ in 0..<diagnosticIterations {
                _ = sanitizeCompilingRules(message)
            }
        },
        after: {
            for _ in 0..<diagnosticIterations {
                _ = sanitizeWithCachedRules(message)
            }
        }
    )
    print(
        "sanitize bytes=\(message.utf8.count) iterations=\(diagnosticIterations) "
            + "beforeMedianMs=\(String(format: "%.3f", result.before)) "
            + "afterMedianMs=\(String(format: "%.3f", result.after)) exact=true "
            + "beforeSamplesMs=\(sampleText(result.beforeSamples)) "
            + "afterSamplesMs=\(sampleText(result.afterSamples))"
    )
}

let timestampIterations = 25_000
let timestampResult = measurePair(
    repeats: repeats,
    before: {
        for _ in 0..<timestampIterations { _ = timestampWithNewFormatter() }
    },
    after: {
        for _ in 0..<timestampIterations { _ = timestampWithCachedFormatter() }
    }
)
print(
    "timestamp iterations=\(timestampIterations) "
        + "beforeMedianMs=\(String(format: "%.3f", timestampResult.before)) "
        + "afterMedianMs=\(String(format: "%.3f", timestampResult.after)) "
        + "beforeSamplesMs=\(sampleText(timestampResult.beforeSamples)) "
        + "afterSamplesMs=\(sampleText(timestampResult.afterSamples))"
)

for count in [100, 1_000, 10_000] {
    let dates = (0..<count).map {
        Date(timeIntervalSince1970: Double(1_700_000_000 + $0 * 86_400))
    }
    let formatter = makeKnownHostsFormatter()
    precondition(
        datesWithNewFormatter(dates)
            == datesWithCachedFormatter(dates, formatter: formatter)
    )
    let result = measurePair(
        repeats: repeats,
        before: { _ = datesWithNewFormatter(dates) },
        after: { _ = datesWithCachedFormatter(dates, formatter: formatter) }
    )
    print(
        "known-host-dates count=\(count) "
            + "beforeMedianMs=\(String(format: "%.3f", result.before)) "
            + "afterMedianMs=\(String(format: "%.3f", result.after)) exact=true "
            + "beforeSamplesMs=\(sampleText(result.beforeSamples)) "
            + "afterSamplesMs=\(sampleText(result.afterSamples))"
    )
}

let scrollSnapshotIterations = 1_000_000
var scrollChecksum = 0
var scrollSamples: [Double] = []
for _ in 0..<repeats {
    scrollSamples.append(timed {
        scrollChecksum &+= captureScrollPositionShape(scrollSnapshotIterations)
    })
}
print(
    "scroll-position-shape iterations=\(scrollSnapshotIterations) "
        + "medianMs=\(String(format: "%.3f", median(scrollSamples))) "
        + "checksum=\(scrollChecksum) samplesMs=\(sampleText(scrollSamples))"
)
