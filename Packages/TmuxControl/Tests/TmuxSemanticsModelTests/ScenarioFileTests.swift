import Foundation
import XCTest
@testable import TmuxSemanticsModel

/// The scenario scripts in `Scenarios/`, which the differential lane also
/// replays against real tmux (scripts/integration/run-tmux-model-differential.sh).
final class ScenarioFileTests: XCTestCase {
    static let scenarioDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Scenarios")

    static func scenarioFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: scenarioDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "scenario" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Every scenario's model-only expectations hold on every version it
    /// declares, at nominal timing, without unmodelled input.
    func testEveryScenarioHoldsInTheModel() throws {
        let files = try Self.scenarioFiles()
        XCTAssertGreaterThanOrEqual(files.count, 10, "scenario files went missing")
        var runs = 0
        for file in files {
            let script = try ScenarioScript.parse(String(contentsOf: file, encoding: .utf8))
            XCTAssertEqual(script.name, file.deletingPathExtension().lastPathComponent, "scenario name must match its file")
            for version in script.versions {
                let transcript = ScenarioRunner.run(script, version: version)
                XCTAssertEqual(transcript.failures, [], "\(script.name) on \(version.rawValue)")
                XCTAssertEqual(transcript.unsupported, [], "\(script.name) on \(version.rawValue)")
                XCTAssertFalse(transcript.steps.isEmpty)
                runs += 1
            }
        }
        XCTAssertGreaterThan(runs, 0)
    }

    /// The expectations are live: a wrong expectation fails.
    func testWrongExpectationFails() throws {
        let script = try ScenarioScript.parse("""
        scenario mutation
        session O 80x24 w0
        control device O
        send device refresh-client -C 100,30
        expect-size w0 101x30
        expect device %layout-change {w0} *,100x30,0,0,*
        expect-not device %layout-change *
        expect-latest w0 nobody
        """)
        let transcript = ScenarioRunner.run(script, version: .v3_4)
        XCTAssertEqual(transcript.failures.count, 3, "\(transcript.failures)")
    }

    func testParserRejectsMalformedScenarios() {
        let cases: [(String, String)] = [
            ("session O 80x24 w0", "the first directive must be `scenario NAME`"),
            ("scenario s\ncontrol c O", "unknown session O"),
            ("scenario s\nsession O 80x24 w0\ncontrol c O\nwindow O w1", "setup must come before the first client"),
            ("scenario s\nsession O 80x24 w0\ntty t O 80x24\nsend t display -p x", "t is a terminal client"),
            ("scenario s\nsession O 80x24 w0\ncontrol c O\ndetach c\nsend c display -p x", "client c has detached"),
            ("scenario s\nsession O 80,24 w0", "bad size 80,24 (want WxH)"),
            ("scenario s\nversions 3.5\nsession O 80x24 w0", "unknown version 3.5"),
            ("scenario s\nsession O 80x24 w0\nbogus", "unknown directive bogus"),
            ("scenario s\nsession O 80x24 w0", "no action steps"),
        ]
        for (text, message) in cases {
            XCTAssertThrowsError(try ScenarioScript.parse(text), text) { error in
                XCTAssertEqual((error as? ScenarioError)?.message, message, text)
            }
        }
    }

    // MARK: Differential lane hooks (env-gated)

    /// Dry-run step of the differential lane: writes each scenario's nominal
    /// model transcript for every modelled version (the lane runs every
    /// scenario on every tmux; expectations must hold on declared versions).
    func testExportNominalTranscripts() throws {
        guard let directory = ProcessInfo.processInfo.environment["TESSERA_TMUX_MODEL_EXPORT_DIR"] else {
            throw XCTSkip("set TESSERA_TMUX_MODEL_EXPORT_DIR to export model transcripts")
        }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let selected = Set((ProcessInfo.processInfo.environment["TESSERA_TMUX_MODEL_SCENARIOS"] ?? "")
            .split(separator: ",").map(String.init))
        var written = 0
        for file in try Self.scenarioFiles() {
            let script = try ScenarioScript.parse(String(contentsOf: file, encoding: .utf8))
            if !selected.isEmpty, !selected.contains(script.name) { continue }
            for version in TmuxVersion.allCases {
                let transcript = ScenarioRunner.run(script, version: version)
                if script.versions.contains(version) {
                    XCTAssertEqual(transcript.failures, [], "\(script.name) on \(version.rawValue)")
                }
                XCTAssertEqual(transcript.unsupported, [], "\(script.name) on \(version.rawValue)")
                let data = try Self.encoder.encode(transcript)
                try data.write(to: output.appendingPathComponent("\(script.name)--\(version.rawValue).json"))
                written += 1
            }
        }
        XCTAssertGreaterThan(written, 0, "no scenario was exported")
    }

    /// Live step of the differential lane: replays every scenario run that the
    /// real-tmux runner recorded (`real-*.json`) on the model, at the recorded
    /// step times and the server's version, and writes `model-*.json`.
    func testReplayRecordedRuns() throws {
        guard let directory = ProcessInfo.processInfo.environment["TESSERA_TMUX_MODEL_REPLAY_DIR"] else {
            throw XCTSkip("set TESSERA_TMUX_MODEL_REPLAY_DIR to replay recorded runs")
        }
        let folder = URL(fileURLWithPath: directory)
        let inputs = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("real-") && $0.pathExtension == "json" }
        XCTAssertFalse(inputs.isEmpty, "no real-*.json in \(directory)")
        var replayed = 0
        for input in inputs {
            let recorded = try JSONDecoder().decode(RecordedResult.self, from: Data(contentsOf: input))
            var runs: [ReplayedRun] = []
            for run in recorded.runs {
                guard let mapping = TmuxVersion.forServerVersion(run.version) else {
                    XCTFail("\(input.lastPathComponent): no model for \(run.version)")
                    continue
                }
                var transcripts: [ScenarioTranscript] = []
                for scenario in run.scenarios where scenario.status == "ok" {
                    let script = try ScenarioScript.parse(scenario.source)
                    var timeline: [Int: StepTiming] = [:]
                    for step in scenario.steps ?? [] {
                        timeline[step.index] = StepTiming(start: step.start, read: step.read)
                    }
                    transcripts.append(ScenarioRunner.run(script, version: mapping.version, timeline: timeline))
                    replayed += 1
                }
                runs.append(ReplayedRun(tmux: run.tmux, version: run.version, modelVersion: mapping.version.rawValue, exact: mapping.exact, scenarios: transcripts))
            }
            let name = "model-" + input.lastPathComponent.dropFirst("real-".count)
            try Self.encoder.encode(ReplayedResult(runs: runs)).write(to: folder.appendingPathComponent(String(name)))
        }
        XCTAssertGreaterThan(replayed, 0, "no recorded scenario was replayed")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

/// What scripts/integration/remote/tmux-model-runner.py prints.
struct RecordedResult: Decodable {
    struct Step: Decodable {
        let index: Int
        let start: Double
        let read: Double
    }

    struct Scenario: Decodable {
        let name: String
        let source: String
        let status: String
        let steps: [Step]?
    }

    struct Run: Decodable {
        let tmux: String
        let version: String
        let scenarios: [Scenario]
    }

    let runs: [Run]
}

struct ReplayedRun: Encodable {
    let tmux: String
    let version: String
    let modelVersion: String
    let exact: Bool
    let scenarios: [ScenarioTranscript]
}

struct ReplayedResult: Encodable {
    let runs: [ReplayedRun]
}
