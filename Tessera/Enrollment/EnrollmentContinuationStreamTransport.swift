import Foundation

/// Byte transport for `NSUserActivity` continuation streams.
///
/// The peer binding is load-bearing: Foundation creates these streams only
/// after Handoff has matched devices through Apple's same-account continuity
/// service. If this adapter is ever reused with arbitrary streams, the caller
/// must provide a SAS-bound transport instead of claiming this binding.
@MainActor
final class EnrollmentContinuationStreamTransport: NSObject, EnrollmentMessageTransport {
    enum StreamError: Error, Equatable, LocalizedError {
        case closed
        case outputBackpressure
        case readFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .closed:
                return "The enrollment continuation stream is closed."
            case .outputBackpressure:
                return "The enrollment continuation stream stopped accepting data."
            case .readFailed:
                return "Could not read from the enrollment continuation stream."
            case .writeFailed:
                return "Could not write to the enrollment continuation stream."
            }
        }
    }

    let peerBinding: EnrollmentPeerBinding = .appleAccountContinuationStream
    var onBytes: ((Data) -> Void)?
    var onClose: (() -> Void)?

    /// Called after bytes or a close event has been delivered. The production
    /// coordinator uses this to snapshot `EnrollmentService.state` for UI.
    var onServiceEvent: (() -> Void)?

    private static let readChunkBytes = 16 * 1024
    private static let maximumPendingOutputBytes = 256 * 1024

    private let input: InputStream
    private let output: OutputStream
    private var pendingOutput = Data()
    private var isStarted = false
    private var closeRequested = false
    private var outputClosed = false
    private var forcedCloseTask: Task<Void, Never>?
    private(set) var isClosed = false

    init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
        super.init()
    }

    func start() {
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

    func send(_ bytes: Data) throws {
        guard !isClosed, !closeRequested else { throw StreamError.closed }
        guard bytes.count <= Self.maximumPendingOutputBytes,
              pendingOutput.count <= Self.maximumPendingOutputBytes - bytes.count
        else {
            closeWithError(StreamError.outputBackpressure)
            throw StreamError.outputBackpressure
        }
        pendingOutput.append(bytes)
        flushOutput()
        if isClosed { throw StreamError.writeFailed }
    }

    func close() {
        guard !isClosed, !closeRequested else { return }
        closeRequested = true
        flushOutput()
        if pendingOutput.isEmpty { closeOutputGracefully() }
        armForcedClose()
    }

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

    /// Half-close after all queued bytes have entered Foundation's stream.
    /// Closing the input at the same instant can discard the final buffered
    /// chunk of a bound/continuation stream. Keeping it alive until peer EOF is
    /// also a protocol-level acknowledgement that the terminal frame was read.
    private func closeOutputGracefully() {
        guard !outputClosed else { return }
        outputClosed = true
        output.delegate = nil
        output.remove(from: .main, forMode: .common)
        output.close()
    }

    private func armForcedClose() {
        guard forcedCloseTask == nil else { return }
        // A peer that disappears after the half-close must not retain these
        // streams indefinitely.
        // This bounded task intentionally retains the adapter. Coordinators may
        // release their active reference immediately after cancel/failure, but
        // a queued terminal frame still has to drain before the streams die.
        forcedCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !self.isClosed else { return }
            self.finalizeClose(notifyService: false)
        }
    }

    private func closeWithError(_ error: Error) {
        DiagnosticLogStore.appendApp(
            "enrollment stream result=failed error='\(error.localizedDescription)'"
        )
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

extension EnrollmentContinuationStreamTransport: StreamDelegate {
    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        Task { @MainActor [weak self] in
            self?.handle(eventCode, from: aStream)
        }
    }
}
