/* probe -- report which filesystem this process is actually looking at.
 *
 * Built static (`gcc -static -o probe probe.c`) so it can be exec'd via
 * execveat() after setns() with nothing bind-mounted into the container: a
 * static binary has no ELF interpreter and no shared libraries to resolve, so
 * the container's libc is never consulted. That is the whole point of rung 2,
 * and it is what lets one binary work against both a glibc and a musl image.
 *
 * Deliberately avoids getpwuid()/getgrgid(): those pull in NSS, which does not
 * work in a static binary.
 */

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void show_ns(void) {
    char buf[128];
    ssize_t n = readlink("/proc/self/ns/mnt", buf, sizeof(buf) - 1);
    if (n < 0) {
        /* Expected inside a container whose /proc is for a different PID
         * namespace than ours -- we entered the mount ns only. */
        printf("mnt-ns:        <unreadable: %s>\n", strerror(errno));
        return;
    }
    buf[n] = '\0';
    printf("mnt-ns:        %s\n", buf);
}

static void show_osrelease(void) {
    FILE *f = fopen("/etc/os-release", "r");
    char line[256];
    if (!f) {
        printf("os-release:    <absent>\n");
        return;
    }
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "ID=", 3) == 0 || strncmp(line, "PRETTY_NAME=", 12) == 0) {
            line[strcspn(line, "\n")] = '\0';
            printf("os-release:    %s\n", line);
        }
    }
    fclose(f);
}

static void list_dir(const char *path, int limit) {
    DIR *d = opendir(path);
    struct dirent *e;
    int n = 0;

    if (!d) {
        printf("%-14s <cannot open: %s>\n", path, strerror(errno));
        return;
    }
    printf("%s:\n  ", path);
    while ((e = readdir(d)) && n < limit) {
        if (e->d_name[0] == '.' && (e->d_name[1] == '\0' ||
            (e->d_name[1] == '.' && e->d_name[2] == '\0')))
            continue;
        printf("%s ", e->d_name);
        n++;
    }
    if (e) printf("...");
    printf("\n");
    closedir(d);
}

static void probe_path(const char *path) {
    struct stat st;
    printf("%-38s %s\n", path, stat(path, &st) == 0 ? "present" : "ABSENT");
}

static void probe_labeled(const char *label, const char *path) {
    struct stat st;
    printf("%-38s %s\n", label,
           (path && stat(path, &st) == 0) ? "present" : "ABSENT");
}

int main(int argc, char **argv) {
    printf("=== probe: static host binary, container filesystem view ===\n");
    printf("argv[0]:       %s\n", argc > 0 ? argv[0] : "(none)");
    printf("uid/euid:      %d/%d   gid/egid: %d/%d\n",
           (int)getuid(), (int)geteuid(), (int)getgid(), (int)getegid());
    printf("pid:           %d   (host PID namespace -- we only entered the mount ns)\n",
           (int)getpid());
    show_ns();
    show_osrelease();
    printf("\n");
    list_dir("/", 40);
    list_dir("/work/repo", 40);
    printf("\n");
    /* Toolchain from the *image*, which a host process cannot otherwise see. */
    probe_path("/usr/local/cargo/bin/cargo");
    probe_path("/usr/local/rustup");
    /* Exists on the host and not in a stock image, so its absence proves we are
     * looking at the container's root rather than the host's. */
    probe_labeled("host $HOME", getenv("HOME"));

    /* `probe --hold N` stays alive holding the container's mount namespace open,
     * so teardown behaviour can be observed. */
    if (argc > 2 && strcmp(argv[1], "--hold") == 0) {
        int secs = atoi(argv[2]);
        printf("holding mount namespace for %ds\n", secs);
        fflush(stdout);
        sleep(secs);
    }
    return 0;
}
