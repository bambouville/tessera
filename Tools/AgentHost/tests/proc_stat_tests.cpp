#include "ProcStat.h"
#include <cassert>
#include <string>

std::string row(const std::string& name, const std::string& group = "42", const std::string& rss = "999") {
    // Fields 3..24, followed by rsslim and a newline.
    std::string result = "123 (" + name + ") S 7 " + group;
    for (int field = 6; field <= 23; ++field) result += " 0";
    return result + " " + rss + " 18446744073709551615\n";
}

int main() {
    for (const auto& name : {"codex", "has spaces", "a ) ( b", "line\nname", ""}) {
        const auto result = tessera::parseProcStat(row(name));
        assert(result && result->pid == 123 && result->group == 42 && result->residentPages == 999);
    }
    assert(tessera::parseProcStat(row("zero", "0", "0")));
    for (const auto& invalid : {"-1", "+1", "1.5", "1x", "18446744073709551616", ""}) {
        assert(!tessera::parseProcStat(row("bad", "42", invalid)));
        assert(!tessera::parseProcStat(row("bad", invalid)));
    }
    assert(!tessera::parseProcStat(row("bad", "2147483648")));
    auto good = row("test");
    const auto rssEnd = good.find(" 184467");
    for (size_t length = 0; length <= rssEnd; ++length)
        assert(!tessera::parseProcStat(good.substr(0, length)));
    good.replace(0, 3, "2147483648"); assert(!tessera::parseProcStat(good));
    return 0;
}
