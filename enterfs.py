#!/usr/bin/env python3
"""Run a HOST program with a Podman container's filesystem view.

The program stays an ordinary host process -- host network, host PID namespace,
host lifetime, reaped by whoever spawned it -- but every path it opens resolves
inside the container. Nothing is bind-mounted into the container and the image
needs no cooperation whatsoever.

    ./enterfs.py -c podman-shared-fs-demo -- ./probe
    ./enterfs.py -c podman-shared-fs-demo -- /usr/bin/node -e 'console.log(1)'

Two rungs, chosen automatically by reading the binary's ELF PT_INTERP header:

  static (no PT_INTERP)
      open() the binary on the host, setns() into the container's mount
      namespace, then fexecve it (os.execve accepts an fd). The already-open fd
      survives the namespace switch, so the binary runs even though its path no
      longer exists. Nothing is resolved through the container -- no interpreter,
      no libraries -- so the image's libc is irrelevant.

  dynamic (has PT_INTERP)
      A dynamically-linked binary still needs its loader and its libraries, and
      after setns() those are gone. So before switching, open_tree(OPEN_TREE_CLONE
      | AT_RECURSIVE) snapshots the host root; after switching we unshare(CLONE_NEWNS)
      to get a private copy of the container's tree (so the container never sees
      this) and move_mount() the host snapshot in at --host-prefix. The program is
      then launched through the host loader with an explicit --library-path.

Namespace entry happens IN-PROCESS -- no `podman unshare` wrapper. That matters:
`podman unshare` forks, so the caller would get podman's pid rather than the
program's, and an orchestrator holding that pid could not reliably wait() on or
kill the real process. Doing it in-process keeps the program a direct child.

It works because the kernel grants capabilities over a user namespace whose owner
uid matches the caller's euid, so the same user that created the container can
setns into the rootless user namespace unaided. The ordering is forced: the user
namespace must be joined FIRST, or the mount-namespace setns fails EPERM.

We join the ROOTLESS user namespace (the pause process's), not the container's.
That is deliberate: it keeps unshare() and move_mount() within a single user
namespace -- cross-user-namespace mount attachment is the fragile part -- while
still granting full access, because there we are uid 0 with CAP_DAC_OVERRIDE over
the whole mapped range. Under --userns=keep-id there is a happy coincidence:
rootless-userns uid 0 IS container uid 1000, so files land with exactly the
ownership the container's own processes expect, with no chown dance.
"""

import argparse
import ctypes
import json
import os
import subprocess
import sys

# --- syscall plumbing -------------------------------------------------------

AT_FDCWD = -100
AT_RECURSIVE = 0x8000
OPEN_TREE_CLONE = 0x01
MOVE_MOUNT_F_EMPTY_PATH = 0x04
MS_BIND = 0x1000
MS_REC = 0x4000
MS_SLAVE = 1 << 19

NR_OPEN_TREE = 428
NR_MOVE_MOUNT = 429

_libc = ctypes.CDLL(None, use_errno=True)
_libc.syscall.restype = ctypes.c_long
_libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                        ctypes.c_ulong, ctypes.c_void_p]
_libc.mount.restype = ctypes.c_int


def _syscall(nr, *args):
    ctypes.set_errno(0)
    res = _libc.syscall(ctypes.c_long(nr), *args)
    if res < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return res


def open_tree(dirfd, path, flags):
    """Detach a copy of a mount subtree into an fd, unmoored from any namespace."""
    return _syscall(NR_OPEN_TREE, ctypes.c_int(dirfd),
                    ctypes.c_char_p(path), ctypes.c_uint(flags))


def move_mount(from_fd, from_path, to_fd, to_path, flags):
    return _syscall(NR_MOVE_MOUNT, ctypes.c_int(from_fd), ctypes.c_char_p(from_path),
                    ctypes.c_int(to_fd), ctypes.c_char_p(to_path), ctypes.c_uint(flags))


def make_rslave(path=b"/"):
    if _libc.mount(None, path, None, ctypes.c_ulong(MS_REC | MS_SLAVE), None) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"mount(MS_REC|MS_SLAVE, {path!r}): {os.strerror(err)}")


def bind_over(source, target):
    """Bind `source` onto `target`, shadowing whatever the container had there.

    Only ever called inside our private mount namespace, so the container's own
    processes never see it.
    """
    if _libc.mount(source, target, None, ctypes.c_ulong(MS_BIND | MS_REC), None) != 0:
        err = ctypes.get_errno()
        raise OSError(err, f"bind {source!r} -> {target!r}: {os.strerror(err)}")


# --- ELF sniffing -----------------------------------------------------------

def elf_interp(path):
    """Return the PT_INTERP string, or None for a static binary.

    Raises SystemExit for anything that is not an ELF64 object, since a shebang
    script's interpreter line would resolve inside the container and quietly mean
    something different from what the caller asked for.
    """
    with open(path, "rb") as f:
        hdr = f.read(64)
        if len(hdr) < 64 or hdr[:4] != b"\x7fELF":
            raise SystemExit(
                f"enterfs: {path} is not an ELF64 binary. Shebang scripts are not "
                f"supported -- invoke the interpreter explicitly, e.g. "
                f"`-- /usr/bin/python3 {path}`."
            )
        if hdr[4] != 2:
            raise SystemExit(f"enterfs: {path} is not 64-bit; this prototype is ELF64-only")
        end = "little" if hdr[5] == 1 else "big"
        e_phoff = int.from_bytes(hdr[32:40], end)
        e_phentsize = int.from_bytes(hdr[54:56], end)
        e_phnum = int.from_bytes(hdr[56:58], end)
        for i in range(e_phnum):
            f.seek(e_phoff + i * e_phentsize)
            ph = f.read(e_phentsize)
            if int.from_bytes(ph[0:4], end) != 3:  # PT_INTERP
                continue
            p_offset = int.from_bytes(ph[8:16], end)
            p_filesz = int.from_bytes(ph[32:40], end)
            f.seek(p_offset)
            return f.read(p_filesz).rstrip(b"\0").decode()
    return None


def ldd_library_dirs(path):
    """Directories holding the binary's shared libraries, resolved on the host."""
    try:
        out = subprocess.run(["ldd", path], capture_output=True, text=True,
                             check=False).stdout
    except OSError:
        return []
    dirs = []
    for line in out.splitlines():
        if "=>" not in line:
            continue
        rhs = line.split("=>", 1)[1].strip()
        if not rhs.startswith("/"):
            continue
        d = os.path.dirname(rhs.split(" ")[0])
        if d and d not in dirs:
            dirs.append(d)
    return dirs


# --- podman glue ------------------------------------------------------------

def podman_inspect(container, fmt):
    res = subprocess.run(["podman", "inspect", "--format", fmt, container],
                         capture_output=True, text=True)
    if res.returncode != 0:
        raise SystemExit(f"enterfs: no such container: {container}")
    return res.stdout.strip()


def container_pid(container):
    pid = int(podman_inspect(container, "{{.State.Pid}}") or 0)
    if pid == 0:
        raise SystemExit(
            f"enterfs: container {container} is not running (State.Pid=0); "
            f"there is no mount namespace to enter"
        )
    return pid


def pause_pid():
    """PID of the rootless pause process, which owns the user namespace every
    rootless container is created inside."""
    runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    path = f"{runtime}/libpod/tmp/pause.pid"
    if not os.path.exists(path):
        # Nothing rootless has run yet; this materialises the pause process.
        subprocess.run(["podman", "info"], capture_output=True)
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"enterfs: cannot find the rootless pause process ({path}): {exc}")


def in_podman_userns(pause):
    try:
        return os.readlink("/proc/self/ns/user") == os.readlink(f"/proc/{pause}/ns/user")
    except OSError:
        return False


# --- main -------------------------------------------------------------------

def build_env(args, container, cwd):
    if args.use_container_env:
        env = {}
        for kv in json.loads(podman_inspect(container, "{{json .Config.Env}}") or "[]"):
            k, _, v = kv.partition("=")
            env[k] = v
    else:
        env = dict(os.environ)
    for kv in args.env:
        k, _, v = kv.partition("=")
        env[k] = v
    env["PWD"] = cwd
    return env


def main():
    p = argparse.ArgumentParser(
        description="Run a host program with a Podman container's filesystem view.")
    p.add_argument("-c", "--container", required=True)
    p.add_argument("--cwd", help="directory to chdir to inside the container "
                                 "(default: the container's WORKDIR)")
    p.add_argument("--uid", type=int, help="setuid before exec, in the current user namespace")
    p.add_argument("--gid", type=int, help="setgid before exec, in the current user namespace")
    p.add_argument("--host-prefix", default="/mnt",
                   help="where to graft the host root for dynamically-linked programs. "
                        "Must already exist in the image: creating it would write through "
                        "to the container's overlay. (default: /mnt)")
    p.add_argument("--host-bind", action="append", default=[], metavar="PATH",
                   help="bind the host's PATH over the container's PATH, for programs "
                        "that load their own resources by absolute path (e.g. Debian/Ubuntu "
                        "node needs --host-bind /usr/share/nodejs). Repeatable. Visible only "
                        "to the launched process.")
    p.add_argument("--enter-userns", action="store_true",
                   help="also join the container's user namespace (fidelity experiment; "
                        "makes the host-root graft cross a user namespace boundary)")
    p.add_argument("--use-container-env", action="store_true",
                   help="use the image's Config.Env instead of inheriting the host's")
    p.add_argument("-e", "--env", action="append", default=[], metavar="K=V")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("argv", nargs=argparse.REMAINDER)
    args = p.parse_args()

    argv = args.argv[1:] if args.argv and args.argv[0] == "--" else args.argv
    if not argv:
        p.error("no program given; use: enterfs.py -c NAME -- PROGRAM [ARGS...]")

    # Everything that shells out to podman has to happen while we still have the
    # host's filesystem and network view.
    pause = pause_pid()
    pid = container_pid(args.container)
    cwd = args.cwd or podman_inspect(args.container, "{{.Config.WorkingDir}}") or "/"
    program = argv[0] if os.path.isabs(argv[0]) else os.path.abspath(argv[0])
    if not os.path.isfile(program):
        raise SystemExit(f"enterfs: no such host program: {program}")

    interp = elf_interp(program)
    envp = build_env(args, args.container, cwd)

    def log(msg):
        if args.verbose:
            print(f"enterfs: {msg}", file=sys.stderr)

    log(f"container={args.container} pid={pid} cwd={cwd}")
    log(f"program={program} interp={interp or '<static>'}")
    log(f"host mnt-ns={os.readlink('/proc/self/ns/mnt')} "
        f"target mnt-ns={os.readlink(f'/proc/{pid}/ns/mnt')}")

    # Everything that needs the host filesystem must happen before setns.
    prog_fd = None
    tree_fd = None
    lib_dirs = []
    if interp is None:
        prog_fd = os.open(program, os.O_RDONLY)
        # PEP 446 makes Python's fds non-inheritable, i.e. O_CLOEXEC, which would
        # close the fd out from under the exec below.
        os.set_inheritable(prog_fd, True)
    else:
        lib_dirs = ldd_library_dirs(program)
        log(f"library dirs: {lib_dirs}")

    # 1. Join the rootless user namespace. Permitted without privilege because its
    #    owner uid is ours. Must come first: joining a container's mount namespace
    #    straight from the host is EPERM.
    # 2. For the host-root graft, also join the pause process's MOUNT namespace --
    #    open_tree() needs a mount namespace we hold CAP_SYS_ADMIN over, and the
    #    host's is owned by the initial user namespace. The pause process's is a
    #    copy of the host's and is owned by the namespace from step 1.
    # A pidfd lets setns() join both in a single call.
    join = 0 if in_podman_userns(pause) else os.CLONE_NEWUSER
    if interp is not None:
        join |= os.CLONE_NEWNS
    if join:
        os.setns(os.pidfd_open(pause), join)
        log(f"joined rootless namespaces (pause pid {pause}), uid now {os.getuid()}")

    if interp is not None:
        tree_fd = open_tree(AT_FDCWD, b"/", OPEN_TREE_CLONE | AT_RECURSIVE)
        log(f"snapshotted host root as fd {tree_fd}")

    # 3. The actual point of the exercise.
    os.setns(os.pidfd_open(pid),
             os.CLONE_NEWNS | (os.CLONE_NEWUSER if args.enter_userns else 0))
    # Past this point the host filesystem is unreachable except through fds
    # opened above. Diagnostics that read files will not work.

    if interp is not None:
        # Private copy of the container's tree, so the graft is invisible to the
        # container's own processes and disappears when we exit.
        os.unshare(os.CLONE_NEWNS)
        make_rslave(b"/")
        if not os.path.isdir(args.host_prefix):
            raise SystemExit(
                f"enterfs: --host-prefix {args.host_prefix} does not exist in the image; "
                f"pick a directory that does (creating one would write through to the "
                f"container's filesystem)"
            )
        move_mount(tree_fd, b"", AT_FDCWD, args.host_prefix.encode(),
                   MOVE_MOUNT_F_EMPTY_PATH)
        os.close(tree_fd)
        log(f"grafted host root at {args.host_prefix}")

        # Programs that reference their own data by absolute path would otherwise
        # silently read the CONTAINER's copy -- which is worse than failing, since
        # it can succeed with the wrong files.
        prefix = args.host_prefix.rstrip("/")
        for path in args.host_bind:
            if not os.path.exists(path):
                raise SystemExit(
                    f"enterfs: --host-bind {path}: no such path in the image. A bind "
                    f"target must already exist (creating it would write through to the "
                    f"container's filesystem). Bind an existing parent instead, e.g. "
                    f"{os.path.dirname(path) or '/'}."
                )
            bind_over((prefix + path).encode(), path.encode())
            log(f"bound host {path} over container {path}")

    os.chdir(cwd)

    if args.gid is not None:
        os.setgroups([])
        os.setgid(args.gid)
    if args.uid is not None:
        os.setuid(args.uid)

    if interp is None:
        # os.execve accepts a file descriptor (fexecve), so the binary runs from
        # the fd opened back when the host filesystem was still reachable.
        os.execve(prog_fd, [program] + argv[1:], envp)
    else:
        prefix = args.host_prefix.rstrip("/")
        loader = prefix + interp
        launch = [loader, "--inhibit-cache", "--argv0", argv[0]]
        if lib_dirs:
            launch += ["--library-path", ":".join(prefix + d for d in lib_dirs)]
        launch += [prefix + program] + argv[1:]
        os.execve(loader, launch, envp)

    raise SystemExit("enterfs: exec returned, which should be impossible")


if __name__ == "__main__":
    main()
