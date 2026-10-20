#pragma once
#include <charconv>
#include <cstdint>
#include <optional>
#include <string_view>

namespace tessera {
struct ProcStat {
    int32_t pid = 0, group = 0;
    uint64_t residentPages = 0;
};

// Linux proc stat fields 1, 5 and 24. See the kernel proc filesystem
// documentation, table 1-4. comm can contain spaces, parentheses and newlines;
// it is not a whitespace-separated field. No allocation or locale streams.
inline std::optional<ProcStat> parseProcStat(std::string_view raw) {
    const auto open = raw.find(" ("), close = raw.rfind(')');
    if (open == std::string_view::npos || close == std::string_view::npos || close <= open + 1 ||
        close + 2 >= raw.size() || raw[close + 1] != ' ') return std::nullopt;
    auto number = [](std::string_view token, auto& value) {
        const auto result = std::from_chars(token.data(), token.data() + token.size(), value);
        return !token.empty() && result.ec == std::errc() && result.ptr == token.data() + token.size();
    };
    ProcStat result;
    if (!number(raw.substr(0, open), result.pid) || result.pid <= 0) return std::nullopt;
    raw.remove_prefix(close + 2);
    for (int field = 3; field <= 24; ++field) {
        const auto end = raw.find_first_of(" \n");
        if (end == std::string_view::npos || end == 0) return std::nullopt;
        const auto token = raw.substr(0, end);
        if (field == 3 && token.size() != 1) return std::nullopt;
        if (field == 5 && (!number(token, result.group) || result.group < 0)) return std::nullopt;
        if (field == 24 && !number(token, result.residentPages)) return std::nullopt;
        raw.remove_prefix(end + 1);
    }
    return result;
}
}
