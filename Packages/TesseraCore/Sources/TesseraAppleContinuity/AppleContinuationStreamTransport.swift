import Foundation
import TesseraEnrollmentCore

/// Byte transport for Apple Handoff continuation streams.
///
/// The peer binding is load-bearing: Foundation creates these streams only
/// after same-account Handoff matching. Arbitrary streams must use a separately
/// verified SAS-bound transport instead.
@MainActor
open class AppleContinuationStreamTransport: NSObject {
    public enum StreamError: Error, Equatable, LocalizedError {
        case closed
        case outputBackpressure
        case readFailed
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .closed:
                String(
                    localized: "The enrollment continuation stream is closed.",
                    bundle: .main
                )
            case .outputBackpressure:
                String(
                    localized: "The enrollment continuation stream stopped accepting data.",
                    bundle: .main
                )
            case .readFailed:
                String(
                    localized: "Could not read from the enrollment continuation stream.",
                    bundle: .main
                )
            case .writeFailed:
                String(
                    localized: "Could not write to the enrollment continuation stream.",
                    bundle: .main
                )
            }
        }
    }

    public let peerBinding: PeerBinding = .appleAccountContinuationStream
    public var onBytes: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    public var onServiceEvent: (() -> Void)?

    private static let readChunkBytes = 16 * 1024
    private static let maximumPendingOutputBytes = 256 * 1024

    private let input: InputStream
    private let output: OutputStream
    private var pendingOutput = Data()
    private var isStarted = false
    private var closeRequested = false
    private var outputClosed = false
    private var forcedCloseTask: Task<Void, Never>?
    public private(set) var isClosed = false

    public init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        super.init()
    }

    public func start() {
        guard !isStarted, !isClosed else { return }
        isStarted = true
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)

        if input.streamStatus == .notOpen { input.open() }
        if !outputClosed, output.streamStatus == .notOpen { output.open() }
        drainInput()
        flushOutput()
    }

    public func send(_ bytes: Data) throws {
        guard !isClosed, !closeRequested else { throw StreamError.closed }
        guard bytes.count <= Self.maximumPendingOutputBytes,
              pendingOutput.count <= Self.maximumPendingOutputBytes - bytes.count else {
            closeWithError(StreamError.outputBackpressure)
            throw StreamError.outputBackpressure
        }
        pendingOutput.append(bytes)
        flushOutput()
        if isClosed { throw StreamError.writeFailed }
    }

    public func close() {
        guard !isClosed, !closeRequested else { return }
        closeRequested = true
        flushOutput()
        if pendingOutput.isEmpty { closeOutputGracefully() }
        armForcedClose()
    }

    /// Platform adapters may override this diagnostic hook without changing
    /// transport ordering or close behavior.
    open func didFail(_ error: Error) {}

    private func drainInput() {
        guard !isClosed else { return }
        var bytes = [UInt8](repeating: 0, count: Self.readChunkBytes)

        while input.hasBytesAvailable {
            let count = input.read(&bytes, maxLength: bytes.count)
            if count > 0 {
                onBytes?(Data(bytes[0..<count]))
                onServiceEvent?()
            } else if count == 0 {
                finalizeClose(notifyService: true)
                return
            } else {
                closeWithError(input.streamError ?? StreamError.readFailed)
                return
            }
        }
    }

    private func flushOutput() {
        guard !isClosed, !outputClosed, output.hasSpaceAvailable else { return }
        while !pendingOutput.isEmpty, output.hasSpaceAvailable {
            let written = pendingOutput.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return output.write(base, maxLength: rawBuffer.count)
            }
            if written > 0 {
                pendingOutput.removeFirst(written)
            } else if written < 0 {
                closeWithError(output.streamError ?? StreamError.writeFailed)
                return
            } else {
                return
            }
        }
        if pendingOutput.isEmpty, closeRequested {
            closeOutputGracefully()
        }
    }

    private func closeOutputGracefully() {
        guard !outputClosed else { return }
        outputClosed = true
        output.delegate = nil
        output.remove(from: .main, forMode: .common)
        output.close()
    }

    private func armForcedClose() {
        guard forcedCloseTask == nil else { return }
        forcedCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !self.isClosed else { return }
            self.finalizeClose(notifyService: false)
        }
    }

    private func closeWithError(_ error: Error) {
        didFail(error)
        finalizeClose(notifyService: true)
    }

    private func finalizeClose(notifyService: Bool) {
        guard !isClosed else { return }
        isClosed = true
        closeRequested = true
        forcedCloseTask?.cancel()
        forcedCloseTask = nil
        pendingOutput.removeAll(keepingCapacity: false)
        input.delegate = nil
        output.delegate = nil
        input.remove(from: .main, forMode: .common)
        output.remove(from: .main, forMode: .common)
        input.close()
        if !outputClosed { output.close() }
        outputClosed = true
        if notifyService { onClose?() }
        onServiceEvent?()
    }

    private func handle(_ event: Stream.Event, from stream: Stream) {
        guard !isClosed else { return }
        switch event {
        case .openCompleted:
            if stream === input { drainInput() }
            if stream === output { flushOutput() }
        case .hasBytesAvailable:
            drainInput()
        case .hasSpaceAvailable:
            flushOutput()
        case .endEncountered:
            finalizeClose(notifyService: true)
        case .errorOccurred:
            closeWithError(stream.streamError ?? StreamError.readFailed)
        default:
            break
        }
    }
}

extension AppleContinuationStreamTransport: StreamDelegate {
    nonisolated public func stream(
        _ aStream: Stream,
        handle eventCode: Stream.Event
    ) {
        Task { @MainActor [weak self] in
            self?.handle(eventCode, from: aStream)
        }
    }
}
