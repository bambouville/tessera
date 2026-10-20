#include "LocalTransport.h"
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <unistd.h>

int main() {
    char path[] = "/tmp/tessera-relay-exec-XXXXXX";
    const auto root = ::mkdtemp(path);
    assert(root);
    const auto runtime = std::filesystem::canonical(root).string();
    const auto started = std::chrono::steady_clock::now();
    assert(tessera::runRelay(runtime, "/nonexistent/tessera-test-helper", "", 100, true) == 69);
    assert(tessera::runRelay(runtime + "/absent", "/nonexistent/tessera-test-helper", "", 100, true) == 77);
    assert(!std::filesystem::exists(runtime + "/absent"));
    // Failed exec is acknowledged by the still-waitable child, not mistaken
    // for successful daemonization followed by a socket readiness timeout.
    const auto result = tessera::runRelay(runtime, "/nonexistent/tessera-test-helper", "", 100);
    std::filesystem::remove_all(runtime);
    assert(result == 70);
    assert(std::chrono::steady_clock::now() - started < std::chrono::seconds(3));
    assert(!std::filesystem::exists(runtime + "/client.sock"));
}
