#pragma once
#include "PlainASCII.h"
#include "SearchFoldTable.h"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace tessera {
// The host search prefilter. The query and each record's string values fold
// the same way: ASCII lowercased, controls other than tab and newline dropped,
// other characters through the generated case and diacritic fold (Hangul
// syllables arithmetically), and invalid UTF-8 bytes kept as is. A code point
// this host's Unicode leaves unassigned folds to the byte 0xFF, which valid
// UTF-8 never holds: the app's newer Unicode may fold or ignore it, so text
// holding one is always a candidate, and a query word ends there. A record is
// a candidate when it may hold the query as the app shows it, or when the app
// shows a label of its own in it. The app matches every candidate again, so
// the prefilter may accept records the app rejects but must never reject one
// it accepts.
namespace search {
// Appends a run of plain ASCII lowercased, in one copy.
inline void appendLowered(std::string& output, std::string_view run) {
    const auto start = output.size();
    output.append(run);
    auto* data = reinterpret_cast<unsigned char*>(output.data() + start);
    for (size_t index = 0; index < run.size(); ++index)
        data[index] = static_cast<unsigned char>(data[index] + (static_cast<unsigned char>(data[index] - 'A') < 26 ? 32 : 0));
}

// Printable ASCII at the start of `text` (plainASCII admits DEL, which the
// fold drops).
inline size_t printableRun(std::string_view text) {
    auto run = detail::plainASCII(text);
    if (const void* del = run ? std::memchr(text.data(), 0x7f, run) : nullptr)
        run = static_cast<size_t>(static_cast<const char*>(del) - text.data());
    return run;
}

inline void appendEncoded(std::string& output, uint32_t point) {
    if (point < 0x800) {
        output.push_back(static_cast<char>(0xC0 | (point >> 6)));
        output.push_back(static_cast<char>(0x80 | (point & 0x3F)));
    } else if (point < 0x10000) {
        output.push_back(static_cast<char>(0xE0 | (point >> 12)));
        output.push_back(static_cast<char>(0x80 | ((point >> 6) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | (point & 0x3F)));
    } else {
        output.push_back(static_cast<char>(0xF0 | (point >> 18)));
        output.push_back(static_cast<char>(0x80 | ((point >> 12) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | ((point >> 6) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | (point & 0x3F)));
    }
}

inline void appendPoint(std::string& output, uint32_t point) {
    if (point < 0x80) {
        if ((point < 0x20 && point != '\t' && point != '\n') || point == 0x7f) return;
        output.push_back(static_cast<char>(point >= 'A' && point <= 'Z' ? point + 32 : point));
        return;
    }
    if (point >= 0xAC00 && point <= 0xD7A3) {
        // Leading consonant, vowel, and any trailing consonant (Unicode 3.12).
        const uint32_t index = point - 0xAC00;
        appendPoint(output, 0x1100 + index / 588);
        appendPoint(output, 0x1161 + index % 588 / 28);
        if (index % 28) appendPoint(output, 0x11A7 + index % 28);
        return;
    }
    // Most text sits in blocks of 256 points the fold leaves alone.
    if (!(search_fold::blocks[point >> 11] >> ((point >> 8) & 7) & 1)) { appendEncoded(output, point); return; }
    const auto* range = std::upper_bound(std::begin(search_fold::ranges), std::end(search_fold::ranges), point,
        [](uint32_t value, const search_fold::Range& entry) { return value < entry.first; });
    if (range != std::begin(search_fold::ranges) && point <= (range - 1)->last) {
        if ((range - 1)->unassigned) output.push_back('\xFF');
        return;
    }
    const auto* begin = std::begin(search_fold::entries), *end = std::end(search_fold::entries);
    const auto* found = std::lower_bound(begin, end, point, [](const search_fold::Entry& entry, uint32_t value) {
        return entry.point < value;
    });
    if (found != end && found->point == point)
        output.append(reinterpret_cast<const char*>(search_fold::pool) + found->offset, found->length);
    else appendEncoded(output, point);
}

// Decodes one UTF-8 sequence at text[index]; an invalid byte is returned as
// U+FFFD's stand-in, a point above U+10FFFF, so it is copied unchanged.
inline uint32_t decode(std::string_view text, size_t& index) {
    const auto lead = static_cast<unsigned char>(text[index++]);
    if (lead < 0x80) return lead;
    size_t length = lead >= 0xF0 && lead < 0xF5 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC2 && lead < 0xE0 ? 1 : 0;
    if (lead >= 0xF5) length = 0;
    uint32_t point = length == 3 ? lead & 0x07 : length == 2 ? lead & 0x0F : lead & 0x1F;
    if (!length || index + length > text.size()) return 0x110000u | lead;
    for (size_t i = 0; i < length; ++i) {
        const auto next = static_cast<unsigned char>(text[index + i]);
        if ((next & 0xC0) != 0x80) return 0x110000u | lead;
        point = (point << 6) | (next & 0x3F);
    }
    if ((length == 2 && point < 0x800) || (length == 3 && (point < 0x10000 || point > 0x10FFFF)) ||
        (point >= 0xD800 && point <= 0xDFFF)) return 0x110000u | lead;
    index += length;
    return point;
}

inline void appendText(std::string& output, std::string_view text) {
    for (size_t index = 0; index < text.size();) {
        if (const auto run = printableRun(text.substr(index))) { appendLowered(output, text.substr(index, run)); index += run; continue; }
        const auto point = decode(text, index);
        if (point > 0x10FFFF) output.push_back(static_cast<char>(point & 0xFF));
        else appendPoint(output, point);
    }
}

inline std::string fold(std::string_view text) {
    std::string output; output.reserve(text.size()); appendText(output, text); return output;
}

// Folds a query. The app's match compares only the first character of a
// multi-character case fold (ß as s, then any one character of the text), and
// a value it clips by bytes may end in U+FFFD where the record holds the whole
// character: a query word ends after either. Right after such a fold the app
// also matches Thai and Lao SARA AM (ำ, ຳ) to nothing, as it does the marks
// this fold drops.
inline std::string foldQuery(std::string_view text) {
    std::string output; output.reserve(text.size());
    bool afterExpansion = false;
    for (size_t index = 0; index < text.size();) {
        if (const auto run = printableRun(text.substr(index))) {
            appendLowered(output, text.substr(index, run)); index += run; afterExpansion = false; continue;
        }
        const auto point = decode(text, index);
        if (point > 0x10FFFF) { output.push_back(static_cast<char>(point & 0xFF)); afterExpansion = false; continue; }
        if (point == 0xFFFD) { output.push_back('\xFF'); afterExpansion = false; continue; }
        if (afterExpansion && (point == 0x0E33 || point == 0x0EB3)) continue;
        const auto* end = std::end(search_fold::expansions);
        const auto* found = std::lower_bound(std::begin(search_fold::expansions), end, point,
            [](const search_fold::Expansion& entry, uint32_t value) { return entry.point < value; });
        if (found == end || found->point != point) {
            const auto size = output.size();
            appendPoint(output, point);
            afterExpansion = afterExpansion && output.size() == size;
            continue;
        }
        appendPoint(output, found->first);
        output.push_back('\xFF');
        afterExpansion = true;
    }
    return output;
}

inline int hexadecimal(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

inline bool readHex(std::string_view json, size_t index, uint32_t& value) {
    if (index + 4 > json.size()) return false;
    value = 0;
    for (size_t i = 0; i < 4; ++i) {
        const auto digit = hexadecimal(json[index + i]);
        if (digit < 0) return false;
        value = (value << 4) | static_cast<uint32_t>(digit);
    }
    return true;
}

// Decodes the JSON escape at json[index], a backslash; false when it is cut
// short.
inline bool unescape(std::string_view json, size_t& index, uint32_t& point) {
    if (index + 1 >= json.size()) return false;
    const char escape = json[index + 1]; index += 2;
    switch (escape) {
    case 'n': point = '\n'; return true;
    case 't': point = '\t'; return true;
    case 'r': point = '\r'; return true;
    case 'b': point = '\b'; return true;
    case 'f': point = '\f'; return true;
    case 'u':
        if (!readHex(json, index, point)) return false;
        index += 4;
        if (point >= 0xD800 && point <= 0xDBFF && index + 6 <= json.size() && json[index] == '\\' && json[index + 1] == 'u') {
            uint32_t low = 0;
            if (readHex(json, index + 2, low) && low >= 0xDC00 && low <= 0xDFFF) {
                point = 0x10000 + ((point - 0xD800) << 10) + (low - 0xDC00); index += 6;
            }
        }
        if (point >= 0xD800 && point <= 0xDFFF) point = 0xFFFD;
        return true;
    default: point = static_cast<unsigned char>(escape); return true;
    }
}

// A value's lines as the app splits it for a diff: at each LF, CRLF included,
// the last line dropped when empty.
struct Lines {
    size_t points = 0, breaks = 0;
    bool trailingBreak = false;
    size_t count() const { return points ? breaks + !trailingBreak : 0; }
};

// Folds the JSON string that starts at json[index], just past its opening
// quote, into `value`; false when the document ends inside it.
inline bool readString(std::string_view json, size_t& index, std::string& value, Lines* lines = nullptr) {
    while (index < json.size()) {
        if (const auto run = printableRun(json.substr(index))) {
            appendLowered(value, json.substr(index, run)); index += run;
            if (lines) { lines->points += run; lines->trailingBreak = false; }
            continue;
        }
        if (json[index] == '"') { ++index; return true; }
        uint32_t point = 0;
        if (json[index] != '\\') point = decode(json, index);
        else if (!unescape(json, index, point)) { index = json.size(); return false; }
        if (lines) { ++lines->points; lines->breaks += point == '\n'; lines->trailingBreak = point == '\n'; }
        if (point > 0x10FFFF) value.push_back(static_cast<char>(point & 0xFF));
        else appendPoint(value, point);
    }
    return false;
}

inline bool jsonSpace(char value) { return value == ' ' || value == '\n' || value == '\r' || value == '\t'; }

// Whether a string read up to `index` is an object key.
inline bool keyFollows(std::string_view json, size_t index) {
    while (index < json.size() && jsonSpace(json[index])) ++index;
    return index < json.size() && json[index] == ':';
}

// Characters the app's display text deletes (AgentDisplayText.sanitize).
inline bool displayStrips(uint32_t point) {
    return (point < 0x20 && point != '\t' && point != '\n') || (point >= 0x7F && point <= 0x9F) || point == 0x061C ||
        point == 0x200E || point == 0x200F || (point >= 0x202A && point <= 0x202E) || (point >= 0x2066 && point <= 0x2069) ||
        point == 0xFEFF;
}

// A JSON string's contents as the app holds the value: escapes decoded and
// what its display text deletes deleted, otherwise unfolded.
inline std::string displayed(std::string_view raw) {
    std::string text; text.reserve(raw.size());
    for (size_t index = 0; index < raw.size();) {
        const auto start = index;
        uint32_t point = 0;
        if (raw[index] != '\\') point = decode(raw, index);
        else if (!unescape(raw, index, point)) break;
        if (point > 0x10FFFF) text.push_back(raw[start]);
        else if (displayStrips(point)) continue;
        else if (point < 0x80) text.push_back(static_cast<char>(point));
        else appendEncoded(text, point);
    }
    return text;
}

// Top-level keys whose values are structure or metadata: the app searches a
// record's blocks and authored fields, never these, and a common word in them
// ("message", a branch, the project) would make every record a candidate.
inline bool metadataKey(std::string_view key) {
    static constexpr std::string_view keys[] = {"branch", "classificationreason", "event", "ignorereason", "model",
        "permissionmode", "project", "provider", "provideritemid", "providerid", "role", "sessionid", "stopreason",
        "timestamp", "toolcallid", "toolstatus", "turnid", "type"};
    return std::find(std::begin(keys), std::end(keys), key) != std::end(keys);
}

// Record kinds whose shown text the app composes from defaults, joined fields
// and record IDs ("Question", "Option 2", a task's "title owner"). They are
// rare, so each is a candidate whatever its values; the app's match decides.
inline bool composedKind(std::string_view type) {
    static constexpr std::string_view kinds[] = {"agent", "permission", "permission_request", "question", "subagent",
        "task-list", "workflow"};
    return std::find(std::begin(kinds), std::end(kinds), type) != std::end(kinds);
}

// A block of a record's `blocks`, as the app reads it. A block of another
// type shows its type; one missing the field it shows, or holding a field
// that is not a string, shows a label ("Tool", "attachment", "System event",
// "unknown", "invalid-<type>"). Its type value is never shown otherwise.
inline constexpr std::string_view blockFields[] = {"type", "text", "preview", "name", "path", "diff", "mediaType"};
// The same, folded as keys are read.
inline constexpr std::string_view foldedBlockFields[] = {"type", "text", "preview", "name", "path", "diff", "mediatype"};
inline bool labelledBlock(std::string_view type, unsigned strings) {
    static constexpr std::string_view known[] = {"attachment", "compact-summary", "edit", "system", "system-event", "text",
        "thinking", "tool_call", "tool_result"};
    const bool text = strings >> 1 & 1, name = strings >> 3 & 1;
    if (!(strings & 1) || std::find(std::begin(known), std::end(known), type) == std::end(known)) return true;
    if (!text && (type == "text" || type == "thinking" || type == "compact-summary" || type == "system-event" || type == "system"))
        return true;
    return !name && (type == "tool_call" || type == "attachment");
}

struct RecordKind {
    // Always a candidate: the app composes its text or shows a label in it,
    // or it holds a code point this host cannot fold.
    bool composed = false;
    // Holds an Edit, MultiEdit or Write call, which the app shows as a diff.
    bool edit = false;
};

// Folds an Edit, MultiEdit or Write call's input as the app shows it decoded:
// each string value, and over each change the hunk header the app writes
// ("@@ -0,1 +0,2 @@"), for an old_string and new_string pair in one object or
// a whole-file content, which starts at line 1. A key read twice leaves the
// app's choice unknown: the record is then always a candidate.
inline void appendEditInput(std::string& output, std::string_view json, bool& composed) {
    struct Change { size_t removed = SIZE_MAX, added = SIZE_MAX; };
    std::vector<Change> open;
    std::string value;
    int key = 0;
    const auto header = [&](size_t removed, size_t start, size_t added) {
        output += "@@ -0,"; output += std::to_string(removed); output += " +"; output += std::to_string(start);
        output.push_back(','); output += std::to_string(added); output += " @@\n";
    };
    for (size_t index = 0; index < json.size();) {
        const char next = json[index];
        if (next == '{' || next == '[') { open.emplace_back(); key = 0; ++index; continue; }
        if (next == '}' || next == ']') {
            if (!open.empty()) {
                const auto change = open.back(); open.pop_back();
                if (change.removed != SIZE_MAX && change.added != SIZE_MAX) header(change.removed, 0, change.added);
            }
            ++index; continue;
        }
        if (next != '"') {
            if (!jsonSpace(next) && next != ':' && next != ',') key = 0;
            ++index; continue;
        }
        ++index;
        value.clear();
        Lines lines;
        const bool closed = readString(json, index, value, &lines);
        if (closed && keyFollows(json, index)) {
            key = value == "old_string" ? 1 : value == "new_string" ? 2 : value == "content" ? 3 : 0;
            continue;
        }
        output += value; output.push_back('\n');
        if (!closed) return;
        if (key == 3) header(0, lines.count() ? 1 : 0, lines.count());
        else if (key && !open.empty()) {
            auto& count = key == 1 ? open.back().removed : open.back().added;
            if (count != SIZE_MAX) composed = true;
            count = lines.count();
        }
        key = 0;
    }
}

// Folds every string value of one JSON record into `output`, decoding its
// escapes, each value followed by a newline, as the app joins blocks and
// fields: a query matches within one value. Object keys, the record's
// top-level metadata and its blocks' types are skipped. An Edit, MultiEdit or
// Write call's preview is JSON the app decodes into a diff, so its input is
// appended as that diff shows it too. A malformed document folds as far as it
// reads.
inline RecordKind appendJsonValues(std::string& output, std::string_view json) {
    RecordKind kind;
    std::string value, recordType;
    const auto begin = output.size();
    size_t depth = 0;
    bool recordNamed = false, inBlocks = false, inBlock = false, compactSummary = false, truncated = false;
    // The key whose value comes next, and what that value decides.
    bool keyed = false, skip = false, typeKey = false, nameKey = false, previewKey = false, recordNameKey = false,
        unparsedKey = false, blocksKey = false, compactKey = false, subtypeKey = false, truncatedKey = false;
    int field = -1;
    // The block being read: its type, and the fields it holds as strings.
    std::string_view blockType;
    unsigned blockStrings = 0;
    // Each JSON object preview, as a span of `json`.
    std::vector<std::pair<size_t, size_t>> previews;
    const auto finish = [&] {
        if (kind.edit)
            for (const auto& [start, length] : previews) appendEditInput(output, displayed(json.substr(start, length)), kind.composed);
        // A tool call without a name: the app shows "Tool". A shortened
        // compacted summary: the app glues "_Shortened preview · some content
        // is omitted_" into the summary's text.
        if ((recordType == "tool_call" || recordType == "tool-use") && !recordNamed) kind.composed = true;
        if (compactSummary && truncated) kind.composed = true;
        kind.composed = kind.composed || output.find('\xFF', begin) != std::string::npos;
        return kind;
    };
    for (size_t index = 0; index < json.size();) {
        const char next = json[index];
        if (jsonSpace(next) || next == ',' || next == ':') { ++index; continue; }
        if (next == '}' || next == ']') {
            if (depth == 3 && inBlock) { inBlock = false; kind.composed = kind.composed || labelledBlock(blockType, blockStrings); }
            else if (depth == 2 && inBlocks) inBlocks = false;
            if (depth) --depth;
            keyed = false; ++index; continue;
        }
        // A value starts here: a key's, or an array element.
        const bool element = !keyed && inBlocks && depth == 2;
        // A block that is not an object: "invalid-block".
        if (element && next != '{') kind.composed = true;
        if (next != '"') {
            if (keyed && field >= 0) kind.composed = true;
            if (next == '{' || next == '[') {
                if (keyed && blocksKey && next == '[') inBlocks = true;
                if (element && next == '{') { inBlock = true; blockType = {}; blockStrings = 0; }
                ++depth; keyed = false; ++index; continue;
            }
            // A number or literal.
            const auto start = index;
            while (index < json.size() && !jsonSpace(json[index]) && std::string_view(",:]}\"{[").find(json[index]) == std::string_view::npos)
                ++index;
            if (index == start) ++index;
            const auto token = json.substr(start, index - start);
            // Undecodable blocks: "Unsupported content · some blocks could not be decoded".
            if (keyed && unparsedKey && token[0] != '-' && token.find_first_of("123456789") != std::string_view::npos)
                kind.composed = true;
            if (keyed && token == "true") { compactSummary = compactSummary || compactKey; truncated = truncated || truncatedKey; }
            keyed = false; continue;
        }
        ++index;
        const auto rawStart = index;
        value.clear();
        if (!readString(json, index, value)) { output += value; return finish(); }
        const auto raw = json.substr(rawStart, index - 1 - rawStart);
        if (keyFollows(json, index)) {
            keyed = true;
            skip = depth == 1 && metadataKey(value);
            typeKey = depth == 1 && value == "type";
            unparsedKey = depth == 1 && value == "unparsedcontentcount";
            recordNameKey = depth == 1 && raw == "name";
            compactKey = depth == 1 && value == "iscompactsummary";
            subtypeKey = depth == 1 && value == "subtype";
            truncatedKey = value == "truncated";
            blocksKey = depth == 1 && raw == "blocks";
            // A key the app may read under another spelling.
            if (depth == 1 && ((value == "name" && !recordNameKey) || (value == "blocks" && !blocksKey))) kind.composed = true;
            field = -1;
            if (inBlock && depth == 3)
                for (size_t candidate = 0; candidate < std::size(blockFields); ++candidate) {
                    if (raw == blockFields[candidate]) field = static_cast<int>(candidate);
                    else if (value == foldedBlockFields[candidate]) kind.composed = true;
                }
            nameKey = value == "name"; previewKey = value == "preview";
            continue;
        }
        const bool wasKeyed = keyed;
        keyed = false;
        if (!wasKeyed) { output += value; output.push_back('\n'); continue; }
        if (skip) {
            if (typeKey) { recordType = value; kind.composed = kind.composed || composedKind(value); }
            continue;
        }
        if (recordNameKey) recordNamed = true;
        if (subtypeKey && value == "compact_boundary") compactSummary = true;
        if (field >= 0) {
            if (blockStrings >> field & 1) kind.composed = true;
            blockStrings |= 1u << field;
            if (field == 0) { blockType = raw; continue; }
        }
        if (nameKey && (value == "edit" || value == "multiedit" || value == "write")) kind.edit = true;
        const auto lead = value.find_first_not_of(" \t\n");
        if (previewKey && lead != std::string::npos && value[lead] == '{') previews.emplace_back(rawStart, raw.size());
        output += value; output.push_back('\n');
    }
    return finish();
}

// The part of folded query text a record must hold. The app glues a notice
// into a compacted summary as _notice_ and starts an Edit diff's lines with +
// or -: text may run on from those into the record's own, so only what
// follows is required.
inline std::string_view requiredPart(std::string_view text) {
    while (!text.empty() && text.back() == '_') text.remove_suffix(1);
    while (!text.empty() && (text.front() == '_' || text.front() == '+' || text.front() == '-')) text.remove_prefix(1);
    return text;
}

// A folded query as the host matches it: words a record must hold, each
// anywhere in it. A query whose words only spaces separate must instead lie
// within one value, since the app joins values with newlines.
struct Query {
    std::vector<std::string> words;
    std::optional<std::string> phrase;
    // The query names nothing a record must hold: no record can be skipped.
    bool pageAll = false;
};

inline Query query(std::string_view needle) {
    Query result;
    constexpr std::string_view separators(" \t\n\xFF", 4);
    const auto first = needle.find_first_not_of(separators), last = needle.find_last_not_of(separators);
    // Only what the app may read as any character: nothing to require. A
    // query that folds away entirely is no query.
    if (first == std::string_view::npos) { result.pageAll = needle.find('\xFF') != std::string_view::npos; return result; }
    const auto trimmed = needle.substr(first, last - first + 1);
    for (size_t index = 0; index < trimmed.size();) {
        const auto start = trimmed.find_first_not_of(separators, index);
        const auto end = std::min(trimmed.find_first_of(separators, start), trimmed.size());
        if (const auto part = requiredPart(trimmed.substr(start, end - start)); !part.empty()) result.words.emplace_back(part);
        index = end;
    }
    if (trimmed.find_first_of(separators.substr(1)) == std::string_view::npos && trimmed.find(' ') != std::string_view::npos)
        result.phrase = std::string(requiredPart(trimmed));
    result.pageAll = result.words.empty() && !result.phrase;
    return result;
}

inline bool matches(const Query& query, std::string_view folded) {
    if (query.phrase) return folded.find(*query.phrase) != std::string_view::npos;
    for (const auto& word : query.words)
        if (folded.find(word) == std::string_view::npos) return false;
    return true;
}
}
}
