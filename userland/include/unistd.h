/* ZOS libc —— <unistd.h> */
#ifndef _ZOS_UNISTD_H
#define _ZOS_UNISTD_H

#include <stddef.h>

typedef long ssize_t;
typedef unsigned int uid_t;
typedef unsigned int pid_t;

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);
long lseek(int fd, long off, int whence);
int dup(int fd);
int isatty(int fd);

pid_t getpid(void);
pid_t fork(void);
int execve(const char *path, char *const argv[], char *const envp[]);
int waitpid(pid_t pid, int *status, int options);

unsigned sleep(unsigned seconds);
int usleep(unsigned usec);

int chdir(const char *path);
char *getcwd(char *buf, size_t size);

/* getopt（POSIX）*/
extern char *optarg;
extern int optind;
extern int opterr;
extern int optopt;
int getopt(int argc, char *const argv[], const char *optstring);

#endif
