/* iControl isolated cursor renderer IPC. SPDX-License-Identifier: GPL-2.0-only */
#include "DeviceCursor.h"
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
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>
extern char **environ;

static int gRendererSocket = -1;
static pid_t gRendererPID;
static atomic_bool gAvailable, gVisible;
static FPSCursorMessage gLastCursor;
static int64_t gLastUpdate;
static pthread_mutex_t gRendererLock = PTHREAD_MUTEX_INITIALIZER;
static int64_t renderer_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void renderer_stop(void) {
    if (gRendererSocket >= 0) { shutdown(gRendererSocket, SHUT_RDWR); close(gRendererSocket); gRendererSocket = -1; }
    if (gRendererPID > 0) { kill(gRendererPID, SIGTERM); waitpid(gRendererPID, NULL, WNOHANG); gRendererPID = 0; }
    atomic_store(&gAvailable, false); atomic_store(&gVisible, false);
}
static bool renderer_read_flags(int timeout) {
    struct pollfd item = {gRendererSocket, POLLIN, 0};
    uint8_t flags;
    if (poll(&item, 1, timeout) <= 0 || recv(gRendererSocket, &flags, 1, 0) != 1 || flags > 3 || flags == 2) return false;
    atomic_store(&gAvailable, flags & 1); atomic_store(&gVisible, flags & 2); return true;
}
bool fps_cursor_initialize(void) {
    char executable[PATH_MAX]; uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return false;
    int sockets[2]; if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return false;
    // Put the child's channel at 3 without inheriting the parent's other side.
    int childSocket = fcntl(sockets[1], F_DUPFD_CLOEXEC, 10);
    close(sockets[1]);
    if (childSocket < 0) { close(sockets[0]); return false; }
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, sockets[0]);
    posix_spawn_file_actions_adddup2(&actions, childSocket, 3);
    posix_spawn_file_actions_addclose(&actions, childSocket);
    char *argv[] = {executable, "--cursor-renderer-fd", "3", NULL};
    int result = posix_spawn(&gRendererPID, executable, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions); close(childSocket);
    if (result) { close(sockets[0]); gRendererPID = 0; return false; }
    gRendererSocket = sockets[0];
    int yes = 1; setsockopt(gRendererSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(gRendererSocket, F_SETFD, FD_CLOEXEC);
    fcntl(gRendererSocket, F_SETFL, fcntl(gRendererSocket, F_GETFL) | O_NONBLOCK);
    if (!renderer_read_flags(2000) || !fps_cursor_available()) { renderer_stop(); return false; }
    gLastUpdate = renderer_ms(); return true;
}
static void renderer_send(void) {
    if (gRendererSocket < 0) return;
    // Bound a broken UI renderer so it cannot stall the touch daemon's owner.
    if (send(gRendererSocket, &gLastCursor, sizeof(gLastCursor), 0) != sizeof(gLastCursor)
        || !renderer_read_flags(100)) { renderer_stop(); return; }
    gLastUpdate = renderer_ms();
}
void fps_cursor_update(bool visible, FPSContact point, unsigned rotation) {
    pthread_mutex_lock(&gRendererLock);
    gLastCursor = (FPSCursorMessage){.x = point.x, .y = point.y, .visible = visible, .rotation = rotation};
    renderer_send(); pthread_mutex_unlock(&gRendererLock);
}
void fps_cursor_keepalive(void) {
    pthread_mutex_lock(&gRendererLock);
    if (gRendererSocket >= 0 && renderer_ms() - gLastUpdate >= 100) renderer_send();
    pthread_mutex_unlock(&gRendererLock);
}
void fps_cursor_shutdown(void) {
    pthread_mutex_lock(&gRendererLock); renderer_stop(); pthread_mutex_unlock(&gRendererLock);
}
bool fps_cursor_available(void) { return atomic_load(&gAvailable); }
bool fps_cursor_visible(void) { return atomic_load(&gVisible); }
