#include "ReadStatus.h"
#include <cassert>

int main() {
    using tessera::ReadStatus;
    const auto progress = ReadStatus::from("readPending");
    assert(progress.state == "preparing" && progress.recovery == "continue");
    for (const auto* code : {"codexIndexCapacity", "claudeIndexCapacity", "kimiIndexCapacity", "readBudgetExceeded"}) {
        const auto status = ReadStatus::from(code);
        assert(status.code == code && status.state == "resourceLimited" && status.domain == "host");
        assert(status.recovery == "retryRead");
    }
    assert(ReadStatus::from("sourceChanged").recovery == "rebootstrap");
    assert(ReadStatus::from("readContinuationTimeout").state == "retryable");
    assert(ReadStatus::from("piFormatUnsupported").state == "unsupported");
    for (const auto* value : {"private path /home/user", "provider transcript", "futureUnknownCode"})
        assert(ReadStatus::from(value).code == "unknown");
    assert(ReadStatus::from("windowItemCapacity").json().find("client") == std::string::npos);
}
