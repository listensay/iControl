/* iControl FPS multi-touch daemon. Copyright (c) 2026 iControl contributors.
 * SPDX-License-Identifier: GPL-2.0-only
 * HID ABI / event conventions: Apple IOKitSPI and TrollVNC STHIDEventGenerator.
 * This independent daemon does not modify or link TrollVNC. */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#ifndef FPSD_SIMULATOR
#import <UIKit/UIKit.h>
#endif
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "FPSProtocol.h"
#include "HIDBridge.h"
#include "DeviceCursor.h"

static volatile sig_atomic_t gRunning = 1;
static int gListener = -1, gOwner = -1, gConnections = 0;
static pthread_mutex_t gOwnerLock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t gToken[32];
static dispatch_group_t gSessions;
static FILE *gEventLog;
static unsigned gRotation;
static pthread_mutex_t gRotationLock = PTHREAD_MUTEX_INITIALIZER;

#ifndef FPSD_SIMULATOR
static FPSCreateHand pHand;
static FPSCreateFinger pFinger;
static FPSSetInteger pInteger;
static FPSSetFloat pFloat;
static FPSAppendEvent pAppend;
static FPSSetSender pSender;
static FPSDispatchEvent pDispatch;
static FPSHIDClientRef gHIDClient;
#endif

static int64_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static void clear_secret(void *data, size_t size) {
    volatile uint8_t *bytes = data;
    while (size--) *bytes++ = 0;
}
static int transfer(int fd, void *buffer, size_t size, bool writing, int64_t deadline) {
    size_t offset = 0;
    while (offset < size && gRunning) {
        int64_t left = deadline - now_ms();
        if (left <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd item = { fd, writing ? POLLOUT : POLLIN, 0 };
        int result = poll(&item, 1, (int)left);
        if (result < 0 && errno == EINTR) continue;
        if (result <= 0) { errno = ETIMEDOUT; return -1; }
        ssize_t count = writing ? send(fd, (uint8_t *)buffer + offset, size - offset, 0)
                                : recv(fd, (uint8_t *)buffer + offset, size - offset, 0);
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) return -1;
        offset += (size_t)count;
    }
    return offset == size ? 0 : -1;
}

static bool load_token(const char *path) {
    struct stat info;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return false;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || (info.st_mode & 0077) || info.st_size != 64) {
        close(fd); return false;
    }
#ifndef FPSD_SIMULATOR
    if (info.st_uid != 0) { close(fd); return false; }
#endif
    char hex[64]; ssize_t count = read(fd, hex, sizeof(hex)); close(fd);
    if (count != 64) return false;
    for (unsigned i = 0; i < 32; ++i) {
        unsigned a = (unsigned char)hex[i * 2], b = (unsigned char)hex[i * 2 + 1];
        if (!((a >= '0' && a <= '9') || (a >= 'a' && a <= 'f')) ||
            !((b >= '0' && b <= '9') || (b >= 'a' && b <= 'f'))) return false;
        gToken[i] = ((a <= '9' ? a - '0' : a - 'a' + 10) << 4) | (b <= '9' ? b - '0' : b - 'a' + 10);
    }
    clear_secret(hex, sizeof(hex)); return true;
}

static unsigned current_rotation(void) {
    pthread_mutex_lock(&gRotationLock); unsigned value = gRotation; pthread_mutex_unlock(&gRotationLock); return value;
}
static void set_orientation(NSInteger orientation) {
    // UIInterfaceOrientation swaps the device's landscape enum values:
    // LandscapeLeft=4 and LandscapeRight=3. Using UIDeviceOrientation's
    // numbering reverses both landscape touch axes.
    if (orientation < 1 || orientation > 4) return;
    unsigned rotation = fps_interface_rotation((int)orientation, current_rotation());
    pthread_mutex_lock(&gRotationLock); gRotation = rotation; pthread_mutex_unlock(&gRotationLock);
    fprintf(stderr, "FPS interface orientation=%ld rotation=%u\n", (long)orientation, rotation * 90);
}

@protocol FPSOrientationReporting
- (NSInteger)activeInterfaceOrientation;
- (NSInteger)orientation;
- (void)setHandler:(void (^)(id))handler;
@end
static id gOrientationObserver;
static NSTimer *gOrientationTimer;
static void observe_orientation(void) {
#ifndef FPSD_SIMULATOR
    if (!dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW)) {
        fprintf(stderr, "FrontBoardServices unavailable: %s\n", dlerror()); return;
    }
    Class cls = NSClassFromString(@"FBSOrientationObserver");
    id<FPSOrientationReporting> observer = (id)[[cls alloc] init];
    if (observer && [(id)observer respondsToSelector:@selector(setHandler:)] &&
        [(id)observer respondsToSelector:@selector(activeInterfaceOrientation)]) {
        [observer setHandler:^(id update) {
            if ([update respondsToSelector:@selector(orientation)]) set_orientation([(id<FPSOrientationReporting>)update orientation]);
        }];
        set_orientation([observer activeInterfaceOrientation]); gOrientationObserver = observer;
        // Some iPadOS releases deliver the initial callback before the handler
        // is installed. Refresh the value on the main run loop as well.
        gOrientationTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            NSInteger value = [observer activeInterfaceOrientation];
            unsigned rotation = fps_interface_rotation((int)value, current_rotation());
            if (value >= 1 && value <= 4 && rotation != current_rotation()) set_orientation(value);
        }];
    } else { fprintf(stderr, "Automatic orientation unavailable; select a touch orientation in iControl.\n"); }
#endif
}

static bool initialize_hid(void) {
#ifdef FPSD_SIMULATOR
    return true;
#else
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!library) return false;
    pHand = (FPSCreateHand)dlsym(library, "IOHIDEventCreateDigitizerEvent");
    pFinger = (FPSCreateFinger)dlsym(library, "IOHIDEventCreateDigitizerFingerEvent");
    pInteger = (FPSSetInteger)dlsym(library, "IOHIDEventSetIntegerValue");
    pFloat = (FPSSetFloat)dlsym(library, "IOHIDEventSetFloatValue");
    pAppend = (FPSAppendEvent)dlsym(library, "IOHIDEventAppendEvent");
    pSender = (FPSSetSender)dlsym(library, "IOHIDEventSetSenderID");
    pDispatch = (FPSDispatchEvent)dlsym(library, "IOHIDEventSystemClientDispatchEvent");
    FPSCreateClient create = (FPSCreateClient)dlsym(library, "IOHIDEventSystemClientCreate");
    if (!pHand || !pFinger || !pInteger || !pFloat || !pAppend || !pSender || !pDispatch || !create) return false;
    gHIDClient = create(kCFAllocatorDefault); return gHIDClient != NULL;
#endif
}

static bool dispatch_state(FPSState *previous, const FPSState *display, unsigned rotation, bool canceled, uint32_t seq) {
    (void)seq;
    FPSState next = *display; next.orientation = rotation;
    uint32_t mask = 0, masks[FPS_MAX_ID + 1] = {0};
    bool changed = false;
    for (unsigned id = 1; id <= FPS_MAX_ID; ++id) {
        next.contacts[id] = fps_rotate(next.contacts[id], rotation);
        FPSContact old = previous->contacts[id], point = next.contacts[id];
        if (old.down != point.down) { masks[id] = FPS_RANGE | FPS_TOUCH | FPS_IDENTITY; changed = true; }
        else if (point.down && (old.x != point.x || old.y != point.y)) { masks[id] = FPS_POSITION | FPS_ATTRIBUTE; changed = true; }
        if (old.down && !point.down && canceled) masks[id] |= FPS_CANCEL;
        mask |= masks[id];
    }
    if (!changed) return true;
#ifdef FPSD_SIMULATOR
    (void)mask;
    if (gEventLog) {
        fprintf(gEventLog, "frame seq=%u active=%u rotation=%u canceled=%u ids=", seq, next.count, rotation, canceled);
        for (unsigned id = 1; id <= FPS_MAX_ID; ++id) if (next.contacts[id].down) fprintf(gEventLog, "%u,", id);
        fprintf(gEventLog, " edges=");
        for (unsigned id = 1; id <= FPS_MAX_ID; ++id) if (masks[id]) {
            FPSContact point = next.contacts[id].down ? next.contacts[id] : previous->contacts[id];
            fprintf(gEventLog, "%u:%s:%.5f:%.5f,", id,
                    !point.down || !next.contacts[id].down ? "up" : !previous->contacts[id].down ? "down" : "move", point.x, point.y);
        }
        fprintf(gEventLog, "\n"); fflush(gEventLog);
    }
#else
    uint64_t stamp = mach_absolute_time();
    FPSHIDEventRef hand = pHand(kCFAllocatorDefault, stamp, 3, 0, 0, mask, 0, 0, 0, 0, 0, 0, false, next.count != 0, 0);
    if (!hand) return false;
    pInteger(hand, FPS_BUILT_IN, 1); pInteger(hand, FPS_DISPLAY_INTEGRATED, 1);
    for (unsigned id = 1; id <= FPS_MAX_ID; ++id) {
        if (!previous->contacts[id].down && !next.contacts[id].down) continue;
        FPSContact point = next.contacts[id].down ? next.contacts[id] : previous->contacts[id];
        bool down = next.contacts[id].down;
        FPSHIDEventRef finger = pFinger(kCFAllocatorDefault, stamp, id, id, masks[id], point.x, point.y, 0, 0, 90, down, down, 0);
        if (!finger) { CFRelease(hand); return false; }
        pFloat(finger, FPS_MAJOR_RADIUS, down ? 5 : 0); pFloat(finger, FPS_MINOR_RADIUS, down ? 5 : 0);
        pAppend(hand, finger, 0); CFRelease(finger);
    }
    pSender(hand, UINT64_C(0x8000000817319372));
    pDispatch(gHIDClient, hand); CFRelease(hand);
#endif
    *previous = next; return true;
}

static void release_contacts(FPSState *previous, uint32_t seq) {
    FPSState empty = {0}; dispatch_state(previous, &empty, 0, true, seq);
}

static void update_cursor(bool visible, FPSContact point, unsigned rotation, uint32_t seq) {
    fps_cursor_update(visible, point, rotation);
#ifdef FPSD_SIMULATOR
    if (gEventLog) {
        FPSContact physical = fps_rotate(point, rotation);
        fprintf(gEventLog, "cursor seq=%u visible=%u x=%.5f y=%.5f rotation=%u\n", seq,
                fps_cursor_visible(), physical.x, physical.y, rotation);
        fflush(gEventLog);
    }
#else
    (void)seq;
#endif
}

static void handle_client(int fd) {
    @autoreleasepool {
        FPSState previous = {0}; bool owner = false; uint32_t last = 0; bool has_sequence = false;
        char greeting[] = "ICFPS014";
        if (transfer(fd, greeting, 8, true, now_ms() + 500)) goto done;
        uint8_t secret[32];
        if (transfer(fd, secret, sizeof(secret), false, now_ms() + 1500)) goto done;
        unsigned difference = 0;
        for (unsigned i = 0; i < sizeof(secret); ++i) difference |= secret[i] ^ gToken[i];
        clear_secret(secret, sizeof(secret));
        if (difference) { char denied[] = "DENY0001"; transfer(fd, denied, 8, true, now_ms() + 100); goto done; }
        pthread_mutex_lock(&gOwnerLock);
        if (gOwner < 0) { gOwner = fd; owner = true; }
        pthread_mutex_unlock(&gOwnerLock);
        if (!owner) { char busy[] = "BUSY0001"; transfer(fd, busy, 8, true, now_ms() + 100); goto done; }
        char ready[] = "READY001";
        if (transfer(fd, ready, 8, true, now_ms() + 100)) goto done;
        fprintf(stderr, "FPS session connected.\n");
        while (gRunning) {
            int64_t deadline = now_ms() + FPS_WATCHDOG_MS;
            uint8_t header[FPS_HEADER_SIZE], body[FPS_MAX_CONTACTS * FPS_CONTACT_SIZE];
            if (transfer(fd, header, sizeof(header), false, deadline)) break;
            if (!fps_header_valid(header)) break;
            if (transfer(fd, body, header[1] * FPS_CONTACT_SIZE, false, deadline)) break;
            uint32_t seq = fps_u32(header + 4);
            if (has_sequence && (int32_t)(seq - last) <= 0) break;
            has_sequence = true; last = seq;
            unsigned rotation = header[2] == 255 ? current_rotation() : header[2];
            if (header[0] == 4) {
                FPSContact point;
                if (!fps_cursor_decode(header, body, &point)) break;
                update_cursor(header[1] == 1, point, rotation, seq);
            } else {
                FPSState state;
                if (!fps_decode(header, body, &state)) break;
                if (header[0] == 1) {
                    if (previous.count && previous.orientation != rotation) release_contacts(&previous, seq);
                    if (!dispatch_state(&previous, &state, rotation, false, seq)) break;
                } else if (header[0] == 2) {
                    release_contacts(&previous, seq); update_cursor(false, (FPSContact){0}, 0, seq);
                }
            }
            fps_cursor_keepalive();
            uint8_t flags = (fps_cursor_available() ? 1 : 0) | (fps_cursor_visible() ? 2 : 0);
            uint8_t ack[8] = {128, previous.count, rotation, flags}; fps_put_u32(ack + 4, seq);
            if (transfer(fd, ack, sizeof(ack), true, now_ms() + 100)) break;
        }
    done:
        if (owner) {
            release_contacts(&previous, last);
            update_cursor(false, (FPSContact){0}, 0, last);
            pthread_mutex_lock(&gOwnerLock); if (gOwner == fd) gOwner = -1; pthread_mutex_unlock(&gOwnerLock);
            fprintf(stderr, "FPS session ended; all contacts released.\n");
        }
        shutdown(fd, SHUT_RDWR); close(fd);
        pthread_mutex_lock(&gOwnerLock); --gConnections; pthread_mutex_unlock(&gOwnerLock);
    }
}

static void stop_signal(int signal_number) { (void)signal_number; gRunning = 0; }
static void accept_clients(void) {
    while (gRunning) {
        struct pollfd item = {gListener, POLLIN, 0};
        if (poll(&item, 1, 100) <= 0) continue;
        int fd = accept(gListener, NULL, NULL); if (fd < 0) continue;
        int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); fcntl(fd, F_SETFD, FD_CLOEXEC);
        pthread_mutex_lock(&gOwnerLock);
        bool admit = gConnections < 8; if (admit) ++gConnections;
        pthread_mutex_unlock(&gOwnerLock);
        if (!admit) { close(fd); continue; }
        dispatch_group_async(gSessions, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ handle_client(fd); });
    }
    close(gListener);
    dispatch_group_wait(gSessions, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    CFRunLoopStop(CFRunLoopGetMain());
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--cursor-renderer-fd") && !strcmp(argv[2], "3")) {
            int yes = 1; setsockopt(3, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            return fps_cursor_renderer_run(3);
        }
        const char *token_path = NULL, *log_path = NULL; unsigned port = 5902;
        for (int i = 1; i < argc; ++i) {
            if (!strcmp(argv[i], "--version")) { puts("icontrol-fpsd 1.4.0 protocol=1 cursor=1 contacts=10 watchdog=350ms"); return 0; }
            if (!strcmp(argv[i], "--token-file") && i + 1 < argc) token_path = argv[++i];
#ifdef FPSD_SIMULATOR
            else if (!strcmp(argv[i], "--event-log") && i + 1 < argc) log_path = argv[++i];
            else if (!strcmp(argv[i], "--interface-orientation") && i + 1 < argc) {
                int value = atoi(argv[++i]); if (value < 1 || value > 4) return 2; set_orientation(value);
            }
            else if (!strcmp(argv[i], "--port") && i + 1 < argc) {
                char *end; unsigned long value = strtoul(argv[++i], &end, 10);
                if (*end || value > 65535) return 2; port = (unsigned)value;
            }
#endif
            else { fputs("Unsupported argument.\n", stderr); return 2; }
        }
        if (!token_path || !load_token(token_path)) { fputs("A private 64-byte token file is required.\n", stderr); return 3; }
#ifndef FPSD_SIMULATOR
        if (getuid() != 0) { fputs("FPS HID input requires the jailbreak root account.\n", stderr); return 4; }
#endif
        if (!initialize_hid()) { fputs("The iPad HID event interface is unavailable.\n", stderr); return 5; }
        // Cursor availability is reported independently; failed window hosting
        // must not disable the user's already-working WASD/touch channel.
        fps_cursor_initialize();
#ifdef FPSD_SIMULATOR
        if (log_path) { gEventLog = fopen(log_path, "w"); if (!gEventLog) return 6; }
#endif
        gListener = socket(AF_INET, SOCK_STREAM, 0); if (gListener < 0) return 7;
        fcntl(gListener, F_SETFD, FD_CLOEXEC);
        int yes = 1; setsockopt(gListener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
                                     .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (bind(gListener, (struct sockaddr *)&address, sizeof(address)) || listen(gListener, 8)) {
            fputs("The local FPS port is unavailable.\n", stderr); close(gListener); return 8;
        }
        socklen_t size = sizeof(address); getsockname(gListener, (struct sockaddr *)&address, &size);
        printf("FPS_READY port=%u protocol=1\n", ntohs(address.sin_port)); fflush(stdout);
        signal(SIGTERM, stop_signal); signal(SIGINT, stop_signal); signal(SIGHUP, stop_signal); signal(SIGPIPE, SIG_IGN);
        gSessions = dispatch_group_create(); observe_orientation();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ accept_clients(); });
        CFRunLoopRun();
        fps_cursor_shutdown();
        if (gEventLog) fclose(gEventLog);
#ifndef FPSD_SIMULATOR
        if (gHIDClient) CFRelease(gHIDClient);
#endif
        clear_secret(gToken, sizeof(gToken)); return 0;
    }
}
