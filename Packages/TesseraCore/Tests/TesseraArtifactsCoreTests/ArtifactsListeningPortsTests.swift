import XCTest
import TesseraArtifactsCore

final class ArtifactsListeningPortsTests: XCTestCase {
    func testUbuntuSSFixture() {
        let output = """
        TESSERA_ARTIFACTS_PORTS:ss
        LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=692,fd=14))
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1001,fd=3))
        LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1002,fd=3))
        LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=3011,fd=22))
        LISTEN 0 511 [::1]:5173 [::]:* users:(("node",pid=3011,fd=23))
        LISTEN 0 5 *:8000 *:* users:(("python3",pid=4112,fd=3))
        ESTAB 0 0 127.0.0.1:9000 127.0.0.1:12345
        """
        let ports = ArtifactsListeningPorts.parse(output, sshPort: 2222)
        XCTAssertEqual(ports, [.init(port: 53, bindAddress: "127.0.0.53", process: "systemd-resolve"),
                               .init(port: 5173, bindAddress: "127.0.0.1", process: "node"),
                               .init(port: 8000, bindAddress: "*", process: "python3")])
    }

    func testBusyBoxAlpineNetstatFixture() {
        let output = """
        TESSERA_ARTIFACTS_PORTS:netstatLinux
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
        tcp        0      0 127.0.0.1:3000          0.0.0.0:*               LISTEN
        tcp        0      0 :::8080                 :::*                    LISTEN
        tcp        0      0 127.0.0.1:3000          127.0.0.1:50123         ESTABLISHED
        udp        0      0 0.0.0.0:5353            0.0.0.0:*
        """
        XCTAssertEqual(ArtifactsListeningPorts.parse(output), [.init(port: 3000, bindAddress: "127.0.0.1"),
                                                               .init(port: 8080, bindAddress: "::")])
    }

    func testMacOSNetstatFixture() {
        let output = """
        TESSERA_ARTIFACTS_PORTS:netstatMacOS
        Active Internet connections (including servers)
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)      rhiwat shiwat pid epid state options
        tcp4       0      0  *.22                   *.*                    LISTEN       131072 131072 123 0 0x0100 0x00000006
        tcp4       0      0  127.0.0.1.4321         *.*                    LISTEN       131072 131072 812 0 0x0100 0x00000006
        tcp6       0      0  ::1.3000               *.*                    LISTEN       131072 131072 912 0 0x0100 0x00000006
        tcp4       0      0  192.168.1.2.53000      1.2.3.4.443            ESTABLISHED  131072 131072 111 0 0x0100 0x00000006
        """
        XCTAssertEqual(ArtifactsListeningPorts.parse(output), [.init(port: 3000, bindAddress: "::1"),
                                                               .init(port: 4321, bindAddress: "127.0.0.1")])
    }

    func testLSOFFixtureAndFinalAttemptMarker() {
        let output = """
        TESSERA_ARTIFACTS_PORTS:ss
        LISTEN 0 5 *:9999 *:*
        TESSERA_ARTIFACTS_PORTS:lsof
        COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        sshd      120 root    3u  IPv4 0x1111111111111111      0t0  TCP *:22 (LISTEN)
        node     1001 me     22u  IPv6 0x2222222222222222      0t0  TCP [::1]:5173 (LISTEN)
        python3  1002 me      3u  IPv4 0x3333333333333333      0t0  TCP *:8000 (LISTEN)
        python3  1002 me      4u  IPv6 0x4444444444444444      0t0  TCP [::]:8000 (LISTEN)
        """
        XCTAssertEqual(ArtifactsListeningPorts.parse(output), [.init(port: 5173, bindAddress: "::1", process: "node"),
                                                               .init(port: 8000, bindAddress: "*", process: "python3")])
        XCTAssertEqual(ArtifactsListeningPorts.parse("LISTEN 0 128 *:8000 *:*"), [])
        XCTAssertEqual(ArtifactsListeningPorts.parse("TESSERA_ARTIFACTS_PORTS:none\n"), [])
    }
}
