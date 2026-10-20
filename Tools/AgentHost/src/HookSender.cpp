#include "HookSender.h"
#include "LocalTransport.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <string>

namespace tessera {
namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t maximumPayload = 65536;
constexpr auto deadlineDuration = std::chrono::milliseconds(100);

struct Descriptor {
    int value;
    ~Descriptor() { if (value >= 0) ::close(value); }
};

bool ready(int fd, short events, Clock::time_point deadline) {
    while (Clock::now() < deadline) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        pollfd item{fd, events, 0};
        int result = ::poll(&item, 1, static_cast<int>(std::max<int64_t>(1, left)));
        if (result > 0) return (item.revents & (events | POLLHUP)) != 0;
        if (result == 0 || errno != EINTR) return false;
    }
    return false;
}

bool writeAll(int fd, const void* bytes, size_t size, Clock::time_point deadline) {
    const char* cursor = static_cast<const char*>(bytes);
    while (size && ready(fd, POLLOUT, deadline)) {
        const auto count = ::write(fd, cursor, size);
        if (count > 0) { cursor += count; size -= static_cast<size_t>(count); }
        else if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) return false;
    }
    return size == 0;
}
}

int sendHook(const char* socketPath) {
    const auto deadline = Clock::now() + deadlineDuration;
    const std::string path(socketPath);
    Descriptor connection{connectLocal(path, 100)};
    if (connection.value < 0) return 0;
    (void)::signal(SIGPIPE, SIG_IGN);

    // Do not hold a provider while waiting for stdin or a stalled service.
    // Frame completion is required; the receiver must reject truncated writes.
    std::array<char, maximumPayload + 1> payload{};
    size_t used = 0;
    bool complete = false;
    while (ready(STDIN_FILENO, POLLIN, deadline)) {
        const auto count = ::read(STDIN_FILENO, payload.data() + used, payload.size() - used);
        if (count == 0) { complete = true; break; }
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN) continue;
            return 0;
        }
        used += static_cast<size_t>(count);
        if (used > maximumPayload) {
            // A small hint forces canonical reconciliation, not silent acceptance
            // of a truncated JSON payload. No record/session identity is guessed.
            constexpr char overflow[] = "{\"hook_event_name\":\"TesseraHookOverflow\"}";
            auto length = htonl(sizeof(overflow) - 1);
            if (writeAll(connection.value, &length, sizeof(length), deadline))
                (void)writeAll(connection.value, overflow, sizeof(overflow) - 1, deadline);
            return 0;
        }
    }
    if (!complete || used == 0) return 0;
    auto length = htonl(static_cast<uint32_t>(used));
    if (writeAll(connection.value, &length, sizeof(length), deadline))
        (void)writeAll(connection.value, payload.data(), used, deadline);
    return 0;
}
}
