import XCTest
@testable import TmuxSemanticsModel

/// Drops the time and command number from guard lines, so `%begin 1700000000 12 1`
/// becomes `%begin 1`.
func normalized(_ lines: [String]) -> [String] {
    lines.map { line in
        let parts = line.split(separator: " ")
        if ["%begin", "%end", "%error"].contains(String(parts.first ?? "")), parts.count == 4 {
            return "\(parts[0]) \(parts[3])"
        }
        return line
    }
}

/// The lines inside guard blocks, without the guards.
func payload(_ lines: [String]) -> [String] {
    var inside = false
    var result: [String] = []
    for line in lines {
        if line.hasPrefix("%begin ") { inside = true; continue }
        if line.hasPrefix("%end ") || line.hasPrefix("%error ") { inside = false; continue }
        if inside { result.append(line) }
    }
    return result
}

/// Lines outside guard blocks (notifications).
func notifications(_ lines: [String]) -> [String] {
    var inside = false
    var result: [String] = []
    for line in lines {
        if line.hasPrefix("%begin ") { inside = true; continue }
        if line.hasPrefix("%end ") || line.hasPrefix("%error ") { inside = false; continue }
        if !inside { result.append(line) }
    }
    return result
}

extension XCTestCase {
    /// Fails if the model met input it does not implement.
    func assertFullyModelled(_ model: TmuxServerModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.unsupported, [], "scenario used unmodelled tmux behaviour", file: file, line: line)
    }
}
