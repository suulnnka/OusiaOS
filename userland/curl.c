/* curl —— 极简 HTTP 客户端（移植演示：标准 C，经 ZOS 扩展系统调用）
 *
 * 用法: curl http://HOST[:PORT]/PATH
 *   HOST 可以是 IP 或域名（内核侧做 DNS）
 *   默认端口 80，默认路径 /
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>

long zos_http_get(const char *host, int port, const char *path,
                  char *buf, unsigned long len);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: curl http://host[:port]/path\n");
        return 1;
    }
    const char *url = argv[1];
    if (strncmp(url, "http://", 7) == 0)
        url += 7;

    char host[128] = {0};
    int port = 80;
    const char *path = "/";

    const char *colon = strchr(url, ':');
    const char *slash = strchr(url, '/');
    if (colon != 0 && (slash == 0 || colon < slash)) {
        size_t hlen = (size_t)(colon - url);
        if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
        memcpy(host, url, hlen);
        port = atoi(colon + 1);
        if (port <= 0) port = 80;
        if (slash != 0)
            path = slash;
    } else if (slash != 0) {
        size_t hlen = (size_t)(slash - url);
        if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
        memcpy(host, url, hlen);
        path = slash;
    } else {
        strncpy(host, url, sizeof(host) - 1);
    }

    printf("* fetching http://%s:%d%s ...\n", host, port, path);

    static char buf[48 * 1024];
    long r = zos_http_get(host, port, path, buf, sizeof(buf));
    if (r < 0) {
        errno = (int)-r;
        perror("curl");
        return 1;
    }

    /* 打印响应（跳过 HTTP 头） */
    long len = r;
    const char *body = buf;
    const char *sep = strstr(buf, "\r\n\r\n");
    if (sep != 0) {
        /* 顺手打印状态行 */
        const char *eol = strstr(buf, "\r\n");
        if (eol != 0)
            printf("%.*s\n", (int)(eol - buf), buf);
        body = sep + 4;
        len = r - (long)(body - buf);
    }
    fwrite(body, 1, (size_t)len, stdout);
    printf("\n* %ld bytes body\n", len);
    return 0;
}
