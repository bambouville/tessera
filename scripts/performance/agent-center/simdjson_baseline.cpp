// Parser-only control: full DOM validation, one real JSONL record at a time.
// This is not Tessera normalization, image redaction, or an adapter prototype.
#include <simdjson.h>
#include <sys/resource.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    if (argc != 2) return 64;
    std::ifstream file(argv[1], std::ios::binary);
    if (!file) return 66;
    simdjson::dom::parser parser;
    std::string line;
    uint64_t valid = 0, invalid = 0, bytes = 0;
    auto start = std::chrono::steady_clock::now();
    while (std::getline(file, line)) {
        bytes += line.size() + (file.eof() ? 0 : 1);
        simdjson::dom::element doc;
        auto error = parser.parse(line).get(doc);
        if (error) ++invalid; else ++valid;
    }
    if (file.bad()) return 74;
    auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
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
              << ",\"version\":\"" << SIMDJSON_VERSION << "\"}]\n";
}
