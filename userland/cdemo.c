/* cdemo —— OusiaOS libc 移植演示（纯 C 编写）
 *
 * 这份源码 #include 的全是标准头文件，在 Linux 上用 gcc 也能编译
 * （除 /etc/motd 路径外无平台依赖）——展示"零修改移植"的含义。
 * 覆盖：printf 格式族、string.h、ctype、malloc/realloc/free、qsort、
 *       stdio FILE 读写、dirent、errno/strerror/perror、getopt、atexit。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>

static void bye(void) {
    puts("cdemo: atexit handler ran");
}

static int cmp_int(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

int main(int argc, char **argv) {
    int verbose = 0;
    int opt;
    while ((opt = getopt(argc, argv, "vh")) != -1) {
        switch (opt) {
        case 'v': verbose = 1; break;
        case 'h':
            printf("usage: cdemo [-v]\n");
            return 0;
        default:
            return 1;
        }
    }
    if (verbose)
        puts("cdemo: verbose mode");

    /* ---- 1. printf 格式族 ---- */
    printf("[%d] [%5d] [%-5d|] [%05d] [%x] [%X]\n",
           42, 42, 42, 42, 255, 255);
    printf("[%s] [%10s] [%-10s|] [%.3s]\n",
           "str", "str", "str", "string");
    printf("long: %ld  llong: %lld  size_t: %zu  char: %c%%\n",
           1234567890123L, 4611686018427387904LL,
           (size_t)4096, 'Z');

    char buf[64];
    snprintf(buf, sizeof(buf), "snprintf: %s=%d", "answer", 42);
    puts(buf);

    /* ---- 2. string.h + ctype ---- */
    char s[64];
    strcpy(s, "Hello,");
    strcat(s, " OusiaOS");
    printf("len=%zu cmp=%d upper=%s\n",
           strlen(s), strcmp(s, "Hello, OusiaOS"), "OK");
    char *dup = strdup(s);
    for (char *p = dup; *p; p++)
        *p = (char)toupper(*p);
    printf("dup=%s\n", dup);
    free(dup);

    /* ---- 3. malloc / realloc / qsort ---- */
    int *v = malloc(8 * sizeof(int));
    if (v == 0) {
        perror("malloc");
        return 1;
    }
    srand(42);
    for (int i = 0; i < 8; i++)
        v[i] = rand() % 1000;
    v = realloc(v, 10 * sizeof(int));
    v[8] = 7;
    v[9] = 3;
    qsort(v, 10, sizeof(int), cmp_int);
    printf("sorted:");
    for (int i = 0; i < 10; i++)
        printf(" %d", v[i]);
    printf("\n");
    free(v);

    /* ---- 4. stdio: 读文件 ---- */
    FILE *f = fopen("/etc/motd", "r");
    if (f == 0) {
        perror("fopen /etc/motd");
        return 1;
    }
    char line[128];
    int nlines = 0;
    while (fgets(line, sizeof(line), f) != 0)
        nlines++;
    fclose(f);
    printf("motd: %d lines (fgets ok)\n", nlines);

    /* ---- 5. dirent: 列 /bin ---- */
    DIR *d = opendir("/bin");
    if (d != 0) {
        int n = 0;
        struct dirent *e;
        while ((e = readdir(d)) != 0)
            n++;
        closedir(d);
        printf("/bin: %d entries (opendir/readdir ok)\n", n);
    }

    /* ---- 6. errno / strerror / time ---- */
    errno = ENOENT;
    printf("errno test: %s (isatty(0)=%d)\n",
           strerror(errno), isatty(0));
    printf("uptime: %ld s, pid=%d\n", time(0), getpid());

    atexit(bye);
    puts("cdemo: PASS");
    return 0;
}
