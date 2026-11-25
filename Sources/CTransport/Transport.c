#include "CTransport.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <time.h>

static int64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    return 0;
}

static int wait_fd(int fd, short events, int64_t deadline) {
    for (;;) {
        int64_t remaining = deadline - now_ms();
        if (remaining <= 0) { errno = ETIMEDOUT; return -1; }
        struct pollfd p = { .fd = fd, .events = events };
        int result = poll(&p, 1, (int)remaining);
        if (result < 0 && errno == EINTR) continue;
        if (result == 0) { errno = ETIMEDOUT; return -1; }
        if (result < 0) return -1;
        if (p.revents & POLLNVAL) { errno = EBADF; return -1; }
        // Let recv/send report EOF or the actual socket error.
        if (p.revents & (events | POLLERR | POLLHUP)) return 0;
    }
}

static int connect_address(int fd, const struct sockaddr *address, socklen_t size, int timeout) {
    if (nonblocking(fd) < 0) return -1;
    if (connect(fd, address, size) == 0) return 0;
    if (errno != EINPROGRESS) return -1;
    if (wait_fd(fd, POLLOUT, now_ms() + timeout) < 0) return -1;
    int error = 0;
    socklen_t length = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) return -1;
    if (error) { errno = error; return -1; }
    return 0;
}

int ic_connect_unix(const char *path, int timeout_ms) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    if (!path || strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect_address(fd, (struct sockaddr *)&addr, sizeof(addr), timeout_ms) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

int ic_connect_loopback(uint16_t port, int timeout_ms) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect_address(fd, (struct sockaddr *)&addr, sizeof(addr), timeout_ms) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

int ic_listen_loopback(uint16_t port) {
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (nonblocking(fd) < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

int ic_listen_unix(const char *path) {
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    if (!path || strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (nonblocking(fd) < 0 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        chmod(path, 0600) < 0 || listen(fd, 4) < 0) {
        int saved = errno; close(fd); errno = saved; return -1;
    }
    return fd;
}

uint16_t ic_bound_port(int fd) {
    struct sockaddr_in addr;
    socklen_t length = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &length) < 0) return 0;
    return ntohs(addr.sin_port);
}

int ic_accept_timeout(int fd, int timeout_ms) {
    if (wait_fd(fd, POLLIN, now_ms() + timeout_ms) < 0) return errno == ETIMEDOUT ? -2 : -1;
    int accepted;
    do { accepted = accept(fd, NULL, NULL); } while (accepted < 0 && errno == EINTR);
    if (accepted >= 0 && nonblocking(accepted) < 0) {
        int saved = errno; close(accepted); errno = saved; return -1;
    }
    if (accepted < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return -2;
    return accepted;
}

int ic_read_exact(int fd, void *data, size_t length, int timeout_ms) {
    size_t offset = 0;
    int64_t deadline = now_ms() + timeout_ms;
    while (offset < length) {
        if (wait_fd(fd, POLLIN, deadline) < 0) return -1;
        ssize_t result = recv(fd, (char *)data + offset, length - offset, 0);
        if (result > 0) offset += (size_t)result;
        else if (result == 0) { errno = ECONNRESET; return -1; }
        else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
    }
    return 0;
}

int ic_write_all(int fd, const void *data, size_t length, int timeout_ms) {
    size_t offset = 0;
    int64_t deadline = now_ms() + timeout_ms;
    while (offset < length) {
        if (wait_fd(fd, POLLOUT, deadline) < 0) return -1;
        ssize_t result = send(fd, (const char *)data + offset, length - offset, 0);
        if (result > 0) offset += (size_t)result;
        else if (result == 0) { errno = EPIPE; return -1; }
        else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
    }
    return 0;
}

ssize_t ic_read_some(int fd, void *data, size_t length, int timeout_ms) {
    if (!data || !length) { errno = EINVAL; return -1; }
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        if (wait_fd(fd, POLLIN, deadline) < 0) return errno == ETIMEDOUT ? -2 : -1;
        ssize_t result = recv(fd, data, length, 0);
        if (result >= 0) return result;
        if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) return -1;
    }
}

void ic_shutdown_socket(int fd) { if (fd >= 0) shutdown(fd, SHUT_RDWR); }
void ic_shutdown_write(int fd) { if (fd >= 0) shutdown(fd, SHUT_WR); }
void ic_close_socket(int fd) { if (fd >= 0) close(fd); }

typedef struct {
    unsigned char bytes[65536];
    size_t offset;
    size_t size;
    int eof;
    int write_closed;
} relay_buffer;

static int fill(int fd, relay_buffer *buffer) {
    if (buffer->size != 0 || buffer->eof) return 0;
    ssize_t count = recv(fd, buffer->bytes, sizeof(buffer->bytes), 0);
    if (count > 0) { buffer->offset = 0; buffer->size = (size_t)count; return 0; }
    if (count == 0) { buffer->eof = 1; return 0; }
    return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1;
}

static int drain(int fd, relay_buffer *buffer, uint64_t *counter) {
    if (buffer->size == 0) return 0;
    ssize_t count = send(fd, buffer->bytes + buffer->offset, buffer->size, 0);
    if (count > 0) {
        buffer->offset += (size_t)count;
        buffer->size -= (size_t)count;
        *counter += (uint64_t)count;
        return 0;
    }
    return (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) ? 0 : -1;
}

int ic_relay(int left, int right, uint64_t *left_to_right, uint64_t *right_to_left) {
    relay_buffer lr = {0}, rl = {0};
    uint64_t lr_count = 0, rl_count = 0;
    int outcome = 0;
    for (;;) {
        if (lr.eof && lr.size == 0 && !lr.write_closed) {
            shutdown(right, SHUT_WR); lr.write_closed = 1;
        }
        if (rl.eof && rl.size == 0 && !rl.write_closed) {
            shutdown(left, SHUT_WR); rl.write_closed = 1;
        }
        if (lr.write_closed && rl.write_closed) break;
        struct pollfd p[2] = {
            { .fd = left, .events = 0 }, { .fd = right, .events = 0 }
        };
        if (!lr.eof && lr.size == 0) p[0].events |= POLLIN;
        if (rl.size > 0) p[0].events |= POLLOUT;
        if (!rl.eof && rl.size == 0) p[1].events |= POLLIN;
        if (lr.size > 0) p[1].events |= POLLOUT;
        // Ignore a completed half of the stream until there is data to write.
        if (!p[0].events) p[0].fd = -1;
        if (!p[1].events) p[1].fd = -1;
        int result = poll(p, 2, 1000);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { outcome = -1; break; }
        if (result == 0) continue;
        if ((p[0].revents | p[1].revents) & (POLLERR | POLLNVAL)) { outcome = -1; break; }
        if ((p[0].revents & (POLLIN | POLLHUP)) && fill(left, &lr) < 0) { outcome = -1; break; }
        if ((p[1].revents & (POLLIN | POLLHUP)) && fill(right, &rl) < 0) { outcome = -1; break; }
        if ((p[0].revents & (POLLOUT | POLLHUP)) && drain(left, &rl, &rl_count) < 0) { outcome = -1; break; }
        if ((p[1].revents & (POLLOUT | POLLHUP)) && drain(right, &lr, &lr_count) < 0) { outcome = -1; break; }
    }
    if (left_to_right) *left_to_right = lr_count;
    if (right_to_left) *right_to_left = rl_count;
    return outcome;
}
