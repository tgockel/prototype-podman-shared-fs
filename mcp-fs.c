/* mcp-fs -- a deliberately tiny read-only filesystem MCP server over stdio.
 *
 *   mcp-fs [--root DIR]
 *
 * Exists so this repo can demonstrate a real MCP handshake end to end without
 * depending on any particular MCP implementation. It speaks just enough of the
 * protocol to be driven by a client: initialize, tools/list, and tools/call for
 * two tools, list_files and read_file.
 *
 * Built static (`gcc -static`) because that is the interesting case: the launcher
 * can open it on one filesystem and exec it on another, so nothing -- not the
 * loader, not libc -- is resolved through the container it ends up looking at.
 *
 * The JSON parsing is minimal on purpose: it scans for the keys it needs rather
 * than building a document tree. That is fine for a prototype driven by a known
 * client and is NOT suitable for anything else.
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_READ (64 * 1024)

static char root_dir[PATH_MAX] = "/";

/* ---------------------------------------------------------------- JSON in --- */

/* Value of "key" as a string. Handles \" and \\ only -- see the header comment. */
static int json_str(const char *json, const char *key, char *out, size_t n) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ' || *p == ':') p++;
    if (*p != '"') return 0;
    p++;
    size_t i = 0;
    while (*p && *p != '"' && i + 1 < n) {
        if (*p == '\\' && p[1]) {
            p++;
            out[i++] = (*p == 'n') ? '\n' : (*p == 't') ? '\t' : *p;
        } else {
            out[i++] = *p;
        }
        p++;
    }
    out[i] = '\0';
    return 1;
}

/* Value of "key" as a number, for the request id. */
static int json_int(const char *json, const char *key, long *out) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\"", key);
    const char *p = strstr(json, pat);
    if (!p) return 0;
    p += strlen(pat);
    while (*p == ' ' || *p == ':') p++;
    if (*p < '0' || *p > '9') return 0;
    *out = strtol(p, NULL, 10);
    return 1;
}

/* --------------------------------------------------------------- JSON out --- */

static void emit_escaped(const char *s, size_t len) {
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"':  fputs("\\\"", stdout); break;
            case '\\': fputs("\\\\", stdout); break;
            case '\n': fputs("\\n", stdout);  break;
            case '\r': fputs("\\r", stdout);  break;
            case '\t': fputs("\\t", stdout);  break;
            default:
                if (c < 0x20) printf("\\u%04x", c);
                else putchar(c);
        }
    }
}

static void reply_open(long id) { printf("{\"jsonrpc\":\"2.0\",\"id\":%ld,\"result\":", id); }
static void reply_close(void)   { printf("}\n"); fflush(stdout); }

/* A tools/call result: one text content block. */
static void reply_text(long id, const char *text, size_t len) {
    reply_open(id);
    printf("{\"content\":[{\"type\":\"text\",\"text\":\"");
    emit_escaped(text, len);
    printf("\"}]}");
    reply_close();
}

static void reply_error(long id, const char *msg) {
    printf("{\"jsonrpc\":\"2.0\",\"id\":%ld,\"error\":{\"code\":-32000,\"message\":\"", id);
    emit_escaped(msg, strlen(msg));
    printf("\"}}\n");
    fflush(stdout);
}

/* ------------------------------------------------------------------ tools --- */

/* Join `rel` onto the root and refuse anything that escapes it. */
static int resolve(const char *rel, char *out) {
    char joined[PATH_MAX * 2];   /* room for root + '/' + rel before realpath */
    if (rel[0] == '/')
        snprintf(joined, sizeof joined, "%s", rel);
    else
        snprintf(joined, sizeof joined, "%s/%s", root_dir, rel);

    if (!realpath(joined, out)) return 0;
    size_t rl = strlen(root_dir);
    if (strcmp(root_dir, "/") == 0) return 1;
    return strncmp(out, root_dir, rl) == 0 && (out[rl] == '\0' || out[rl] == '/');
}

static void tool_list_files(long id, const char *path) {
    char full[PATH_MAX];
    if (!resolve(path[0] ? path : root_dir, full)) { reply_error(id, "path outside root"); return; }

    DIR *d = opendir(full);
    if (!d) { reply_error(id, strerror(errno)); return; }

    char buf[MAX_READ];
    size_t n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char sub[PATH_MAX * 2];
        struct stat st;
        snprintf(sub, sizeof sub, "%s/%s", full, e->d_name);
        const char *kind = (stat(sub, &st) == 0 && S_ISDIR(st.st_mode)) ? "[DIR] " : "[FILE] ";
        int w = snprintf(buf + n, sizeof buf - n, "%s%s\n", kind, e->d_name);
        if (w < 0 || (size_t)w >= sizeof buf - n) break;
        n += (size_t)w;
    }
    closedir(d);
    reply_text(id, buf, n);
}

static void tool_read_file(long id, const char *path) {
    char full[PATH_MAX];
    if (!resolve(path, full)) { reply_error(id, "path outside root"); return; }

    FILE *f = fopen(full, "rb");
    if (!f) { reply_error(id, strerror(errno)); return; }
    static char buf[MAX_READ];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    reply_text(id, buf, n);
}

/* ------------------------------------------------------------------- main --- */

static void handle(char *line) {
    char method[64] = "";
    long id = 0;
    int has_id = json_int(line, "id", &id);

    if (!json_str(line, "method", method, sizeof method)) return;
    if (!strncmp(method, "notifications/", 14)) return;   /* no reply expected */
    if (!has_id) return;

    if (!strcmp(method, "initialize")) {
        reply_open(id);
        printf("{\"protocolVersion\":\"2024-11-05\","
               "\"capabilities\":{\"tools\":{}},"
               "\"serverInfo\":{\"name\":\"mcp-fs\",\"version\":\"0.1.0\"}}");
        reply_close();
    } else if (!strcmp(method, "tools/list")) {
        reply_open(id);
        printf("{\"tools\":["
               "{\"name\":\"list_files\",\"description\":\"List a directory.\","
               "\"inputSchema\":{\"type\":\"object\",\"properties\":"
               "{\"path\":{\"type\":\"string\"}}}},"
               "{\"name\":\"read_file\",\"description\":\"Read a file (64 KiB max).\","
               "\"inputSchema\":{\"type\":\"object\",\"properties\":"
               "{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}"
               "]}");
        reply_close();
    } else if (!strcmp(method, "tools/call")) {
        char name[64] = "", path[PATH_MAX] = "";
        json_str(line, "name", name, sizeof name);
        json_str(line, "path", path, sizeof path);
        if (!strcmp(name, "list_files"))      tool_list_files(id, path);
        else if (!strcmp(name, "read_file"))  tool_read_file(id, path);
        else                                  reply_error(id, "no such tool");
    } else {
        reply_error(id, "method not supported by this minimal server");
    }
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--root") && i + 1 < argc) {
            if (!realpath(argv[++i], root_dir)) {
                fprintf(stderr, "mcp-fs: --root %s: %s\n", argv[i], strerror(errno));
                return 1;
            }
        }
    }
    fprintf(stderr, "mcp-fs: serving %s over stdio\n", root_dir);

    char *line = NULL;
    size_t cap = 0;
    while (getline(&line, &cap, stdin) > 0) handle(line);
    free(line);
    return 0;
}
