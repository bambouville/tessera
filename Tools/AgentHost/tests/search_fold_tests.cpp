#include "SearchFold.h"
#include <cassert>
#include <string>

namespace {
std::string values(std::string_view json, tessera::search::RecordKind* kind = nullptr) {
    std::string output;
    const auto found = tessera::search::appendJsonValues(output, json);
    if (kind) *kind = found;
    return output;
}

// Whether the host reads `json` as a candidate for `needle`.
bool candidate(std::string_view needle, std::string_view json) {
    std::string output;
    const auto kind = tessera::search::appendJsonValues(output, json);
    const auto query = tessera::search::query(tessera::search::foldQuery(needle));
    return query.pageAll || kind.composed || tessera::search::matches(query, output);
}

bool composed(std::string_view json) {
    tessera::search::RecordKind kind;
    values(json, &kind);
    return kind.composed;
}
}

int main() {
    using tessera::search::fold; using tessera::search::foldQuery; using tessera::search::query;
    // Case, diacritics and compatibility forms fold alike on both sides.
    assert(fold("NeEdLe") == "needle");
    assert(fold("A Long ASCII Run, Folded @ [Once] {Z}") == "a long ascii run, folded @ [once] {z}");
    assert(fold("N\xC3\x89" "EDLE") == "needle");               // NÉEDLE
    assert(fold("ne\xCC\x81" "edle") == "needle");              // e + combining acute
    assert(fold("\xC3\x9F") == "ss");                           // ß
    assert(fold("\xEF\xAC\x81") == "fi");                       // ﬁ ligature
    assert(fold("\xC4\xB0") == "i");                            // İ
    // Canonically equivalent text folds alike: a composed Hangul syllable
    // and its jamo, a two-part Bengali vowel and its parts.
    assert(fold("\xED\x95\x9C") == "\xE1\x84\x92\xE1\x85\xA1\xE1\x86\xAB");   // 한
    assert(fold("\xEA\xB0\x80") == "\xE1\x84\x80\xE1\x85\xA1");               // 가, no trailing consonant
    assert(fold("\xE1\x84\x92\xE1\x85\xA1\xE1\x86\xAB") == fold("\xED\x95\x9C"));
    assert(fold("\xE0\xA7\x8B") == fold("\xE0\xA7\x87\xE0\xA6\xBE"));         // ো
    assert(fold("\xF0\x90\x90\x80") == "\xF0\x90\x90\xA8");                   // Deseret capital
    assert(fold("\xF0\x9F\x98\x80") == "\xF0\x9F\x98\x80");                   // an emoji: unchanged
    // What the app's match may ignore or its display text strips is dropped:
    // joiners, skin tones, tags, bidi controls, controls, unassigned points.
    assert(fold("a\xE2\x80\x8C" "b") == "ab");                    // ZWNJ
    assert(fold("\xF0\x9F\x91\x8D\xF0\x9F\x8F\xBD") == "\xF0\x9F\x91\x8D");     // thumbs up, medium skin tone
    assert(fold("x\xF3\xA0\x81\xA2y") == "xy");                  // a tag character
    assert(fold("a\xE2\x80\xAE" "b\xEF\xBB\xBF" "c") == "abc");      // RLO, BOM
    assert(fold("a\rb\x01" "c\x7F" "d\xC2\x85" "e\tf\ng") == "abcde\tf\ng");
    assert(fold("a\xF0\xB0\x80\x80" "b").size() == 6);          // assigned CJK: kept
    assert(fold("x\xEE\x80\x80y") == "x\xEE\x80\x80y");          // private use: kept
    // A point this Unicode leaves unassigned marks its text: the app's newer
    // Unicode may pair U+A7D2 with U+A7D3 (Unicode 17 capital and small
    // double thorn), or ignore a new mark.
    assert(fold("a\xEA\x9F\x92" "b") == "a\xFF" "b");
    assert(candidate("\xEA\x9F\x93", R"({"text":"\uA7D2"})") && candidate("zzz", R"({"text":"x\uA7D2"})"));
    assert(candidate("ab\xEA\x9F\x92" "cd", R"({"text":"ab\uA7D3cd"})") && candidate("ab\xEA\x9F\x92" "cd", R"({"text":"cd ab"})"));
    assert(!candidate("ab\xEA\x9F\x92" "cd", R"({"text":"ab"})"));
    assert(!query(foldQuery("ab\xEA\x9F\x92 cd")).phrase && query(foldQuery("ab\xEA\x9F\x92 cd")).words.size() == 2);
    // Space separators read as a space.
    assert(fold("a\xC2\xA0" "b\xE3\x80\x80" "c") == "a b c");
    // Invalid UTF-8 is kept byte for byte, never dropped or merged.
    assert(fold("a\xFF" "b\xC3") == "a\xFF" "b\xC3");
    assert(fold("\xED\xA0\x80") == "\xED\xA0\x80");             // an encoded surrogate

    // Only string values count, each on its own line; keys are structure.
    assert(values(R"({"needle":1,"text":"Hay"})") == "hay\n");
    assert(values(R"({"a" : "x", "b":["Y", {"needle" :"z"}]})") == "x\ny\nz\n");
    // Escapes decode before folding, surrogate pairs included; \r, \b and \f
    // are controls the app strips.
    assert(values(R"({"t":"line\n\"NEEDLE\"\ttab\r\b\f"})") == "line\n\"needle\"\ttab\n");
    assert(values(R"({"t":"nêédle"})") == "needle\n");
    assert(values(R"({"t":"😀!"})") == "\xF0\x9F\x98\x80!\n");
    assert(values(R"({"t":"\ud83d"})") == "\xEF\xBF\xBD\n");    // a lone surrogate reads as U+FFFD
    assert(values(R"({"t":"\/\\\u200d"})") == "/\\\n");
    assert(values("{\"t\":\"a\x7F" "b\\u007Fc\"}") == "abc\n");
    // A record's top-level metadata is never searched, nor its blocks' types.
    assert(values(R"({"type":"message","role":"user","model":"m","branch":"main","project":"tessera",)"
                  R"("permissionMode":"plan","timestamp":"2026","sessionID":"s","turnID":"t","toolCallID":"c",)"
                  R"("providerID":"p","provider":"claude","toolStatus":"ok","providerItemID":"i","stopReason":"end",)"
                  R"("classificationReason":"r","ignoreReason":"g","event":"e",)"
                  R"("blocks":[{"type":"text","text":"Hello","provider":"kept"}],"title":"main"})") == "hello\nkept\nmain\n");
    assert(values(R"({"type":"tool_call","name":"Bash","role":["kept"]})") == "bash\nkept\n");
    assert(!candidate("tool", R"({"type":"message","blocks":[{"type":"tool_call","name":"Bash","preview":"ls"}]})"));
    // Kinds whose shown text the app composes are always candidates.
    tessera::search::RecordKind kind;
    assert(composed(R"({"type":"question","title":"x"})") && composed(R"({"type":"subagent","summary":"x"})"));
    assert(!composed(R"({"type":"message","blocks":[{"type":"text","text":"x"}]})") && !composed(R"({"kind":"question"})"));
    // So is a record the app shows a label of its own in: a nameless tool
    // call ("Tool") or attachment, a system block without text ("System
    // event"), a block it cannot read ("unknown", "invalid-<type>"), or
    // content the provider could not decode ("Unsupported content ...").
    for (const auto labelled : {
             R"({"type":"tool_call","preview":"x"})", R"({"type":"tool-use","name":7})",
             R"({"blocks":[{"type":"tool_call","preview":"x"}]})", R"({"blocks":[{"type":"attachment","mediaType":"image/png"}]})",
             R"({"blocks":[{"type":"system"}]})", R"({"blocks":[{"type":"text"}]})", R"({"blocks":[{"type":"thinking","text":null}]})",
             R"({"blocks":[{"type":"compact-summary"}]})", R"({"blocks":[{"type":"system-event","title":"x"}]})",
             R"({"blocks":[{"type":"edit","path":["a"]}]})", R"({"blocks":[{"type":"attachment","name":"a","mediaType":1}]})",
             R"({"blocks":[{"type":"tool_result","preview":{"a":1}}]})", R"({"blocks":[{"text":"x"}]})",
             R"({"blocks":[{"type":5,"text":"x"}]})", R"({"blocks":[{"type":"fancy","text":"x"}]})",
             R"({"blocks":[{"type":"Text","text":"x"}]})", R"({"blocks":[{"type":"te\u0078t","text":"x"}]})",
             R"({"blocks":[{"type":"text","Text":"x","text":"y"}]})", R"({"blocks":[{"type":"text","type":"text","text":"x"}]})",
             R"({"blocks":["x"]})", R"({"blocks":[1]})", R"({"blocks":[null]})", R"({"blocks":[["x"]]})",
             R"({"blocks":[{"type":"text","text":"x"},true]})", R"({"Blocks":[]})", R"({"Name":"x","type":"tool_call"})",
             R"({"unparsedContentCount":1})", R"({"unparsedContentCount":0.5,"text":"x"})",
             R"({"isCompactSummary":true,"truncated":true,"text":"x"})",
             R"({"type":"system","subtype":"compact_boundary","blocks":[{"type":"text","text":"x","truncated":true}]})"})
        assert(composed(labelled));
    for (const auto plain : {
             R"({"type":"tool_call","name":"Bash"})", R"({"blocks":[{"type":"tool_call","name":"Bash","preview":"ls"}]})",
             R"({"blocks":[{"type":"attachment","name":"a.png","mediaType":"image/png"}]})",
             R"({"blocks":[{"type":"system","text":"x"},{"type":"edit"},{"type":"tool_result"}]})",
             R"({"blocks":[{"type":"text","text":"x","input":{"type":5,"text":7,"name":null}}]})",
             R"({"other":[1,"x",null],"blocks":[]})", R"({"text":{"blocks":[1]}})",
             R"({"unparsedContentCount":0})", R"({"unparsedContentCount":-1})", R"({"unparsedContentCount":"2"})",
             R"({"isCompactSummary":true,"truncated":false,"text":"x"})", R"({"truncated":true,"text":"x"})",
             R"({"isCompactSummary":"true","truncated":true})"})
        assert(!composed(plain));
    assert(candidate("tool", R"({"blocks":[{"type":"tool_call","preview":"ls"}]})"));
    assert(candidate("system event", R"({"blocks":[{"type":"system"}]})"));
    assert(candidate("decoded", R"({"unparsedContentCount":2,"blocks":[{"type":"text","text":"x"}]})"));
    assert(!candidate("decoded", R"({"unparsedContentCount":0,"blocks":[{"type":"text","text":"x"}]})"));
    // A malformed document folds as far as it reads.
    assert(values(R"({"t":"unterminated NEEDLE)") == "unterminated needle");
    assert(values(R"({"t":"bad \u12"})") == "bad ");
    // Values never join across a boundary into a false match.
    assert(values(R"(["nee","dle"])").find("needle") == std::string::npos);
    assert(!candidate("nee dle", R"(["nee","dle"])") && !candidate("needle", R"(["nee","dle"])"));

    // Words: a query holds when every word does, wherever each is, unless
    // only spaces separate them; then the phrase must lie in one value.
    assert(candidate("needle", R"({"type":"message","text":"a NEEDLE here"})"));
    assert(candidate("hay\tneedle", R"({"blocks":[{"type":"text","text":"needle"},{"type":"text","text":"hay"}]})"));
    assert(!candidate("hay needle", R"({"blocks":[{"type":"text","text":"needle"},{"type":"text","text":"hay"}]})"));
    assert(candidate("hay  needle", R"({"text":"hay  needle"})") && !candidate("hay  needle", R"({"text":"hay needle"})"));
    assert(candidate("  needle\n", R"({"text":"needle"})"));
    assert(candidate("hay\xC2\xA0needle", R"({"text":"hay needle"})"));
    // Common words are words: no label of the app's frees them.
    for (const auto word : {"tool", "code", "port", "token", "event", "system event", "content", "could not", "invalid-", "unknown"}) {
        const auto parsed = query(foldQuery(word));
        assert(!parsed.pageAll && (parsed.phrase || !parsed.words.empty()));
        assert(!candidate(word, R"({"text":"hay"})"));
    }
    // A query naming nothing a record must hold pages every record.
    for (const auto bare : {"-", "+", "_", "__", "+ -", "\xC5\x89"}) assert(query(foldQuery(bare)).pageAll || query(foldQuery(bare)).phrase);
    assert(query(foldQuery("\xC5\x89")).pageAll);                // ŉ: only a wildcard after ʼ
    assert(!query(foldQuery("\xE2\x80\x8D")).pageAll && query(foldQuery("\xE2\x80\x8D")).words.empty());
    // Text the app glues on: the underscores around a compacted summary's
    // notice, a diff line's - or +.
    assert(candidate("_compacted away", R"({"text":"compacted away"})"));
    assert(candidate("summary_", R"({"text":"the summary"})"));

    // The app compares only the first character of a multi-character case
    // fold, then lets each other one stand for any one character: "groß"
    // finds "gros " and "gros\n". A clipped value's U+FFFD stands for the
    // character the record holds whole.
    assert(foldQuery("Gro\xC3\x9F") == "gros\xFF" && fold("Gro\xC3\x9F") == "gross");
    assert(foldQuery("\xE1\xBA\x9E") == "s\xFF" && foldQuery("\xEF\xAC\x81" "x") == "f\xFFx");     // ẞ, ﬁx
    assert(foldQuery("ab\xEF\xBF\xBD" "cd") == "ab\xFF" "cd");
    assert(candidate("gro\xC3\x9F", R"({"text":"gros chat"})") && candidate("GRO\xC3\x9F", R"({"text":"gros\nchat"})"));
    assert(candidate("stra\xC3\x9F" "e", R"({"text":"strasxe"})") && !candidate("stra\xC3\x9F" "e", R"({"text":"stra"})"));
    assert(candidate("\xEF\xAC\x81le x", R"({"text":"fyle x"})") && !query(foldQuery("\xEF\xAC\x81le x")).phrase);
    assert(candidate("caf\xEF\xBF\xBD", R"({"text":"caf\u00e9"})"));
    assert(candidate("gross", R"({"text":"gro\u00df"})") && candidate("\xEF\xAC\x81", R"({"text":"fi"})"));

    // An Edit, MultiEdit or Write call shows a diff the app composes from its
    // decoded preview: lines start with - or +, under a hunk header counting
    // them (Edit's start at 0, Write's at 1).
    const auto edit = R"({"type":"message","blocks":[{"type":"tool_call","name":"Edit",)"
                      R"("preview":"{\"file_path\":\"/a.swift\",\"old_string\":\"let \\\"x\\\" = 1\",\"new_string\":\"let caf\\u00e9 = 2\"}"}]})";
    values(edit, &kind); assert(kind.edit && !kind.composed);
    assert(candidate("\"x\" = 1", edit) && candidate("-let \"x\"", edit) && candidate("+let cafe", edit));
    assert(candidate("@@ -0,1 +0,1 @@", edit) && candidate("+0,1", edit) && candidate("/a.swift", edit));
    assert(!candidate("let \"y\"", edit) && !candidate("+0,1", R"({"text":"hay"})"));
    assert(!candidate("0,2", edit) && !candidate("404", edit) && !candidate("@@ -0,1 +1,1 @@", edit));
    const auto write = R"({"blocks":[{"type":"tool_call","preview":"{\"content\":\"line one\\nline \\\"two\\\"\"}","name":"Write"}]})";
    assert(candidate("+line \"two\"", write) && candidate("one\nline", write));
    assert(candidate("@@ -0,0 +1,2 @@", write) && !candidate("+0,2", write));
    // Lines split at LF and CRLF, never at a lone CR; an empty last line is
    // dropped; what the app's display text deletes from the preview is gone
    // before it is decoded, while an escaped one stays.
    const auto counted = [](const char* input, const char* header) {
        std::string json = R"({"blocks":[{"type":"tool_call","name":"Edit","preview":")";
        json += input; json += R"("}]})";
        return candidate(header, json);
    };
    assert(counted(R"({\"old_string\":\"a\\r\\nb\\r\\n\",\"new_string\":\"a\\rb\"})", "@@ -0,2 +0,1 @@"));
    assert(counted(R"({\"old_string\":\"\\n\",\"new_string\":\"\"})", "@@ -0,1 +0,0 @@"));
    assert(counted(R"({\"old_string\":\"a\\n\\u200b\",\"new_string\":\"x\\n\\n\"})", "@@ -0,2 +0,2 @@"));
    assert(counted(R"({\"old_string\":\"\u200e\",\"new_string\":\"x\"})", "@@ -0,0 +0,1 @@"));
    assert(counted(R"({\"old_string\":\"\\u200e\",\"new_string\":\"x\"})", "@@ -0,1 +0,1 @@"));
    assert(counted(R"({\"content\":\"\"})", "@@ -0,0 +0,0 @@"));
    assert(counted(R"({\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\\nc\"},{\"new_string\":\"\",\"old_string\":\"d\\ne\\nf\"}]})",
                   "@@ -0,1 +0,2 @@") &&
           counted(R"({\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\\nc\"},{\"new_string\":\"\",\"old_string\":\"d\\ne\\nf\"}]})",
                   "@@ -0,3 +0,0 @@"));
    assert(!counted(R"({\"old_string\":\"a\",\"new_string\":\"b\"})", "@@ -0,2"));
    // A key read twice leaves the app's choice unknown.
    values(R"({"blocks":[{"type":"tool_call","name":"Edit","preview":"{\"old_string\":\"a\",\"old_string\":\"b\\nc\",\"new_string\":\"\"}"}]})", &kind);
    assert(kind.composed);
    const auto plain = R"({"blocks":[{"type":"tool_call","name":"Bash","preview":"{\"command\":\"echo \\\"hi\\\"\"}"}]})";
    values(plain, &kind); assert(!kind.edit && !kind.composed);
    assert(candidate("echo \\\"hi", plain) && !candidate("echo \"hi", plain) && !candidate("@@", plain));
    return 0;
}
