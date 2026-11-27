#ifndef ICONTROL_RUST_INPUT_H
#define ICONTROL_RUST_INPUT_H
#include <stddef.h>
#include <stdint.h>

// All profile and frame arrays are borrowed only for the duration of the call.
typedef struct ICFpsLink ICFpsLink;
typedef struct { double x, y; } ICPoint;
typedef struct { ICPoint point, end; double duration; uint16_t trigger; uint8_t behavior, preferred; } ICButton;
typedef struct { uint16_t source, target; } ICLinkKey;
typedef struct { ICPoint point; uint8_t id; } ICContact;
typedef struct {
    ICPoint joystick, look, offset;
    double aspect, radius, turn_duration, look_width, look_height, sensitivity;
    uint8_t joystick_enabled, smooth, look_enabled, swap_axes, invert_x, invert_y, mapping, orientation;
} ICProfile;

typedef void (*ICNotice)(void *, int32_t, double, uint8_t, uint8_t, const char *);
typedef void (*ICDispose)(void *);
// Consumes the transferred fd AND retained callback context on success or error.
// Synchronous handshake: call off-main. Notice 1=ack, 2=cursor flags, 3=failure.
ICFpsLink *ic_fps_open(int32_t fd, const uint8_t *secret, size_t count, void *context,
                       ICNotice notice, ICDispose dispose, uint8_t *supports_cursor, char *error, size_t capacity);
int32_t ic_fps_capture(ICFpsLink *, const ICProfile *, const ICButton *, size_t, const ICLinkKey *, size_t);
void ic_fps_key(ICFpsLink *, uint16_t key, uint8_t down);
void ic_fps_pulse(ICFpsLink *, uint8_t preferred_id);
void ic_fps_mode(ICFpsLink *, uint8_t on);
void ic_fps_aspect(ICFpsLink *, double value);
void ic_fps_mouse(ICFpsLink *, ICPoint delta, double event_age_seconds);
void ic_fps_pointer_move(ICFpsLink *, ICPoint point, double event_age_seconds);
void ic_fps_pointer_down(ICFpsLink *, ICPoint point);
void ic_fps_pointer_up(ICFpsLink *);
void ic_fps_pointer_hide(ICFpsLink *);
void ic_fps_state(ICFpsLink *, uint8_t orientation, const ICContact *, size_t); // explicit layout previews
void ic_fps_cursor(ICFpsLink *, uint8_t orientation, const ICPoint *); // already mapped; NULL hides
void ic_fps_release(ICFpsLink *); // cancel pending capture work; retain the USB session
void ic_fps_stop(ICFpsLink *); // asynchronous, idempotent
void ic_fps_destroy(ICFpsLink *); // once, after last producer; no blocking join
#include "ICOffline.h"
#endif
