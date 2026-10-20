#pragma once
#include <algorithm>
#include <cstddef>
#include <functional>
#include <map>
#include <stdexcept>

namespace tessera {
// One worker owns all callbacks and performs one reconstruction at a time.
// The allowance includes that reconstruction's temporary state, not just the
// metadata retained after it. Content/window buffers have separate budgets.
class HistoryMetadataBudget {
public:
    static constexpr size_t indexLimit = 128 * 1024 * 1024;
    static constexpr size_t totalLimit = 256 * 1024 * 1024;
    void registerFamily(const void* owner, std::function<size_t()> usage) {
        if (!usage_.emplace(owner, std::move(usage)).second)
            throw std::logic_error("duplicateHistoryBudgetOwner");
    }
    void unregisterFamily(const void* owner) { usage_.erase(owner); }
    size_t allowance(const void* owner, size_t requested = indexLimit) const {
        size_t other = 0;
        for (const auto& family : usage_) if (family.first != owner) {
            const auto bytes = family.second();
            if (bytes >= totalLimit - std::min(other, totalLimit)) return 0;
            other += bytes;
        }
        return std::min(requested, totalLimit - other);
    }
    size_t bytes() const {
        size_t result = 0;
        for (const auto& family : usage_) result += family.second();
        return result;
    }
private:
    std::map<const void*, std::function<size_t()>> usage_;
};
}
