#include "LocalTransport.h"
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <array>
#include <cerrno>
#include <chrono>
#include <string>
#include <thread>

namespace tessera {
namespace {
bool startDetached(const std::string& runtime, const char* executable, int idleMs) {
    const auto idle = std::to_string(idleMs);
    int acknowledgement[2];
    if (::pipe(acknowledgement)) return false;
    if (acknowledgement[0] < 3 || acknowledgement[1] < 3 ||
        ::fcntl(acknowledgement[0], F_SETFD, FD_CLOEXEC) || ::fcntl(acknowledgement[1], F_SETFD, FD_CLOEXEC)) {
        ::close(acknowledgement[0]); ::close(acknowledgement[1]); return false;
    }
    const auto child = ::fork();
    if (child < 0) { ::close(acknowledgement[0]); ::close(acknowledgement[1]); return false; }
    if (!child) {
        if (::setsid() < 0) _exit(1);
        const auto daemon = ::fork();
        if (daemon < 0) _exit(1);
        if (daemon) {
            ::close(acknowledgement[1]);
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
            for (;;) {
                pollfd descriptor{acknowledgement[0], POLLIN, 0};
                const auto ready = ::poll(&descriptor, 1, 20);
                if (ready > 0) {
                    char status;
                    const auto count = ::read(acknowledgement[0], &status, 1);
                    if (!count) _exit(0); // CLOEXEC proves the child reached exec/exit.
                    if (count > 0) break;
                    if (errno != EINTR) break;
                } else if (ready < 0 && errno != EINTR) break;
                if (std::chrono::steady_clock::now() >= deadline) break;
            }
            // Still our unreaped, waitable child: its PID cannot be recycled.
            (void)::kill(daemon, SIGKILL);
            while (::waitpid(daemon, nullptr, 0) < 0 && errno == EINTR) { }
            _exit(1);
        }
        ::close(acknowledgement[0]);
        auto failed = [&] {
            const char status = 1;
            (void)::write(acknowledgement[1], &status, 1);
            _exit(1);
        };
        int null = ::open("/dev/null", O_RDWR);
        if (null < 0) failed();
        for (int fd = 0; fd < 3; ++fd) if (::dup2(null, fd) < 0) failed();
        rlimit limit{};
        if (::getrlimit(RLIMIT_NOFILE, &limit)) failed();
        for (rlim_t fd = 3; fd < limit.rlim_cur; ++fd)
            if (fd != static_cast<rlim_t>(acknowledgement[1])) ::close(static_cast<int>(fd));
        if (idleMs == 30000) ::execl(executable, executable, "serve", "--runtime", runtime.c_str(), nullptr);
        else ::execl(executable, executable, "serve", "--runtime", runtime.c_str(), "--idle-ms", idle.c_str(), nullptr);
        failed();
    }
    ::close(acknowledgement[0]); ::close(acknowledgement[1]);
    int status{};
    while (::waitpid(child, &status, 0) < 0) if (errno != EINTR) return false;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
}

int runRelay(const std::string& runtime, const char* executable, const std::string& initial, int idleMs, bool attachOnly) {
    if (!ownedDirectory(runtime, !attachOnly)) return 77;
    const auto path = runtime + "/client.sock";
    int connection = connectLocal(path, 100);
    if (connection < 0) {
        if (attachOnly) return 69;
        if (!startDetached(runtime, executable, idleMs)) return 70;
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        while (connection < 0 && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            connection = connectLocal(path, 100);
        }
    }
    if (connection < 0) return 69;
    (void)::signal(SIGPIPE, SIG_IGN);
    if (!nonblocking(STDIN_FILENO) || !nonblocking(STDOUT_FILENO)) { ::close(connection); return 74; }
    std::string toService = initial, toClient;
    constexpr size_t limit = 65540;
    bool stdinEnded = false, serviceEnded = false, writeEnded = false;
    auto drainDeadline = std::chrono::steady_clock::time_point::max();
    while (!serviceEnded || !toClient.empty()) {
        pollfd descriptors[] = {
            {STDIN_FILENO, static_cast<short>(!stdinEnded && toService.size() < limit ? POLLIN : 0), 0},
            {STDOUT_FILENO, static_cast<short>(!toClient.empty() ? POLLOUT : 0), 0},
            {connection, static_cast<short>((!serviceEnded && toClient.size() < limit ? POLLIN : 0) |
                                           (!toService.empty() ? POLLOUT : 0)), 0}
        };
        if (::poll(descriptors, 3, 100) < 0) { if (errno == EINTR) continue; break; }
        std::array<char, 8192> bytes;
        auto readInto = [&](int fd, std::string& target, bool& ended) {
            if (ended || target.size() == limit) return;
            const auto count = ::read(fd, bytes.data(), std::min(bytes.size(), limit - target.size()));
            if (count > 0) target.append(bytes.data(), static_cast<size_t>(count));
            else if (!count || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)) ended = true;
        };
        auto writeFrom = [&](int fd, std::string& source) {
            if (source.empty()) return true;
            const auto count = ::write(fd, source.data(), source.size());
            if (count > 0) source.erase(0, static_cast<size_t>(count));
            return count >= 0 || errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
        };
        if (descriptors[0].revents & (POLLIN | POLLHUP)) readInto(STDIN_FILENO, toService, stdinEnded);
        if (descriptors[2].revents & (POLLIN | POLLHUP)) readInto(connection, toClient, serviceEnded);
        if ((descriptors[1].revents & POLLOUT) && !writeFrom(STDOUT_FILENO, toClient)) break;
        if ((descriptors[2].revents & POLLOUT) && !writeFrom(connection, toService)) break;
        if ((descriptors[1].revents | descriptors[2].revents) & (POLLERR | POLLNVAL)) break;
        if (stdinEnded && toService.empty() && !writeEnded) {
            (void)::shutdown(connection, SHUT_WR);
            writeEnded = true;
        }
        if ((stdinEnded || serviceEnded) && drainDeadline == std::chrono::steady_clock::time_point::max())
            drainDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
        if (std::chrono::steady_clock::now() >= drainDeadline) break;
    }
    ::close(connection);
    return 0;
}
}
