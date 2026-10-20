public struct TmuxControlModeDetection: Equatable, Sendable {
    public let passthroughBytes: [UInt8]
    public let controlBytes: [UInt8]
    public let enteredControlMode: Bool

    public init(
        passthroughBytes: [UInt8],
        controlBytes: [UInt8],
        enteredControlMode: Bool
    ) {
        self.passthroughBytes = passthroughBytes
        self.controlBytes = controlBytes
        self.enteredControlMode = enteredControlMode
    }
}

/// Incremental detector for tmux's `ESC P 1 0 0 0 p` control-mode prologue.
/// It reserves only a true suffix-prefix match, keeping ordinary shell echo on
/// the immediate path while detecting a prologue split across arbitrary reads.
public struct TmuxControlModeDetector: Sendable {
    public static let prologue: [UInt8] = [
        0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70
    ]

    private var reserved: [UInt8] = []
    public private(set) var hasEnteredControlMode = false

    public init() {}

    public mutating func reset() {
        reserved.removeAll(keepingCapacity: true)
        hasEnteredControlMode = false
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> TmuxControlModeDetection {
        let chunk = Array(bytes)
        guard !hasEnteredControlMode else {
            return .init(passthroughBytes: [], controlBytes: chunk, enteredControlMode: false)
        }
        reserved.append(contentsOf: chunk)
        if let index = Self.firstIndex(of: Self.prologue, in: reserved) {
            let passthrough = Array(reserved[..<index])
            let controlStart = index + Self.prologue.count
            let control = controlStart < reserved.count ? Array(reserved[controlStart...]) : []
            reserved.removeAll(keepingCapacity: true)
            hasEnteredControlMode = true
            return .init(
                passthroughBytes: passthrough,
                controlBytes: control,
                enteredControlMode: true
            )
        }

        let prefixLength = Self.longestProloguePrefixAtTail(of: reserved)
        let flushCount = reserved.count - prefixLength
        let passthrough = flushCount > 0 ? Array(reserved[..<flushCount]) : []
        if flushCount > 0 { reserved.removeFirst(flushCount) }
        return .init(passthroughBytes: passthrough, controlBytes: [], enteredControlMode: false)
    }

    public static func longestProloguePrefixAtTail(of bytes: [UInt8]) -> Int {
        let maximum = min(prologue.count - 1, bytes.count)
        for length in stride(from: maximum, through: 1, by: -1) {
            let start = bytes.count - length
            if bytes[start...].elementsEqual(prologue.prefix(length)) { return length }
        }
        return 0
    }

    public static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for index in 0...(haystack.count - needle.count)
            where haystack[index..<(index + needle.count)].elementsEqual(needle) {
            return index
        }
        return nil
    }
}
