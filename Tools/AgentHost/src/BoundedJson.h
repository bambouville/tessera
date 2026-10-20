#pragma once
#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace tessera {
// Streaming string projection for oversized JSON records. Structure and every
// string's escape/UTF-8 validity are checked; skipped bytes never enter the DOM.
// The normal <=1 MiB path goes directly through simdjson instead.
class BoundedJson {
public:
    static constexpr size_t maximumDocument = 1048576;
    // Count decoded UTF-8 bytes, not JSON escape spelling. Equal text must
    // keep the same prefix whether serialized literally or with \u escapes.
    // Opaque transport strings are rejected above 2,048 decoded bytes, well
    // below this bound; clipping cannot shorten them into an accepted cursor.
    // The encoded document remains independently capped at maximumDocument.
    static constexpr size_t maximumString = 16384;
    explicit BoundedJson(bool omitCheckpointHistory = false) : omitCheckpointHistory_(omitCheckpointHistory) {}
    void feed(std::string_view bytes);
    bool malformed() const;
    bool unsupported() const { return overBudget_; }
    bool truncated() const { return truncated_; }
    const std::string& json() const { return output_; }
    size_t retainedBytes() const {
        size_t bytes = sizeof(*this) + output_.capacity() + primitive_.capacity() + key_.capacity() + pending_.capacity() +
            containers_.capacity() * sizeof(Container);
        for (const auto& entry : containers_) bytes += entry.key.capacity();
        return bytes;
    }
private:
    void emit(std::string_view bytes);
    void structural(unsigned char c);
    void beginValue();
    void endString();
    void finishPrimitive();
    struct Container { char kind; int state = 0; std::string key; };
    std::vector<Container> containers_;
    std::string primitive_, key_;
    bool rootStarted_ = false, keyString_ = false, omitCheckpointHistory_ = false, skipping_ = false;
    size_t skipDepth_ = 0;
    std::string output_;
    bool inString_ = false, invalid_ = false, overBudget_ = false, truncated_ = false, parsingAborted_ = false;
    bool closedTruncated_ = false;
    size_t retained_ = 0;
    int escape_ = 0, digits_ = 0, utf8Remaining_ = 0;
    uint32_t unicode_ = 0, codepoint_ = 0, minimumCodepoint_ = 0;
    std::string pending_;
};
}
