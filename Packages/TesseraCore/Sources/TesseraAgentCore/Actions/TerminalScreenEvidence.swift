import Foundation

/// Immutable, physical live-grid evidence. Native terminal owners copy their
/// cells once; provider rules never reconstruct cell coordinates from ANSI or
/// a second Unicode width implementation. Transport bindings remain external.
public struct TerminalScreenEvidence: Codable, Equatable, Sendable {
    public struct Cell: Codable, Equatable, Sendable {
        public let text: String
        public let width: Int
        /// Shared style bits: bold, underline, blink, inverse, invisible, dim,
        /// italic, crossed-out. Colors do not affect composer safety.
        public let style: UInt8
        public init(text: String, width: Int, style: UInt8) {
            self.text = text; self.width = width; self.style = style
        }
        public init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            text = try values.decode(String.self)
            width = try values.decode(Int.self)
            style = try values.decode(UInt8.self)
            guard values.isAtEnd else { throw DecodingError.dataCorruptedError(in: values, debugDescription: "extra cell fields") }
        }
        public func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(text); try values.encode(width); try values.encode(style)
        }
    }

    public let columns: Int
    public let cells: [[Cell]]
    /// True when this row continues the preceding physical row (possibly history).
    public let wrappedRows: [Bool]
    public let cursorRow: Int
    public let cursorColumn: Int
    public let cursorVisible: Bool
    public let isAlternate: Bool
    public let complete: Bool

    public init(columns: Int, cells: [[Cell]], wrappedRows: [Bool], cursorRow: Int,
                cursorColumn: Int, cursorVisible: Bool, isAlternate: Bool, complete: Bool = true) {
        self.columns = columns; self.cells = cells; self.wrappedRows = wrappedRows
        self.cursorRow = cursorRow; self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible; self.isAlternate = isAlternate; self.complete = complete
    }

    public var plainText: String? {
        styledRows.map { $0.map { String(String.UnicodeScalarView($0.map(\.scalar))) }.joined(separator: "\n") }
    }

    /// Validate before interpreting anything. Continuation cells retain their
    /// physical positions but contribute no extra glyph or guessed width.
    var styledRows: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]]? {
        let rows = cells.count
        guard complete, columns > 0, rows > 0, columns <= 65_536 / rows,
              wrappedRows.count == rows, cursorRow >= 0, cursorRow < rows,
              cursorColumn >= 0, cursorColumn <= columns else { return nil }
        var remaining = 65_536 - (rows - 1)
        var result: [[(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)]] = []
        result.reserveCapacity(rows)
        for row in cells {
            guard row.count == columns else { return nil }
            var scalars: [(scalar: Unicode.Scalar, dim: Bool, inverse: Bool)] = []
            var needsContinuation = false
            for cell in row {
                if needsContinuation {
                    guard cell.width == 0, cell.text.isEmpty else { return nil }
                    needsContinuation = false
                    continue
                }
                guard cell.width == 1 || cell.width == 2, !cell.text.isEmpty else { return nil }
                needsContinuation = cell.width == 2
                // Count before retaining scalars; malicious combining sequences
                // cannot create an unbounded intermediate Array or UTF-8 copy.
                for scalar in cell.text.unicodeScalars {
                    guard scalar.value >= 32, !(127...159).contains(scalar.value) else { return nil }
                    remaining -= scalar.value < 0x80 ? 1 : scalar.value < 0x800 ? 2 : scalar.value < 0x10000 ? 3 : 4
                    guard remaining >= 0 else { return nil }
                    scalars.append((scalar, cell.style & 32 != 0, cell.style & 8 != 0))
                }
            }
            guard !needsContinuation else { return nil }
            result.append(scalars)
        }
        return result
    }
}
