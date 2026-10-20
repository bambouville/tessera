#include "BoundedJson.h"
#include "PlainASCII.h"
#include <simdjson.h>
#include <algorithm>

namespace tessera {
void BoundedJson::emit(std::string_view bytes) {
    if (skipping_) return;
    if (output_.size() + bytes.size() > maximumDocument) overBudget_ = true;
    if (!overBudget_) output_.append(bytes);
}

void BoundedJson::beginValue() {
    if (containers_.empty()) {
        if (rootStarted_) invalid_ = true;
        rootStarted_ = true;
        return;
    }
    auto& container = containers_.back();
    const bool expected = container.kind == '{' ? container.state == 3 : container.state == 0 || container.state == 1;
    if (!expected) { invalid_ = true; return; }
    if (!skipping_ && omitCheckpointHistory_ && containers_.size() == 2 && container.kind == '{' &&
        containers_[0].kind == '{' && containers_[0].key == "payload" &&
        (container.key == "guardian_history" || container.key == "replacement_history")) {
        // These are duplicated model context in Codex checkpoints, not new
        // transcript messages. Validate the entire skipped value below, but
        // never retain or recursively normalize its historical messages.
        emit("null"); skipping_ = true; skipDepth_ = containers_.size(); truncated_ = true;
    }
    container.state = 4;
}

void BoundedJson::finishPrimitive() {
    if (primitive_.empty()) return;
    const auto& value = primitive_;
    bool valid = value == "true" || value == "false" || value == "null";
    if (!valid) {
        size_t i = value[0] == '-' ? 1 : 0;
        const auto digit = [&](size_t at) { return at < value.size() && value[at] >= '0' && value[at] <= '9'; };
        if (digit(i)) {
            if (value[i] == '0') ++i;
            else while (digit(i)) ++i;
            bool fraction = true, exponent = true;
            if (i < value.size() && value[i] == '.') { ++i; fraction = digit(i); while (digit(i)) ++i; }
            if (i < value.size() && (value[i] == 'e' || value[i] == 'E')) {
                ++i; if (i < value.size() && (value[i] == '+' || value[i] == '-')) ++i;
                exponent = digit(i); while (digit(i)) ++i;
            }
            valid = fraction && exponent && i == value.size();
        }
    }
    if (!valid) invalid_ = true;
    primitive_.clear();
    if (skipping_ && containers_.size() == skipDepth_) skipping_ = false;
}

void BoundedJson::structural(unsigned char c) {
    const bool space = c == ' ' || c == '\t' || c == '\r' || c == '\n';
    const bool punctuation = c == '{' || c == '}' || c == '[' || c == ']' || c == ':' || c == ',' || c == '"';
    if (!primitive_.empty() && (space || punctuation)) finishPrimitive();
    if (space) { emit(std::string_view(reinterpret_cast<const char*>(&c), 1)); return; }
    if (c == '"') {
        keyString_ = !containers_.empty() && containers_.back().kind == '{' && containers_.back().state <= 1;
        key_.clear();
        if (!keyString_) beginValue();
        emit("\""); inString_ = true; retained_ = 0; return;
    }
    if (c == '{' || c == '[') {
        beginValue(); emit(std::string_view(reinterpret_cast<const char*>(&c), 1));
        if (containers_.size() >= 128) { overBudget_ = true; parsingAborted_ = true; return; }
        containers_.push_back({static_cast<char>(c), 0, {}}); return;
    }
    if (c == '}' || c == ']') {
        if (containers_.empty() || containers_.back().kind != (c == '}' ? '{' : '[') ||
            (containers_.back().state != 0 && containers_.back().state != 4)) { invalid_ = true; return; }
        emit(std::string_view(reinterpret_cast<const char*>(&c), 1)); containers_.pop_back();
        if (skipping_ && containers_.size() == skipDepth_) skipping_ = false;
        return;
    }
    if (c == ':' || c == ',') {
        if (containers_.empty()) { invalid_ = true; return; }
        auto& container = containers_.back();
        if (c == ':') {
            if (container.kind != '{' || container.state != 2) invalid_ = true;
            container.state = 3;
        } else {
            if (container.state != 4) invalid_ = true;
            container.state = 1;
        }
        emit(std::string_view(reinterpret_cast<const char*>(&c), 1)); return;
    }
    if (primitive_.empty()) beginValue();
    if (primitive_.size() >= 1024) { overBudget_ = true; parsingAborted_ = true; return; }
    primitive_ += static_cast<char>(c); emit(std::string_view(reinterpret_cast<const char*>(&c), 1));
}

void BoundedJson::endString() {
    if (keyString_) {
        if (containers_.empty() || containers_.back().kind != '{') { invalid_ = true; return; }
        if (retained_ > maximumString) {
            // The whole key was syntax-validated while streaming, but cannot
            // be used as a renamed/truncated discriminator. Capacity is not
            // malformed JSON, and decoding an incomplete key buffer is wrong.
            overBudget_ = true; containers_.back().key.clear(); containers_.back().state = 2;
            return;
        }
        // Only escaped keys need decoding to recognize the two selected
        // paths. Ordinary keys avoid another parser invocation entirely.
        if (key_.find('\\') != std::string::npos) {
            simdjson::dom::parser parser; simdjson::dom::element key;
            std::string_view decoded;
            if (parser.parse("\"" + key_ + "\"").get(key) || key.get_string().get(decoded)) invalid_ = true;
            else key_ = std::string(decoded);
        }
        containers_.back().key = key_; containers_.back().state = 2;
    } else if (skipping_ && containers_.size() == skipDepth_) skipping_ = false;
}

void BoundedJson::feed(std::string_view bytes) {
    for (size_t offset = 0; offset < bytes.size();) {
        if (parsingAborted_) return;
        if (inString_ && !keyString_ && !escape_ && !utf8Remaining_) {
            const auto length = detail::plainASCII(bytes.substr(offset));
            if (length) {
                const auto kept = retained_ <= maximumString ? std::min(length, maximumString - retained_) : 0;
                emit(bytes.substr(offset, kept));
                if (kept < length) { retained_ = maximumString + 1; truncated_ = true; }
                else retained_ += kept;
                offset += length;
                continue;
            }
        }
        const auto c = static_cast<unsigned char>(bytes[offset++]);
        if (!inString_) {
            if (c == ':' && closedTruncated_) overBudget_ = true; // Never rename a JSON key.
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') closedTruncated_ = false;
            structural(c);
            continue;
        }
        if (keyString_ && !(c == '"' && !escape_ && !utf8Remaining_)) {
            // A decoded byte can occupy six JSON bytes (\u00XX). Keep a full
            // valid key spelling up to the decoded limit used by emitUnit.
            if (key_.size() < maximumString * 6) key_ += static_cast<char>(c);
            else overBudget_ = true;
        }
        auto emitUnit = [&](std::string_view value, size_t decodedBytes) {
            // truncated_ describes the document; retained_ fences this string.
            if (retained_ <= maximumString && retained_ + decodedBytes <= maximumString) {
                emit(value);
                retained_ += decodedBytes;
            } else { retained_ = maximumString + 1; truncated_ = true; }
        };
        if (utf8Remaining_) {
            if ((c & 0xc0) != 0x80) { invalid_ = true; utf8Remaining_ = 0; continue; }
            pending_ += static_cast<char>(c);
            codepoint_ = (codepoint_ << 6) | (c & 0x3f);
            if (!--utf8Remaining_) {
                if (codepoint_ < minimumCodepoint_ || codepoint_ > 0x10ffff ||
                    (codepoint_ >= 0xd800 && codepoint_ <= 0xdfff)) invalid_ = true;
                emitUnit(pending_, pending_.size());
                pending_.clear();
            }
            continue;
        }
        if (escape_) {
            pending_ += static_cast<char>(c);
            if (escape_ == 1) {
                if (c == 'u') { escape_ = 2; digits_ = 4; unicode_ = 0; }
                else {
                    if (c != '"' && c != '\\' && c != '/' && c != 'b' && c != 'f' && c != 'n' && c != 'r' && c != 't') invalid_ = true;
                    emitUnit(pending_, 1); pending_.clear(); escape_ = 0;
                }
            } else if (escape_ == 3) {
                if (c != '\\') invalid_ = true;
                escape_ = 4;
            } else if (escape_ == 4) {
                if (c != 'u') invalid_ = true;
                escape_ = 5; digits_ = 4; unicode_ = 0;
            } else {
                int hex = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
                if (hex < 0) invalid_ = true;
                unicode_ = (unicode_ << 4) | static_cast<uint32_t>(hex < 0 ? 0 : hex);
                if (!--digits_) {
                    if (escape_ == 2 && unicode_ >= 0xd800 && unicode_ <= 0xdbff) escape_ = 3;
                    else {
                        if ((escape_ == 5 && (unicode_ < 0xdc00 || unicode_ > 0xdfff)) ||
                            (escape_ == 2 && unicode_ >= 0xdc00 && unicode_ <= 0xdfff)) invalid_ = true;
                        const size_t decodedBytes = escape_ == 5 ? 4 : unicode_ < 0x80 ? 1 : unicode_ < 0x800 ? 2 : 3;
                        emitUnit(pending_, decodedBytes); pending_.clear(); escape_ = 0;
                    }
                }
            }
            continue;
        }
        if (c == '"') { emit("\""); inString_ = false; closedTruncated_ = retained_ > maximumString; endString(); }
        else if (c == '\\') { escape_ = 1; pending_ = "\\"; }
        else if (c < 0x20) invalid_ = true;
        else if (c < 0x80) emitUnit(std::string_view(reinterpret_cast<const char*>(&c), 1), 1);
        else {
            pending_.assign(1, static_cast<char>(c));
            if (c >= 0xc2 && c <= 0xdf) { utf8Remaining_ = 1; codepoint_ = c & 0x1f; minimumCodepoint_ = 0x80; }
            else if (c >= 0xe0 && c <= 0xef) { utf8Remaining_ = 2; codepoint_ = c & 0x0f; minimumCodepoint_ = 0x800; }
            else if (c >= 0xf0 && c <= 0xf4) { utf8Remaining_ = 3; codepoint_ = c & 7; minimumCodepoint_ = 0x10000; }
            else { invalid_ = true; pending_.clear(); }
        }
    }
}

bool BoundedJson::malformed() const {
    return invalid_ || (!parsingAborted_ && (inString_ || escape_ || utf8Remaining_ || !containers_.empty() || !rootStarted_ || !primitive_.empty()));
}
}
