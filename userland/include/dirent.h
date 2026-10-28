/* OusiaOS libc —— <dirent.h>
 * d_reclen 内含变长名；DIR 内嵌缓冲，readdir 返回内部槽位。
 */
#ifndef _OusiaOS_DIRENT_H
#define _OusiaOS_DIRENT_H

#define DT_DIR 4
#define DT_REG 8
#define DT_CHR 2

struct dirent {
    unsigned long d_ino;
    long d_off;
    unsigned short d_reclen;
    unsigned char d_type;
    char d_name[256];
};

typedef struct {
    int fd;
    unsigned char buf[4096];
    unsigned long len;
    unsigned long pos;
    struct dirent ent;
} DIR;

DIR *opendir(const char *path);
struct dirent *readdir(DIR *d);
int closedir(DIR *d);

#endif
