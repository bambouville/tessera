#include "include/MoshMouseFrameProbe.h"
#include "MoshTerminalFrame.h"

#include <cstring>

extern "C" size_t mosh_mouse_frame_probe(
    int mode, int encoding, int scenario, uint8_t *output, size_t capacity) {
    if ((mode != 0 && mode != 9 && mode != 1000 && mode != 1002 && mode != 1003)
        || (encoding != 0 && encoding != 1005 && encoding != 1006 && encoding != 1015)
        || scenario < 0 || scenario > 4) {
        return 0;
    }
    Terminal::Framebuffer current(12, 3);
    current.ds.mouse_reporting_mode = static_cast<Terminal::DrawState::MouseReportingMode>(mode);
    current.ds.mouse_encoding_mode = static_cast<Terminal::DrawState::MouseEncodingMode>(encoding);
    Terminal::Framebuffer last = current;
    if (scenario == 1) {
        last.ds.mouse_encoding_mode = encoding == 1006
            ? Terminal::DrawState::MOUSE_ENCODING_UTF8 : Terminal::DrawState::MOUSE_ENCODING_SGR;
        if (mode == 0) last.ds.mouse_reporting_mode = Terminal::DrawState::MOUSE_REPORTING_ANY_EVENT;
    } else if (scenario == 2) {
        last = Terminal::Framebuffer(8, 3);
        last.ds.mouse_reporting_mode = current.ds.mouse_reporting_mode;
        last.ds.mouse_encoding_mode = current.ds.mouse_encoding_mode;
    }
    const Terminal::Display display(false);
    const std::string bytes = scenario == 4
        ? display.new_frame(false, last, current)
        : tessera_mosh::terminal_frame(display, scenario != 0, last, current);
    if (bytes.size() > capacity || (output == nullptr && !bytes.empty())) return 0;
    if (!bytes.empty()) std::memcpy(output, bytes.data(), bytes.size());
    return bytes.size();
}
