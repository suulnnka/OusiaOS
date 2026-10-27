/* ZOS libc —— <fcntl.h> */
#ifndef _ZOS_FCNTL_H
#define _ZOS_FCNTL_H

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0x40
#define O_DIRECTORY 0100000
#define O_APPEND 02000

/* open 声明为变参（可带 mode）；实现忽略第三参 */
int open(const char *path, int flags, ...);

#endif
