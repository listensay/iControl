#ifndef ICONTROL_TRANSPORT_H
#define ICONTROL_TRANSPORT_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// Negative descriptors indicate errors. Timed accept returns -2 on timeout.
int ic_connect_unix(const char *path, int timeout_ms);
int ic_connect_loopback(uint16_t port, int timeout_ms);
int ic_listen_loopback(uint16_t port);
int ic_listen_unix(const char *path);
uint16_t ic_bound_port(int fd);
int ic_accept_timeout(int fd, int timeout_ms);
int ic_read_exact(int fd, void *data, size_t length, int timeout_ms);
// Read up to length bytes: 0 = EOF, -2 = timeout, -1 = error.
ssize_t ic_read_some(int fd, void *data, size_t length, int timeout_ms);
int ic_write_all(int fd, const void *data, size_t length, int timeout_ms);
void ic_shutdown_socket(int fd);
void ic_shutdown_write(int fd);
void ic_close_socket(int fd);
int ic_relay(int left, int right, uint64_t *left_to_right, uint64_t *right_to_left);

#endif
