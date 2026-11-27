// Exercises the installed C ABI, actual worker/clock and wire, with no UI or hardware.
#include "CRustInput.h"
#include <assert.h>
#include <errno.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static atomic_int disposed, failed;
static void notice(void *ctx, int32_t kind, double ms, uint8_t a, uint8_t b, const char *msg) {
    (void)ctx; (void)ms; (void)a; (void)b;
    if (kind == 3) { fprintf(stderr, "Unexpected failure: %s\n", msg); atomic_store(&failed, 1); }
}
static void dispose(void *ctx) { (void)ctx; atomic_fetch_add(&disposed, 1); }
static void read_exact(int s, uint8_t *p, size_t n) {
    while (n) {
        struct pollfd fd = {s, POLLIN, 0};
        assert(poll(&fd, 1, 1500) == 1);
        ssize_t r = read(s, p, n); assert(r > 0); p += r; n -= (size_t)r;
    }
}
static void write_all(int s, const void *data, size_t n) {
    const uint8_t *p = data;
    while (n) { ssize_t r = write(s, p, n); assert(r > 0); p += r; n -= (size_t)r; }
}
// ACK every frame, including interleaved heartbeats, just like the daemon.
static void receive_frame(int s, uint8_t opcode, int id, uint8_t *held_ack) {
    for (unsigned tries = 0; tries < 20; tries++) {
        uint8_t h[8], body[80]; read_exact(s,h,8); assert(h[1] <= 10);
        read_exact(s, body, 8*h[1]);
        uint8_t ack[8] = {128,h[0] == 1 ? h[1] : 0,0,1}; memcpy(ack+4,h+4,4);
        if (held_ack && h[0] != 3) memcpy(held_ack, ack, 8); else write_all(s,ack,8);
        if (h[0] == 3) continue;
        assert(h[0] == opcode && h[1] == (id >= 0));
        if (id >= 0) assert(body[0] == id);
        return;
    }
    assert(0 && "expected frame never arrived");
}
static void expect_frame(int s, uint8_t opcode, int id) { receive_frame(s, opcode, id, NULL); }
int main(void) {
    int s[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, s) == 0);
    uint8_t supported = 0, token[32] = {42}, actual[32]; char error[256] = {0};
    write_all(s[1], "ICFPS014READY001", 16);
    ICFpsLink *h = ic_fps_open(s[0], token, 32, NULL, notice, dispose, &supported, error, sizeof(error));
    assert(h && supported); read_exact(s[1],actual,32); assert(memcmp(token,actual,32)==0);
    ICProfile p = {.aspect=1.5,.look={0.5,0.5},.look_enabled=1,.look_width=0.4,.look_height=0.4,.sensitivity=1,.orientation=255};
    ICButton b[] = {{.trigger=4,.point={0.1,0.2},.preferred=3}, {.trigger=5,.point={0.5,0.5},.preferred=4,.behavior=1}};
    assert(ic_fps_capture(h,&p,b,2,NULL,0)); expect_frame(s[1],1,-1);
    ic_fps_mouse(h,(ICPoint){100,20},0.5); // delivered late by native event loop
    for (int k=0; k<4; k++) { ic_fps_key(h,4,1); ic_fps_key(h,4,0); }
    for (int k=0; k<4; k++) { expect_frame(s[1],1,3); expect_frame(s[1],1,-1); }
    // Even a short ACK stall must not accumulate tick snapshots in the socket.
    uint8_t held[8]; ic_fps_key(h,4,1); receive_frame(s[1],1,3,held);
    for (int k=0; k<1000; k++) ic_fps_mouse(h,(ICPoint){3,0},0.0);
    struct pollfd waiting = {s[1], POLLIN, 0}; assert(poll(&waiting,1,55) == 0);
    write_all(s[1],held,8); ic_fps_key(h,4,0); expect_frame(s[1],1,-1);
    ic_fps_pulse(h,4); expect_frame(s[1],1,4);
    expect_frame(s[1],1,-1); // no further producer call; independent tick expires the tap
    ic_fps_mode(h,1); expect_frame(s[1],4,0);
    ic_fps_pointer_down(h,(ICPoint){0.5,0.5}); ic_fps_pointer_up(h);
    expect_frame(s[1],1,2); expect_frame(s[1],1,-1);
    ic_fps_release(h); assert(ic_fps_capture(h,&p,b,2,NULL,0));
    expect_frame(s[1],2,-1); expect_frame(s[1],1,-1);
    ic_fps_stop(h); ic_fps_destroy(h); // returns before reader/writer teardown
    for (int k=0; k<1500 && !atomic_load(&disposed); k++) usleep(1000);
    assert(atomic_load(&disposed)==1 && atomic_load(&failed)==0); close(s[1]);
    puts("Live Rust input C ABI: ordered edges, stale motion, independent timer, cursor, recapture and disposal OK.");
    return 0;
}
