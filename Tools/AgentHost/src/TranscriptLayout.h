#pragma once
#include <string_view>
#include <vector>

namespace tessera {
inline bool transcriptUUID(std::string_view value) {
    if (value.size() != 36) return false;
    for (size_t index = 0; index < value.size(); ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != '-') return false;
        } else if (!((value[index] >= '0' && value[index] <= '9') ||
                     (value[index] >= 'a' && value[index] <= 'f') ||
                     (value[index] >= 'A' && value[index] <= 'F'))) return false;
    }
    return true;
}

// Discovery grammar from the pinned Claude Agent SDK sessions reader:
// projects/<project>/<uuid>.jsonl and
// projects/<project>/<uuid>/subagents/**/agent-<id>.jsonl.
// Workflow result/cache JSONL files are not conversations. Explicit lifecycle
// resolution remains a separate, root-authorized path for historical layouts.
inline bool claudeTranscriptLayout(std::string_view relative) {
    if (relative.empty() || relative.back() == '/') return false;
    std::vector<std::string_view> parts;
    while (!relative.empty()) {
        const auto separator = relative.find('/');
        const auto part = relative.substr(0, separator);
        if (part.empty() || part == "." || part == "..") return false;
        parts.push_back(part);
        if (separator == std::string_view::npos) break;
        relative.remove_prefix(separator + 1);
    }
    if (parts.size() < 2) return false;
    const auto leaf = parts.back();
    if (leaf.size() <= 6 || leaf.substr(leaf.size() - 6) != ".jsonl") return false;
    const auto stem = leaf.substr(0, leaf.size() - 6);
    if (parts.size() == 2) return transcriptUUID(stem);
    return parts.size() >= 4 && transcriptUUID(parts[1]) && parts[2] == "subagents" &&
        stem.size() >= 6 && stem.substr(0, 6) == "agent-";
}
}
