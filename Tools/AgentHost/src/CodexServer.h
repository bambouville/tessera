#pragma once
#include <cstdint>
#include <functional>
#include <chrono>
#include <string>
#include <map>
#include <sys/types.h>

namespace tessera {
// Single worker-owned, read-only App Server child. No session control methods
// are exposed. A capability failure selects the bounded JSONL reader instead.
class CodexServer {
public:
    explicit CodexServer(std::function<bool()> cancelled = {});
    ~CodexServer();
    CodexServer(const CodexServer&) = delete;
    CodexServer& operator=(const CodexServer&) = delete;
    std::string call(const std::string& method, const std::string& params,
        std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::time_point::max(),
        size_t maximumBytes = 16 * 1024 * 1024, bool allowCached = false);
    void invalidateCachedReads() { cache_.clear(); cacheBytes_ = 0; }
    uint64_t bytesRead() const { return bytesRead_; }
    uint64_t peakResidentBytes() const { return peakResident_; }
    bool responseTruncated() const { return responseTruncated_; }
    void shutdown() { stop(); }
    void supervise();
private:
    std::string executable_;
    void start(std::chrono::steady_clock::time_point deadline, bool verifiedVersion = false);
    void stop();
    void checkResources(bool idle = false);
    int input_ = -1, output_ = -1;
    pid_t process_ = -1;
    uint64_t nextID_ = 0, peakResident_ = 0, bytesRead_ = 0;
    bool responseTruncated_ = false;
    std::chrono::steady_clock::time_point lastResourceCheck_{};
    std::string pending_;
    std::function<bool()> cancelled_;
    struct CachedRead { std::string value; std::chrono::steady_clock::time_point observed; bool truncated; size_t bytes; };
    std::map<std::string, CachedRead> cache_;
    size_t cacheBytes_ = 0;
};
}
