#ifndef ICONTROL_OFFLINE_H
#define ICONTROL_OFFLINE_H
#include "CRustInput.h"

// In-memory only. No transport, worker, clock or retained callbacks. A clone
// is an independent copy, including pending motion, timers and contact leases.
// Do not mutate/destroy a handle concurrently with any access to that handle.
typedef struct ICOffline ICOffline;
ICOffline *ic_offline_create(const ICProfile *, const ICButton *, size_t, const ICLinkKey *, size_t);
ICOffline *ic_offline_clone(const ICOffline *);
void ic_offline_destroy(ICOffline *);
void ic_offline_aspect(ICOffline *, double);
uint8_t ic_offline_pressed(const ICOffline *, uint16_t key); // logical key

// Events use caller-supplied monotonic seconds. The callback is synchronous,
// non-reentrant and receives a borrowed, complete, already-mapped frame.
// No callback = unchanged; a callback with zero contacts = lift all fingers.
typedef void (*ICOfflineFrame)(void *, const ICContact *, size_t);
// Returns 1 for a new physical key-down (not a repeat or a rejected key).
uint8_t ic_offline_key(ICOffline *, uint16_t key, uint8_t down, double now, void *, ICOfflineFrame);
void ic_offline_pulse(ICOffline *, size_t button_index, double now, void *, ICOfflineFrame);
void ic_offline_mode(ICOffline *, uint8_t on, double now, void *, ICOfflineFrame);
void ic_offline_mouse(ICOffline *, ICPoint delta, double now);
void ic_offline_pointer_down(ICOffline *, ICPoint point, double now, void *, ICOfflineFrame);
void ic_offline_pointer_move(ICOffline *, ICPoint point);
void ic_offline_pointer_up(ICOffline *, double now, void *, ICOfflineFrame);
void ic_offline_advance(ICOffline *, double now, void *, ICOfflineFrame);
#endif
