#pragma once
#include <string>
#include <string_view>

namespace tessera {
// Display-only port of shlex 1.3.0's default Quoter used by Codex's
// shlex_join. MIT license: ../licenses/shlex-MIT.txt. Never execute this text.
// Matching the upstream spelling matters when a command preview is clipped:
// equivalent but differently quoted argv can expose a different prefix.
inline std::string codexQuoteArgument(std::string_view value) {
    if (value.empty()) return "''";
    std::string result;
    while (!value.empty()) {
        unsigned strategies = 7; // unquoted, single, double
        size_t end = 0;
        if (value[0] == '^') { strategies = 2; end = 1; }
        for (; end < value.size(); ++end) {
            const auto byte = static_cast<unsigned char>(value[end]);
            auto next = strategies;
            if (byte >= 128) next &= ~1u;
            else {
                if (std::string_view("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-./:@]_").find(byte) == std::string_view::npos) next &= ~1u;
                if (byte == '\'' || byte == '^' || byte == '\\') next &= ~2u;
                if (byte == '`' || byte == '$' || byte == '!' || byte == '^') next &= ~4u;
            }
            if (!next) break;
            strategies = next;
        }
        const auto chunk = value.substr(0, end);
        if (strategies & 1) result.append(chunk);
        else if (strategies & 2) { result += '\''; result.append(chunk); result += '\''; }
        else {
            result += '"';
            for (char byte : chunk) {
                if (byte == '$' || byte == '`' || byte == '"' || byte == '\\') result += '\\';
                result += byte;
            }
            result += '"';
        }
        value.remove_prefix(end);
    }
    return result;
}
}
