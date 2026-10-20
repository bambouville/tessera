// Same full-DOM parse as simdjson_baseline.cpp, with chunked binary input.
// Keeps framing overhead separate from claims about the JSON engine.
#include <simdjson.h>
#include <sys/resource.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    FILE *file = std::fopen(argv[1], "rb");
    if (!file) return 66;
    simdjson::dom::parser parser;
    std::string line;
    uint64_t valid = 0, invalid = 0, bytes = 0;
    char buffer[65536];
    const auto start = std::chrono::steady_clock::now();
    auto parse = [&] {
        simdjson::dom::element doc;
        auto error = parser.parse(line).get(doc);
        if (error) ++invalid; else ++valid;
        line.clear();
    };
    while (const size_t count = std::fread(buffer, 1, sizeof(buffer), file)) {
        bytes += count;
        const char *cursor = buffer;
        const char *end = buffer + count;
        while (cursor < end) {
            const char *newline = static_cast<const char *>(std::memchr(cursor, '\n', end - cursor));
            const char *stop = newline ? newline : end;
            line.append(cursor, stop - cursor);
            if (!newline) break;
            parse();
            cursor = newline + 1;
        }
    }
    const bool error = std::ferror(file);
    std::fclose(file);
    if (error) return 74;
    if (!line.empty()) parse();
    const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
#ifdef __APPLE__
    const uint64_t rss = usage.ru_maxrss;
#else
    const uint64_t rss = usage.ru_maxrss * 1024;
#endif
    std::cout << "[{\"phase\":\"initial\",\"wall_ms\":" << ms
              << ",\"peak_rss_bytes\":" << rss << ",\"valid_records\":" << valid
              << ",\"invalid_records\":" << invalid << ",\"bytes_scanned\":" << bytes
              << ",\"reader\":\"fread_memchr\",\"version\":\"" << SIMDJSON_VERSION << "\"}]\n";
}
