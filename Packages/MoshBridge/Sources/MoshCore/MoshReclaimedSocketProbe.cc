#include "include/MoshCoreProbe.h"

#include <chrono>
#include <csignal>
#include <string>
#include <thread>

#include <sys/socket.h>
#include <unistd.h>

#include "network.h"

namespace {

using Clock = std::chrono::steady_clock;

bool receive_until(Network::Connection &connection, const std::string &expected,
                   Clock::time_point deadline) {
    while (Clock::now() < deadline) {
        try {
            return connection.recv() == expected;
        } catch (const Network::NetworkException &error) {
            if (error.function != "No packet received") {
                throw;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
}

class DefaultSigpipeScope {
public:
    bool install() {
        struct sigaction action = {};
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        installed_ = sigaction(SIGPIPE, &action, &previous_) == 0;
        return installed_;
    }

    ~DefaultSigpipeScope() {
        if (installed_) {
            sigaction(SIGPIPE, &previous_, nullptr);
        }
    }

private:
    struct sigaction previous_ = {};
    bool installed_ = false;
};

} // namespace

extern "C" int mosh_reclaimed_socket_probe(void) {
    int step = -1;
    try {
        Network::Connection server("127.0.0.1", "0");
        step = -2;
        const std::string port = server.port();
        Network::Connection client(server.get_key().c_str(), "127.0.0.1", port.c_str());
        const Clock::time_point deadline = Clock::now() + std::chrono::seconds(2);

        step = -3;
        if (client.fds().size() != 1 || server.fds().size() != 1) return step;
        step = -4;
        client.send("initial client message");
        step = -5;
        if (!receive_until(server, "initial client message", deadline)) return step;
        step = -6;
        server.send("initial server message");
        step = -7;
        if (!receive_until(client, "initial server message", deadline)) return step;
        client.set_last_roundtrip_success(Network::timestamp());

        const int old_fd = client.fds().front();
        step = -8;
        if (::connect(old_fd, &client.get_remote_addr().sa,
                      client.get_remote_addr_len()) != 0) return step;
        step = -9;
        if (::shutdown(old_fd, SHUT_RDWR) != 0) return step;

        step = -10;
        {
            DefaultSigpipeScope default_sigpipe;
            if (!default_sigpipe.install()) return step;
            // Keep SIGPIPE at its default disposition for this send. Without
            // SO_NOSIGPIPE, EPIPE terminates the test process here.
            client.send("reclaimed socket send");
        }
        step = -11;
        if (client.get_send_error().find("sendto: ") != 0) return step;
        step = -12;
        const auto hopped_fds = client.fds();
        if (hopped_fds.size() != 2 || hopped_fds.front() != old_fd ||
            hopped_fds.back() == old_fd) return step;

        step = -13;
        const int unconnected_tcp = ::socket(AF_INET, SOCK_STREAM, 0);
        if (unconnected_tcp < 0) return step;
        const int replaced = ::dup2(unconnected_tcp, old_fd);
        const int closed = ::close(unconnected_tcp);
        if (replaced != old_fd || closed != 0) return step;
        // A shut-down UDP socket reads as zero bytes on macOS. An unconnected
        // TCP descriptor makes recvmsg fail with ENOTCONN, like XNU's receive
        // path for a defunct socket. Connection owns and closes this fd.

        step = -14;
        client.send("new port message");
        step = -15;
        if (!receive_until(server, "new port message", deadline)) return step;
        step = -16;
        server.send("new port reply");
        step = -17;
        if (!receive_until(client, "new port reply", deadline)) return step;
        step = -18;
        if (client.fds().size() != 1 || client.fds().front() != hopped_fds.back())
            return step;
        return 42;
    } catch (...) {
        return step;
    }
}
