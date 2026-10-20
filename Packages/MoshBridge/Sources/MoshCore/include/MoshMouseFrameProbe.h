#ifndef TESSERA_MOSH_MOUSE_FRAME_PROBE_H
#define TESSERA_MOSH_MOUSE_FRAME_PROBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Real native frame bytes without a network connection. Scenarios: full (0),
// encoding change (1), resize (2), unchanged diff (3), legacy full frame (4).
size_t mosh_mouse_frame_probe(int mode, int encoding, int scenario,
                             uint8_t *output, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
