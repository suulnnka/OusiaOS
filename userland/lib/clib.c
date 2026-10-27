/* clib.c —— ZOS libc 的 C 部分
 *
 * printf 全家族（用真正的 C va_list 实现，教学重点：可变参数的原理）
 * 与 getopt（移植 Unix 命令行程序的基础设施）。
 *
 * 输出统一走"Sink"抽象：fd 直写（printf/fprintf/dprintf）或
 * 写入缓冲区（sprintf/snprintf），格式引擎只有一份。
 */

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>   /* userland/include —— FILE/printf 声明 */
#include <unistd.h>  /* write */

/* ================= 格式化引擎 ================= */

typedef struct {
    char *buf;      /* 缓冲区模式 */
    size_t cap;     /* 缓冲区容量（含 NUL） */
    size_t len;     /* 已产出长度（含被截断部分） */
    int fd;         /* fd 模式 */
    int to_buf;
    char iobuf[128]; /* fd 模式的输出缓冲 */
    size_t iolen;
} Sink;

static void sink_flush(Sink *s) {
    if (!s->to_buf && s->iolen > 0) {
        write(s->fd, s->iobuf, s->iolen);
        s->iolen = 0;
    }
}

static void sink_ch(Sink *s, char c) {
    if (s->to_buf) {
        if (s->buf != 0 && s->len + 1 < s->cap)
            s->buf[s->len] = c;
    } else {
        if (s->iolen == sizeof(s->iobuf))
            sink_flush(s);
        s->iobuf[s->iolen++] = c;
    }
    s->len++;
}

static void sink_str(Sink *s, const char *p, size_t n) {
    for (size_t i = 0; i < n; i++) sink_ch(s, p[i]);
}

/* 数字渲染：支持 2..16 进制、负号、宽度、零填充/左对齐 */
static void fmt_num(Sink *s, unsigned long long v, int base, int upper,
                    int width, char pad, int left, int neg) {
    char tmp[72];
    int n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0) tmp[n++] = '0';
    while (v != 0) {
        tmp[n++] = digits[v % (unsigned)base];
        v /= (unsigned)base;
    }
    int total = n + (neg ? 1 : 0);
    if (!left)
        for (int i = total; i < width; i++) sink_ch(s, pad);
    if (neg) sink_ch(s, '-');
    for (int i = n - 1; i >= 0; i--) sink_ch(s, tmp[i]);
    if (left)
        for (int i = total; i < width; i++) sink_ch(s, ' ');
}

static void fmt_str(Sink *s, const char *p, int width, int prec, int left) {
    size_t n = 0;
    if (p == 0) p = "(null)";
    while (p[n] != 0 && (prec < 0 || (int)n < prec)) n++;
    if (!left)
        for (size_t i = n; i < (size_t)(width > 0 ? width : 0); i++) sink_ch(s, ' ');
    sink_str(s, p, n);
    if (left)
        for (size_t i = n; i < (size_t)(width > 0 ? width : 0); i++) sink_ch(s, ' ');
}

int zvformat(Sink *s, const char *fmt, va_list ap) {
    for (size_t i = 0; fmt[i] != 0; i++) {
        if (fmt[i] != '%') {
            sink_ch(s, fmt[i]);
            continue;
        }
        i++;
        if (fmt[i] == '%') {
            sink_ch(s, '%');
            continue;
        }
        /* flags */
        int left = 0, plus = 0, space = 0;
        char pad = ' ';
        while (fmt[i] == '-' || fmt[i] == '0' || fmt[i] == '+' || fmt[i] == ' ') {
            if (fmt[i] == '-') left = 1;
            if (fmt[i] == '0') pad = '0';
            if (fmt[i] == '+') plus = 1;
            if (fmt[i] == ' ') space = 1;
            i++;
        }
        /* width */
        int width = 0;
        if (fmt[i] == '*') {
            width = va_arg(ap, int);
            if (width < 0) {
                left = 1;
                width = -width;
            }
            i++;
        } else {
            while (fmt[i] >= '0' && fmt[i] <= '9') width = width * 10 + (fmt[i++] - '0');
        }
        /* precision */
        int prec = -1;
        if (fmt[i] == '.') {
            i++;
            prec = 0;
            if (fmt[i] == '*') {
                prec = va_arg(ap, int);
                i++;
            } else {
                while (fmt[i] >= '0' && fmt[i] <= '9') prec = prec * 10 + (fmt[i++] - '0');
            }
        }
        /* length modifier */
        int lmod = 0; /* 0=int 1=long 2=long long 3=size_t/ptrdiff 4=short 5=char */
        while (fmt[i] == 'l' || fmt[i] == 'h' || fmt[i] == 'z' || fmt[i] == 'j' || fmt[i] == 't') {
            if (fmt[i] == 'l') lmod = (lmod == 1) ? 2 : 1;
            else if (fmt[i] == 'h') lmod = (lmod == 4) ? 5 : 4;
            else lmod = 3;
            i++;
        }

        char conv = fmt[i];
        switch (conv) {
        case 'd':
        case 'i': {
            long long v;
            if (lmod == 2 || lmod == 3) v = va_arg(ap, long long);
            else if (lmod == 1) v = va_arg(ap, long);
            else v = va_arg(ap, int);
            if (lmod == 4) v = (short)v;
            if (lmod == 5) v = (signed char)v;
            int neg = v < 0;
            unsigned long long u = neg ? -(unsigned long long)v : (unsigned long long)v;
            if (neg) sink_ch(s, '-');
            else if (plus) sink_ch(s, '+');
            else if (space) sink_ch(s, ' ');
            fmt_num(s, u, 10, 0, width - (neg || plus || space), pad, left, 0);
            break;
        }
        case 'u':
        case 'o':
        case 'x':
        case 'X': {
            int base = (conv == 'u') ? 10 : (conv == 'o') ? 8 : 16;
            unsigned long long v;
            if (lmod == 2 || lmod == 3) v = va_arg(ap, unsigned long long);
            else if (lmod == 1) v = va_arg(ap, unsigned long);
            else v = va_arg(ap, unsigned int);
            if (lmod == 4) v = (unsigned short)v;
            if (lmod == 5) v = (unsigned char)v;
            fmt_num(s, v, base, conv == 'X', width, pad, left, 0);
            break;
        }
        case 'c': {
            char c = (char)va_arg(ap, int);
            if (!left && width > 1)
                for (int k = 1; k < width; k++) sink_ch(s, ' ');
            sink_ch(s, c);
            if (left && width > 1)
                for (int k = 1; k < width; k++) sink_ch(s, ' ');
            break;
        }
        case 's': {
            const char *p = va_arg(ap, const char *);
            fmt_str(s, p, width, prec, left);
            break;
        }
        case 'p': {
            void *p = va_arg(ap, void *);
            sink_str(s, "0x", 2);
            fmt_num(s, (unsigned long long)(size_t)p, 16, 0, 0, ' ', 0, 0);
            break;
        }
        default:
            /* 未知转换：原样输出 %x */
            sink_ch(s, '%');
            if (fmt[i] != 0) sink_ch(s, fmt[i]);
            break;
        }
        if (fmt[i] == 0) break;
    }
    sink_flush(s);
    if (s->to_buf && s->buf != 0 && s->cap > 0) {
        size_t n = s->len < s->cap - 1 ? s->len : s->cap - 1;
        s->buf[n] = 0;
    }
    return (int)s->len;
}

/* ================= printf 家族 ================= */

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    Sink s = {0, 0, 0, 1, 0, {0}, 0};
    int r = zvformat(&s, fmt, ap);
    va_end(ap);
    return r;
}

int vprintf(const char *fmt, va_list ap) {
    Sink s = {0, 0, 0, 1, 0, {0}, 0};
    return zvformat(&s, fmt, ap);
}

int fprintf(FILE *f, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int fd = f ? f->fd : 2;
    Sink s = {0, 0, 0, fd, 0, {0}, 0};
    int r = zvformat(&s, fmt, ap);
    va_end(ap);
    return r;
}

int vfprintf(FILE *f, const char *fmt, va_list ap) {
    int fd = f ? f->fd : 2;
    Sink s = {0, 0, 0, fd, 0, {0}, 0};
    return zvformat(&s, fmt, ap);
}

int dprintf(int fd, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    Sink s = {0, 0, 0, fd, 0, {0}, 0};
    int r = zvformat(&s, fmt, ap);
    va_end(ap);
    return r;
}

int sprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    Sink s = {buf, (size_t)-1, 0, 0, 1, {0}, 0}; /* cap=-1: 不截断 */
    int r = zvformat(&s, fmt, ap);
    va_end(ap);
    return r;
}

int snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    Sink s = {buf, cap, 0, 0, 1, {0}, 0};
    int r = zvformat(&s, fmt, ap);
    va_end(ap);
    return r;
}

int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap) {
    Sink s = {buf, cap, 0, 0, 1, {0}, 0};
    return zvformat(&s, fmt, ap);
}

/* ================= getopt ================= */

char *optarg = 0;
int optind = 1;
int opterr = 1;
int optopt = 0;
static int nextchar = 1;

int getopt(int argc, char *const argv[], const char *optstring) {
    if (optind >= argc || argv[optind] == 0)
        return -1;
    const char *arg = argv[optind];
    if (arg[0] != '-' || arg[1] == 0)
        return -1; /* 非选项或单个 "-" */
    if (arg[1] == '-' && arg[2] == 0) {
        optind++; /* "--" 结束选项 */
        return -1;
    }
    char c = arg[nextchar];
    if (c == 0) {
        optind++;
        nextchar = 1;
        return -1;
    }
    const char *p = optstring;
    while (*p != 0 && *p != c) p++;
    optopt = (unsigned char)c;
    if (*p == 0) {
        if (opterr)
            printf("%s: invalid option -- '%c'\n", argv[0], c);
        nextchar++;
        if (arg[nextchar] == 0) {
            optind++;
            nextchar = 1;
        }
        return '?';
    }
    if (p[1] == ':') { /* 需要参数 */
        if (arg[nextchar + 1] != 0) {
            optarg = (char *)(arg + nextchar + 1);
        } else if (optind + 1 < argc) {
            optarg = argv[optind + 1];
            optind++;
        } else {
            if (opterr)
                printf("%s: option requires an argument -- '%c'\n", argv[0], c);
            optind++;
            nextchar = 1;
            return (optstring[0] == ':') ? ':' : '?';
        }
        optind++;
        nextchar = 1;
        return c;
    }
    /* 无参选项 */
    nextchar++;
    if (arg[nextchar] == 0) {
        optind++;
        nextchar = 1;
    }
    return c;
}
