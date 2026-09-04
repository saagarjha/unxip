#define _GNU_SOURCE
#include <fcntl.h>

#ifdef __BIONIC__
#include <sys/types.h>

// Swift cannot import the variadic openat(); provide a fixed-arity wrapper.
static inline int unxip_openat(int fd, const char *path, int flags, mode_t mode) {
	return openat(fd, path, flags, mode);
}
#endif
