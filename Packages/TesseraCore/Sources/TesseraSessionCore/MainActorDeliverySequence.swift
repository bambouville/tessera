import Foundation

/// A lossless UI consumer for a transport's AsyncStream. Swift 5 callers of
/// AsyncStream.Iterator.next() hop to the generic executor even when data is
/// already buffered. Under UI contention that charges a scheduling round trip
/// per packet. Drain the source away from UI and expose a same-actor buffered
/// fast path instead. Works on iOS 17 as well as newer isolation-aware runtimes.
///
/// Like the source AsyncStream, each iterator owns its consumption and must
/// not be iterated concurrently. Cancellation/iterator release cancels its
/// source pump. Finishing drains queued values; cancellation discards them.
public struct MainActorDeliverySequence<Element: Sendable>: AsyncSequence, Sendable {
    private let source: AsyncStream<Element>
    private let diagnostics: AsyncDeliveryDiagnostics?
    public init(_ source: AsyncStream<Element>, diagnostics: AsyncDeliveryDiagnostics? = nil) {
        self.source = source
        self.diagnostics = diagnostics
    }
    public func makeAsyncIterator() -> Iterator { Iterator(source, diagnostics: diagnostics) }

    public final class Iterator: AsyncIteratorProtocol {
        private let storage: Storage
        private let diagnostics: AsyncDeliveryDiagnostics?
        private var turnStart: ContinuousClock.Instant?
        fileprivate init(_ source: AsyncStream<Element>, diagnostics: AsyncDeliveryDiagnostics?) {
            self.diagnostics = diagnostics
            storage = Storage(diagnostics: diagnostics)
            storage.start(source)
        }
        deinit { storage.cancel() }

        func cancel() { storage.cancel() }
        var bufferedCount: Int { storage.bufferedCount }

        /// Call only after the consumer actually suspended for cooperative
        /// work. Its scheduling wait is not more uninterrupted UI work. Other
        /// iterations (including metadata-only bursts) retain normal fairness.
        @MainActor public func consumerDidYield() { turnStart = .now }

        @MainActor
        public func next() async -> Element? {
            while !Task.isCancelled {
                if let turnStart, turnStart.duration(to: .now) >= .milliseconds(4) {
                    await Task.yield()
                    self.turnStart = nil
                    if Task.isCancelled { break }
                }
                switch storage.take() {
                case .value(let value):
                    diagnostics?.consumed()
                    if turnStart == nil { turnStart = .now }
                    return value
                case .finished:
                    return nil
                case .empty:
                    turnStart = nil
                    let storage = storage
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { storage.wait($0) }
                    } onCancel: {
                        storage.cancel()
                    }
                }
            }
            storage.cancel()
            return nil
        }
    }

    private enum Read { case value(Element), empty, finished }

    private final class Storage: @unchecked Sendable {
        private let diagnostics: AsyncDeliveryDiagnostics?
        private let lock = NSLock()
        private var queue: [Element] = []
        private var head = 0
        private var finished = false
        private var cancelled = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var pump: Task<Void, Never>?

        init(diagnostics: AsyncDeliveryDiagnostics?) {
            self.diagnostics = diagnostics
        }

        func start(_ source: AsyncStream<Element>) {
            lock.lock()
            pump = Task.detached(priority: Task.currentPriority) { [self] in
                for await value in source {
                    if Task.isCancelled {
                        diagnostics?.discarded(count: 1)
                        break
                    }
                    if !append(value) { break }
                }
                finish()
            }
            lock.unlock()
        }

        func take() -> Read {
            lock.lock()
            defer { lock.unlock() }
            guard head < queue.count else { return finished ? .finished : .empty }
            let value = queue[head]
            head += 1
            if head >= 64, head * 2 >= queue.count {
                queue.removeFirst(head)
                head = 0
            }
            return .value(value)
        }

        var bufferedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return queue.count - head
        }

        func append(_ value: Element) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                diagnostics?.discarded(count: 1)
                return false
            }
            queue.append(value)
            let wake = waiter
            waiter = nil
            lock.unlock()
            wake?.resume()
            return true
        }

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            lock.lock()
            if head < queue.count || finished {
                lock.unlock()
                continuation.resume()
            } else {
                precondition(waiter == nil, "stream iterator consumed concurrently")
                waiter = continuation
                lock.unlock()
            }
        }

        func finish() {
            lock.lock()
            finished = true
            pump = nil
            let wake = waiter
            waiter = nil
            lock.unlock()
            wake?.resume()
        }

        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            finished = true
            let discarded = queue.count - head
            queue.removeAll()
            head = 0
            let task = pump
            pump = nil
            let wake = waiter
            waiter = nil
            lock.unlock()
            diagnostics?.discarded(count: discarded)
            task?.cancel()
            wake?.resume()
        }
    }
}

extension AsyncStream where Element: Sendable {
    public func mainActorDelivery(diagnostics: AsyncDeliveryDiagnostics? = nil) -> MainActorDeliverySequence<Element> {
        MainActorDeliverySequence(self, diagnostics: diagnostics)
    }
}
