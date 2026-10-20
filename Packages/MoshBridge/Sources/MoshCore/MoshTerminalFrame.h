#ifndef TESSERA_MOSH_TERMINAL_FRAME_H
#define TESSERA_MOSH_TERMINAL_FRAME_H

#include <string>
#include "terminaldisplay.h"
#include "terminalframebuffer.h"

namespace tessera_mosh {

inline std::string terminal_frame(
    const Terminal::Display &display, bool initialized,
    const Terminal::Framebuffer &last, const Terminal::Framebuffer &current) {
    std::string bytes = display.new_frame(initialized, last, current);
    const bool restores_encoding = !initialized
        || last.ds.get_width() != current.ds.get_width()
        || last.ds.get_height() != current.ds.get_height()
        || last.ds.mouse_encoding_mode != current.ds.mouse_encoding_mode;
    if (restores_encoding
        && current.ds.mouse_reporting_mode != Terminal::DrawState::MOUSE_REPORTING_NONE) {
        // SwiftTerm clears tracking when a mouse encoding is reset. Mosh's
        // display restores encoding after tracking, so restore the requested
        // tracking mode last. Use the framebuffer for plain Mosh as well.
        bytes += "\033[?" + std::to_string(current.ds.mouse_reporting_mode) + "h";
    }
    return bytes;
}

} // namespace tessera_mosh

#endif
