#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <cassert>
#include <iostream>
#include <unistd.h>

static std::filesystem::path leafPath, backupPath, otherPath;
static bool replaceLeaf = false, symlinkReplacement = false;
static char* catalogTestRealpath(const char* path, char* resolved) {
    if (replaceLeaf) {
        replaceLeaf = false;
        std::filesystem::rename(leafPath, backupPath);
        if (symlinkReplacement) std::filesystem::create_symlink(otherPath, leafPath);
        else std::filesystem::rename(otherPath, leafPath);
    }
    return ::realpath(path, resolved);
}
// Interpose precisely between the production initial lstat and ancestor
// resolution. This is a deterministic filesystem race, not a timing loop.
#define realpath catalogTestRealpath
#include "../src/Catalog.cpp"
#undef realpath

int main(int argc, char** argv) {
    if (argc == 2 && std::string(argv[1]) == "--layout") {
        std::string raw;
        simdjson::dom::parser parser;
        while (std::getline(std::cin, raw)) {
            simdjson::dom::element value;
            std::string_view path;
            if (parser.parse(raw).get(value) || value.get_string().get(path)) return 65;
            std::cout << (tessera::claudeTranscriptLayout(path) ? "1" : "0") << '\n';
        }
        return 0;
    }
    assert(argc == 1);
    const std::string session = "00000000-0000-0000-0000-000000000001";
    assert(tessera::claudeTranscriptLayout("project/" + session + ".jsonl"));
    assert(tessera::claudeTranscriptLayout("project/" + session + "/subagents/agent-fixture.jsonl"));
    assert(tessera::claudeTranscriptLayout("project/" + session + "/subagents/workflows/run/agent-fixture.jsonl"));
    assert(tessera::claudeTranscriptLayout("project/" + session + "/subagents/workflows/projects/run/agent-fixture.jsonl"));
    assert(tessera::claudeTranscriptLayout("project/" + session + "/subagents/agent-.jsonl"));
    for (const auto& path : std::vector<std::string>{"project/results.jsonl", "project/" + session + "/results.jsonl",
            "project/" + session + "/subagents/workflows/run/results.jsonl",
            "project/not-a-session/subagents/agent-fixture.jsonl"})
        assert(!tessera::claudeTranscriptLayout(path));
    char pattern[] = "/tmp/tessera-catalog-alias-XXXXXX";
    const auto root = ::mkdtemp(pattern); assert(root);
    const auto home = std::filesystem::path(root) / "claude";
    const auto directory = home / "projects/project";
    std::filesystem::create_directories(directory);
    assert(::setenv("CLAUDE_CONFIG_DIR", home.c_str(), 1) == 0);
    assert(::setenv("PI_CODING_AGENT_DIR", (std::filesystem::path(root) / "pi").c_str(), 1) == 0);
    assert(::setenv("CODEX_HOME", (std::filesystem::path(root) / "codex").c_str(), 1) == 0);
    assert(::setenv("XDG_DATA_HOME", (std::filesystem::path(root) / "data").c_str(), 1) == 0);
    assert(::setenv("KIMI_CODE_HOME", (std::filesystem::path(root) / "kimi").c_str(), 1) == 0);
    leafPath = directory / "first.jsonl"; backupPath = directory / "backup.jsonl"; otherPath = directory / "second.jsonl";
    tessera::Catalog catalog;
    for (const bool symlink : {false, true}) {
        std::ofstream(leafPath) << "{}\n";
        std::ofstream(otherPath) << "{}\n";
        replaceLeaf = true; symlinkReplacement = symlink;
        bool rejected = false;
        try { (void)catalog.resolve("claude", leafPath); }
        catch (const std::runtime_error&) { rejected = true; }
        assert(rejected);
        std::filesystem::remove(leafPath); std::filesystem::remove(backupPath);
        std::filesystem::remove(otherPath);
    }
    const auto mainPath = directory / (session + ".jsonl");
    const auto nested = directory / session / "subagents/workflows/run";
    std::filesystem::create_directories(nested);
    std::ofstream(mainPath) << "{\"type\":\"user\"}\n";
    std::ofstream(nested / "agent-fixture.jsonl") << "{\"type\":\"assistant\"}\n";
    std::ofstream(nested / "results.jsonl") << "{\"type\":\"result\"}\n";
    std::ofstream(directory / "results.jsonl") << "{\"type\":\"started\"}\n";
    const auto inventory = catalog.inventory();
    assert(inventory.size() == 2);
    assert(inventory[0].path != inventory[1].path);
    const auto codexDirectory = std::filesystem::path(root) / "codex/sessions";
    const auto archiveDirectory = std::filesystem::path(root) / "codex/archived_sessions";
    std::filesystem::create_directories(codexDirectory);
    std::filesystem::create_directories(archiveDirectory);
    const auto original = codexDirectory / ("rollout-" + session + ".jsonl");
    const auto archived = archiveDirectory / original.filename();
    std::ofstream(original) << "{}\n";
    const auto native = catalog.identifyCodex(session, original, 0);
    assert(catalog.resolveCodexFile(session).path == std::filesystem::canonical(original));
    std::filesystem::rename(original, archived);
    assert(catalog.resolveCodexFile(session).path == std::filesystem::canonical(archived));
    assert(catalog.resolveCodex(session).handle == native.handle);
    assert(catalog.resolveCodexFile(session).path == std::filesystem::canonical(archived));
    std::filesystem::rename(archived, original);
    assert(catalog.resolveCodexFile(session).path == std::filesystem::canonical(original));
    // A present but unsafe confirmed path must not fall back to another file.
    std::filesystem::rename(original, archived);
    std::filesystem::create_symlink(archived, original);
    bool rejectedNativeAlias = false;
    try { (void)catalog.resolveCodexFile(session); }
    catch (const std::runtime_error& error) { rejectedNativeAlias = std::string(error.what()) == "sourceMissing"; }
    assert(rejectedNativeAlias);
    std::filesystem::remove_all(root);
}
