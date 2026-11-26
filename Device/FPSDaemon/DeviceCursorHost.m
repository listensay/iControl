/* iControl isolated cursor renderer IPC. SPDX-License-Identifier: GPL-2.0-only */
#include "DeviceCursor.h"
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>
extern char **environ;

static int gRendererSocket = -1;
static pid_t gRendererPID;
static atomic_uchar gFlags;
static enum { Idle, Starting, AwaitingUpdate } gPending;
static FPSCursorMessage gDesired;
static bool gDirty;
static int64_t gSentAt, gRetryAt;
static int gBackoff = 500;
static pthread_mutex_t gRendererLock = PTHREAD_MUTEX_INITIALIZER;
static int64_t renderer_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void renderer_stop(void) {
    if (gRendererSocket >= 0) { close(gRendererSocket); gRendererSocket = -1; }
    if (gRendererPID > 0) {
        pid_t child = gRendererPID; gRendererPID = 0;
        kill(child, SIGKILL);
        // Reap this child even if it was stopped, without blocking touch input.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (waitpid(child, NULL, 0) < 0 && errno == EINTR) { }
        });
    }
    gPending = Idle; atomic_store(&gFlags, 0);
}
static void renderer_failed(const char *reason) {
    renderer_stop(); gDirty = true;
    fprintf(stderr, "FPS cursor renderer %s; retry on demand in %d ms\n", reason, gBackoff);
    gRetryAt = renderer_ms() + gBackoff;
    if (gBackoff < 8000) gBackoff *= 2;
}
static bool renderer_spawn(void) {
    char executable[PATH_MAX]; uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return false;
    int sockets[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return false;
    int childSocket = fcntl(sockets[1], F_DUPFD_CLOEXEC, 10);
    close(sockets[1]);
    if (childSocket < 0) { close(sockets[0]); return false; }
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, sockets[0]);
    posix_spawn_file_actions_adddup2(&actions, childSocket, 3);
    posix_spawn_file_actions_addclose(&actions, childSocket);
    char *argv[] = {executable, "--cursor-renderer-fd", "3", NULL};
    pid_t child = 0;
    int result = posix_spawn(&child, executable, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions); close(childSocket);
    if (result) { close(sockets[0]); return false; }
    gRendererPID = child; gRendererSocket = sockets[0];
    int yes = 1; setsockopt(gRendererSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(gRendererSocket, F_SETFD, FD_CLOEXEC);
    fcntl(gRendererSocket, F_SETFL, fcntl(gRendererSocket, F_GETFL) | O_NONBLOCK);
    gPending = Starting; gSentAt = renderer_ms(); gDirty = true;
    return true;
}
// One response per message. A late reply remains attached to that message;
// a heartbeat can finish it without replaying stale pointer positions.
static void renderer_receive(int waitMS) {
    if (gPending == Idle) return;
    struct pollfd item = {gRendererSocket, POLLIN, 0};
    int result = poll(&item, 1, waitMS);
    if (result < 0 && errno == EINTR) return;
    if (result == 0) {
        if (renderer_ms() - gSentAt >= (gPending == Starting ? 5000 : 1200)) renderer_failed("timed out");
        return;
    }
    uint8_t flags;
    if (result < 0 || recv(gRendererSocket, &flags, 1, 0) != 1 || (flags != 1 && flags != 3)) {
        renderer_failed("unavailable"); return;
    }
    if (gPending == AwaitingUpdate) gBackoff = 500;
    atomic_store(&gFlags, flags); gPending = Idle;
}
static void renderer_service(int waitMS) {
    if (gRendererSocket < 0) {
        if (!gDesired.visible || renderer_ms() < gRetryAt) return;
        if (!renderer_spawn()) { renderer_failed("could not start"); return; }
    }
    renderer_receive(0);
    if (gRendererSocket < 0 || gPending != Idle) return;
    if (!gDirty && (!gDesired.visible || renderer_ms() - gSentAt < 100)) return;
    if (send(gRendererSocket, &gDesired, sizeof(gDesired), 0) != sizeof(gDesired)) {
        renderer_failed("lost connection"); return;
    }
    gSentAt = renderer_ms(); gPending = AwaitingUpdate; gDirty = false;
    renderer_receive(waitMS);
}
bool fps_cursor_initialize(void) {
    // The initial probe runs before accepting input. In-session retries never
    // wait for UIKit startup; the touch owner's 350 ms watchdog stays active.
    if (!renderer_spawn()) { renderer_failed("could not start"); return false; }
    renderer_receive(2000);
    return fps_cursor_available();
}
void fps_cursor_update(bool visible, FPSContact point, unsigned rotation) {
    pthread_mutex_lock(&gRendererLock);
    gDesired = (FPSCursorMessage){.x = point.x, .y = point.y, .visible = visible, .rotation = rotation};
    gDirty = true; renderer_service(5); pthread_mutex_unlock(&gRendererLock);
}
void fps_cursor_keepalive(void) {
    pthread_mutex_lock(&gRendererLock); renderer_service(0); pthread_mutex_unlock(&gRendererLock);
}
void fps_cursor_shutdown(void) {
    pthread_mutex_lock(&gRendererLock); renderer_stop(); pthread_mutex_unlock(&gRendererLock);
}
bool fps_cursor_available(void) { return (atomic_load(&gFlags) & 1) != 0; }
bool fps_cursor_visible(void) { return (atomic_load(&gFlags) & 2) != 0; }
