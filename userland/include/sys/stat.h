/* ZOS libc —— <sys/stat.h>
 * 字段布局与内核 fstat 写入严格对应（mode@24 size@48 ino@8）。
 */
#ifndef _ZOS_SYS_STAT_H
#define _ZOS_SYS_STAT_H

struct stat {
    unsigned long st_dev;   /* 0 */
    unsigned long st_ino;   /* 8 */
    unsigned long st_nlink; /* 16 */
    unsigned int st_mode;   /* 24 */
    unsigned int st_uid;    /* 28 */
    unsigned int st_gid;    /* 32 */
    unsigned int __pad0;    /* 36 */
    unsigned long st_rdev;  /* 40 */
    long st_size;           /* 48 */
    int st_blksize;         /* 56 */
    int __pad1;
    long st_blocks;         /* 64 */
};

#define S_IFMT  0170000
#define S_IFREG 0100000
#define S_IFDIR 0040000
#define S_IFCHR 0020000
#define S_ISREG(m) (((m) & S_IFMT) == S_IFREG)
#define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
#define S_ISCHR(m) (((m) & S_IFMT) == S_IFCHR)

int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);

#endif
