/* iControl passive on-device cursor. SPDX-License-Identifier: GPL-2.0-only */
#ifndef ICONTROL_DEVICE_CURSOR_H
#define ICONTROL_DEVICE_CURSOR_H
#include <stdbool.h>
#include "FPSProtocol.h"

bool fps_cursor_initialize(void);
bool fps_cursor_available(void);
bool fps_cursor_visible(void);
void fps_cursor_update(bool visible, FPSContact point, unsigned rotation);
void fps_cursor_shutdown(void);
void fps_cursor_keepalive(void);
int fps_cursor_renderer_run(int fd);

typedef struct { double x, y; uint8_t visible, rotation, reserved[6]; } FPSCursorMessage;

#endif
