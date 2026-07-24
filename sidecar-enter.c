/* sidecar-enter -- run a program from THIS container's image with ANOTHER
 * container's filesystem view.
 *
 *   sidecar-enter [--target PID | --ns-file PATH] [--graft DIR] [--cwd DIR]
 *                 -- PROGRAM [ARGS...]
 *
 * This is enterfs.py's logic relocated into a sidecar. The sidecar's own rootfs
 * plays exactly the role the host root played there: it supplies the runtime
 * (node, python, whatever the MCP image ships), while the target container
 * supplies the files.
 *
 * Written in C and linked static (`gcc -static`) so it runs unchanged inside any
 * MCP image regardless of that image's libc -- the same reasoning that made the
 * static rung work against Alpine from a glibc host.
 *
 * Expected to be launched with:
 *     --userns=container:<target>   so we are in the user namespace that OWNS the
 *                                 target mount namespace (this is what makes
 *                                 setns permissible; no userns setns needed)
 *     --pid=container:<target>      so the target is visible as PID 1
 *                                 (or use --ns-file with a bind-mounted nsfs file)
 *     --cap-add=SYS_ADMIN         the default seccomp profile gates setns on it
 */

#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef OPEN_TREE_CLONE
#define OPEN_TREE_CLONE 1
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#ifndef MOVE_MOUNT_F_EMPTY_PATH
#define MOVE_MOUNT_F_EMPTY_PATH 0x04
#endif
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

extern char **environ;

/* Directories the loader should search, relative to the graft point. Derived by
 * `ldd` in enterfs.py; hardcoded here because a static C helper has no business
 * shelling out. Covers Debian/Ubuntu multiarch, official node images
 * (/usr/local/lib) and Alpine. */
static const char *LIB_DIRS[] = {
    "/usr/local/lib", "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu",
    "/lib64", "/usr/lib64", "/lib", "/usr/lib", NULL,
};

static void die(const char *what) {
    fprintf(stderr, "sidecar-enter: %s: %s\n", what, strerror(errno));
    exit(1);
}

static int open_tree_(int dfd, const char *path, unsigned flags) {
    return (int)syscall(SYS_open_tree, dfd, path, flags);
}

static int move_mount_(int ffd, const char *fpath, int tfd, const char *tpath,
                       unsigned flags) {
    return (int)syscall(SYS_move_mount, ffd, fpath, tfd, tpath, flags);
}

/* PT_INTERP of an ELF64 file, or NULL when statically linked. Returns a pointer
 * into a static buffer. */
static char *elf_interp(const char *path) {
    static char interp[256];
    Elf64_Ehdr eh;
    Elf64_Phdr ph;
    FILE *f = fopen(path, "rb");
    if (!f) die(path);
    if (fread(&eh, sizeof eh, 1, f) != 1 || memcmp(eh.e_ident, ELFMAG, SELFMAG)) {
        fprintf(stderr, "sidecar-enter: %s is not an ELF64 binary "
                        "(shebang scripts are not supported -- name the interpreter)\n", path);
        exit(1);
    }
    for (int i = 0; i < eh.e_phnum; i++) {
        if (fseek(f, eh.e_phoff + (long)i * eh.e_phentsize, SEEK_SET) != 0) break;
        if (fread(&ph, sizeof ph, 1, f) != 1) break;
        if (ph.p_type != PT_INTERP) continue;
        if (ph.p_filesz >= sizeof interp) break;
        if (fseek(f, ph.p_offset, SEEK_SET) != 0) break;
        if (fread(interp, ph.p_filesz, 1, f) != 1) break;
        interp[ph.p_filesz] = '\0';
        fclose(f);
        return interp;
    }
    fclose(f);
    return NULL;
}

int main(int argc, char **argv) {
    const char *ns_file = NULL, *graft = "/mnt", *cwd = "/";
    long target = 1; /* PID 1 under --pid=container: is the target's init */
    int i = 1;

    for (; i < argc; i++) {
        if (!strcmp(argv[i], "--target") && i + 1 < argc)        target = atol(argv[++i]);
        else if (!strcmp(argv[i], "--ns-file") && i + 1 < argc)  ns_file = argv[++i];
        else if (!strcmp(argv[i], "--graft") && i + 1 < argc)    graft = argv[++i];
        else if (!strcmp(argv[i], "--cwd") && i + 1 < argc)      cwd = argv[++i];
        else if (!strcmp(argv[i], "--")) { i++; break; }
        else break;
    }
    if (i >= argc) {
        fprintf(stderr, "usage: sidecar-enter [--target PID | --ns-file PATH] "
                        "[--graft DIR] [--cwd DIR] -- PROGRAM [ARGS...]\n");
        return 2;
    }

    char **prog_argv = &argv[i];
    const char *program = prog_argv[0];
    char *interp = elf_interp(program);

    /* Everything needing the sidecar's own filesystem happens before setns. */
    int prog_fd = open(program, O_RDONLY);
    if (prog_fd < 0) die(program);

    int tree_fd = -1;
    if (interp) {
        tree_fd = open_tree_(AT_FDCWD, "/", OPEN_TREE_CLONE | AT_RECURSIVE);
        if (tree_fd < 0) die("open_tree(/) -- need CAP_SYS_ADMIN in this user namespace");
    }

    char nsbuf[64];
    if (!ns_file) {
        snprintf(nsbuf, sizeof nsbuf, "/proc/%ld/ns/mnt", target);
        ns_file = nsbuf;
    }
    int ns_fd = open(ns_file, O_RDONLY);
    if (ns_fd < 0) die(ns_file);
    if (setns(ns_fd, CLONE_NEWNS) < 0)
        die("setns(CLONE_NEWNS) -- need --cap-add=SYS_ADMIN and --userns=container:<target>");
    close(ns_fd);
    /* From here the sidecar's own filesystem is gone, reachable only via the fds
     * opened above. */

    if (interp) {
        /* Private copy first, so the graft is invisible to the target container. */
        if (unshare(CLONE_NEWNS) < 0) die("unshare(CLONE_NEWNS)");
        if (mount(NULL, "/", NULL, MS_REC | MS_SLAVE, NULL) < 0) die("mount(MS_REC|MS_SLAVE)");
        if (move_mount_(tree_fd, "", AT_FDCWD, graft, MOVE_MOUNT_F_EMPTY_PATH) < 0) {
            fprintf(stderr, "sidecar-enter: move_mount -> %s: %s "
                            "(does %s exist in the target image?)\n",
                    graft, strerror(errno), graft);
            return 1;
        }
        close(tree_fd);
    }

    if (chdir(cwd) < 0) die(cwd);

    if (!interp) {
        /* Static: run straight from the fd. Nothing resolves through the target
         * container, so its libc is irrelevant. */
        syscall(SYS_execveat, prog_fd, "", prog_argv, environ, AT_EMPTY_PATH);
        die("execveat");
    }

    /* Dynamic: run through the sidecar's own loader, now under the graft point. */
    char loader[512], libpath[4096], progpath[512];
    snprintf(loader, sizeof loader, "%s%s", graft, interp);
    snprintf(progpath, sizeof progpath, "%s%s", graft, program);
    libpath[0] = '\0';
    for (int d = 0; LIB_DIRS[d]; d++) {
        strncat(libpath, graft, sizeof libpath - strlen(libpath) - 1);
        strncat(libpath, LIB_DIRS[d], sizeof libpath - strlen(libpath) - 1);
        if (LIB_DIRS[d + 1]) strncat(libpath, ":", sizeof libpath - strlen(libpath) - 1);
    }

    /* musl's loader understands --library-path but not glibc's --inhibit-cache,
     * and MCP images are very often Alpine-based. */
    int musl = strstr(interp, "ld-musl") != NULL;

    int extra = 5; /* loader [--inhibit-cache] --library-path PATH progpath */
    int nargs = 0;
    while (prog_argv[nargs]) nargs++;
    char **launch = calloc(nargs + extra + 1, sizeof *launch);
    if (!launch) die("calloc");
    int n = 0;
    launch[n++] = loader;
    if (!musl) launch[n++] = (char *)"--inhibit-cache";
    launch[n++] = (char *)"--library-path";
    launch[n++] = libpath;
    launch[n++] = progpath;
    for (int a = 1; a < nargs; a++) launch[n++] = prog_argv[a];
    launch[n] = NULL;

    execv(loader, launch);
    die(loader);
    return 1;
}
