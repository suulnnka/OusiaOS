/* ZOS libc —— <stdio.h>
 * FILE 为薄封装（fd + eof/err 标志），无用户态缓冲。
 * printf 族由 clib.c 以 C va_list 实现。
 */
#ifndef _ZOS_STDIO_H
#define _ZOS_STDIO_H

#include <stddef.h>

typedef struct _zos_file {
    int fd;
    int eof;
    int err;
} FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF (-1)
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#define BUFSIZ 1024
#define FILENAME_MAX 256
#define TMP_MAX 0 /* 未实现 tmpfile */

int printf(const char *fmt, ...);
int vprintf(const char *fmt, __builtin_va_list ap);
int fprintf(FILE *f, const char *fmt, ...);
int vfprintf(FILE *f, const char *fmt, __builtin_va_list ap);
int dprintf(int fd, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int snprintf(char *buf, size_t cap, const char *fmt, ...);
int vsnprintf(char *buf, size_t cap, const char *fmt, __builtin_va_list ap);

int puts(const char *s);
int putchar(int c);
int fputs(const char *s, FILE *f);
int fputc(int c, FILE *f);
int putc(int c, FILE *f);
int getchar(void);
int getc(FILE *f);
int fgetc(FILE *f);
char *fgets(char *buf, int size, FILE *f);

size_t fread(void *ptr, size_t size, size_t nmemb, FILE *f);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *f);

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
int fflush(FILE *f);
int feof(FILE *f);
int ferror(FILE *f);
int fseek(FILE *f, long off, int whence);
long ftell(FILE *f);
void perror(const char *s);

#endif
