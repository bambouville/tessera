#pragma once
#include <deque>
#include <map>
#include <string>
#include <vector>

namespace tessera {
// Advisory wakeups only. Canonical reads still reopen through Catalog and
// validate identity/cursors. Lost notifications fall back to bounded polling.
// Worker-thread owned; never follows paths or emits provider data itself.
class FileWakeups {
public:
    FileWakeups();
    ~FileWakeups();
    void watch(const std::string& handle, int authorizedDescriptor);
    std::vector<std::string> take();
private:
    struct Watch { int descriptor = -1, key = -1; };
    void remove(const std::string& handle);
    int queue_ = -1;
    std::map<std::string, Watch> watches_;
    std::deque<std::string> order_;
};
}
