/* wc —— 从 Unix 移植的字数统计工具（coreutils wc 的精简版）
 *
 * 这就是真实的移植场景：源码与 Unix 版几乎一致，仅依赖
 * <stdio.h>/<ctype.h>/<unistd.h> 的标准子集。
 * 支持: wc [-c|-l|-w] [file...]，缺省打印 行/词/字节。
 */

#include <stdio.h>
#include <ctype.h>
#include <unistd.h>

static int want_lines = 1, want_words = 1, want_bytes = 1;

static void wc_fd(FILE *f, const char *name) {
    unsigned long lines = 0, words = 0, bytes = 0;
    int in_word = 0;
    int c;
    while ((c = fgetc(f)) != EOF) {
        bytes++;
        if (c == '\n')
            lines++;
        if (isspace(c)) {
            in_word = 0;
        } else if (!in_word) {
            in_word = 1;
            words++;
        }
    }
    if (want_lines) printf("%7lu", lines);
    if (want_words) printf("%7lu", words);
    if (want_bytes) printf("%7lu", bytes);
    if (name)
        printf(" %s\n", name);
    else
        printf("\n");
}

int main(int argc, char **argv) {
    int only_one = 0;
    int i = 1;

    for (; i < argc && argv[i][0] == '-' && argv[i][1] != 0; i++) {
        switch (argv[i][1]) {
        case 'c':
            want_lines = want_words = 0;
            want_bytes = 1;
            only_one = 1;
            break;
        case 'l':
            want_words = want_bytes = 0;
            want_lines = 1;
            only_one = 1;
            break;
        case 'w':
            want_lines = want_bytes = 0;
            want_words = 1;
            only_one = 1;
            break;
        default:
            fprintf(stderr, "wc: unknown option %s\n", argv[i]);
            return 1;
        }
        if (argv[i][2] != 0) {
            fprintf(stderr, "wc: combined options unsupported\n");
            return 1;
        }
    }
    (void)only_one;

    if (i >= argc) {
        wc_fd(stdin, 0); /* 从控制台读（Ctrl-D 语义未实现，读到 EOF 为止） */
        return 0;
    }
    for (; i < argc; i++) {
        FILE *f = fopen(argv[i], "r");
        if (f == 0) {
            perror(argv[i]);
            return 1;
        }
        wc_fd(f, argv[i]);
        fclose(f);
    }
    return 0;
}
