/* iControl FPS device protocol. Copyright (c) 2026 iControl contributors.
 * SPDX-License-Identifier: GPL-2.0-only */
#ifndef ICONTROL_FPS_PROTOCOL_H
#define ICONTROL_FPS_PROTOCOL_H
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#define FPS_MAX_CONTACTS 10
#define FPS_MAX_ID 16
#define FPS_WATCHDOG_MS 350
#define FPS_HEADER_SIZE 8
#define FPS_CONTACT_SIZE 8

typedef struct { bool down; double x, y; } FPSContact;
typedef struct { FPSContact contacts[FPS_MAX_ID + 1]; uint8_t count, orientation; } FPSState;

static inline uint32_t fps_u32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}
static inline void fps_put_u32(uint8_t *bytes, uint32_t value) {
    bytes[0] = value >> 24; bytes[1] = value >> 16; bytes[2] = value >> 8; bytes[3] = value;
}
static inline bool fps_header_valid(const uint8_t *header) {
    if (header[0] == 4) return header[1] <= 1 && header[3] == 0 && (header[2] <= 3 || header[2] == 255);
    return header[0] >= 1 && header[0] <= 3 && header[1] <= FPS_MAX_CONTACTS && header[3] == 0
        && (header[2] <= 3 || header[2] == 255) && (header[0] == 1 || header[1] == 0);
}
static inline bool fps_cursor_decode(const uint8_t *header, const uint8_t *body, FPSContact *point) {
    memset(point, 0, sizeof(*point));
    if (!fps_header_valid(header) || header[0] != 4) return false;
    if (!header[1]) return true;
    if (body[0] || body[1] || body[6] || body[7]) return false;
    *point = (FPSContact){true, ((body[2] << 8) | body[3]) / 65535.0, ((body[4] << 8) | body[5]) / 65535.0};
    return true;
}
static inline bool fps_decode(const uint8_t *header, const uint8_t *body, FPSState *state) {
    memset(state, 0, sizeof(*state));
    if (!fps_header_valid(header) || header[0] == 4) return false;
    state->orientation = header[2]; state->count = header[1];
    for (unsigned i = 0; i < state->count; ++i) {
        const uint8_t *p = body + i * FPS_CONTACT_SIZE;
        unsigned id = p[0];
        if (!id || id > FPS_MAX_ID || p[1] || p[6] || p[7] || state->contacts[id].down) return false;
        state->contacts[id] = (FPSContact){ true, ((p[2] << 8) | p[3]) / 65535.0, ((p[4] << 8) | p[5]) / 65535.0 };
    }
    return true;
}
static inline FPSContact fps_rotate(FPSContact point, unsigned rotation) {
    double x = point.x, y = point.y;
    switch (rotation) {
        case 1: point.x = y; point.y = 1 - x; break;
        case 2: point.x = 1 - x; point.y = 1 - y; break;
        case 3: point.x = 1 - y; point.y = x; break;
        default: break;
    }
    return point;
}
// UIKit UIInterfaceOrientation, not UIDeviceOrientation. Invalid/unknown
// readings preserve the last usable interface direction.
static inline unsigned fps_interface_rotation(int orientation, unsigned previous) {
    switch (orientation) { case 1: return 0; case 2: return 2; case 3: return 3; case 4: return 1; default: return previous; }
}
#endif
