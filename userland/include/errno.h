/* ZOS libc —— <errno.h> */
#ifndef _ZOS_ERRNO_H
#define _ZOS_ERRNO_H

int *__errno_location(void);
#define errno (*__errno_location())

#define EPERM 1
#define ENOENT 2
#define EBADF 9
#define ECHILD 10
#define EAGAIN 11
#define ENOMEM 12
#define EACCES 13
#define EFAULT 14
#define ENOTDIR 20
#define EISDIR 21
#define EINVAL 22
#define ENOTTY 25
#define ESPIPE 29
#define EROFS 30
#define ENOSYS 38

char *strerror(int e);

#endif
