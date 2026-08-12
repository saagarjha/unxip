#define _GNU_SOURCE
#include <sys/types.h>
#include <fcntl.h>

// Swift cannot import the variadic openat(); provide a fixed-arity wrapper.
static inline int unxip_openat(int fd, const char *path, int flags, mode_t mode) {
	return openat(fd, path, flags, mode);
}
