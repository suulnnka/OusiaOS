/* OusiaOS libc —— <stdlib.h> */
#ifndef _OusiaOS_STDLIB_H
#define _OusiaOS_STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7FFFFFFF

void *malloc(size_t n);
void *calloc(size_t n, size_t size);
void *realloc(void *old, size_t n);
void free(void *p);

int atoi(const char *s);
long atol(const char *s);
int abs(int x);
long labs(long x);

void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));

int rand(void);
void srand(unsigned seed);

void exit(int code) __attribute__((noreturn));
void _exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int atexit(void (*fn)(void));

char *getenv(const char *name);
extern char **environ;

#endif
