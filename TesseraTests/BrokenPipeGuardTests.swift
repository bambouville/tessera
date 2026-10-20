import Darwin
import XCTest
@testable import Tessera

/// The test host launched the app, so these check the disposition its launch
/// installed. Without it, each broken-pipe write below ends the test process
/// with SIGPIPE instead of failing an assertion.
final class BrokenPipeGuardTests: XCTestCase {
    func test_launchIgnoresBrokenPipes() {
        XCTAssertTrue(BrokenPipeGuard.isIgnoringBrokenPipes)
    }

    /// iOS leaves a socket it reclaimed from a suspended app unable to send,
    /// as `shutdown` does here; mosh's next `sendto` then raised SIGPIPE.
    func test_sendOnAUDPSocketThatCanNoLongerSendFailsInsteadOfEndingTheApp() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        XCTAssertEqual(shutdown(descriptor, SHUT_WR), 0)

        assertBrokenPipeWriteFails { bytes in
            send(descriptor, bytes, 1, MSG_DONTWAIT)
        }
    }

    func test_writeToAPipeWithoutAReaderFailsInsteadOfEndingTheApp() {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        close(descriptors[0])
        defer { close(descriptors[1]) }

        assertBrokenPipeWriteFails { bytes in
            write(descriptors[1], bytes, 1)
        }
    }

    private func assertBrokenPipeWriteFails(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ writeOneByte: (UnsafeRawPointer) -> Int
    ) {
        let byte: [UInt8] = [0x78]
        var failure: Int32 = 0
        let written = byte.withUnsafeBytes { bytes -> Int in
            let result = writeOneByte(bytes.baseAddress!)
            failure = errno
            return result
        }

        XCTAssertEqual(written, -1, file: file, line: line)
        XCTAssertEqual(failure, EPIPE, file: file, line: line)
    }
}
