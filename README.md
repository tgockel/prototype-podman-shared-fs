# podman-shared-fs

Run a program **outside** a Podman container whose **filesystem view is inside** it.

## The problem

You have a container doing some work — a build, an agent task, a sandbox — with a project
mounted into it. Now you want a *tool* to operate on that container's files: an indexer, a
language server, a file-serving MCP server, a linter.

The usual answers are all unsatisfying:

- **Install the tool in the image.** Now every image needs every tool, and users have to
  maintain that.
- **Bind-mount a host-built binary in and `podman exec` it.** Now that binary is coupled to
  the image's libc — a glibc build aborts with `GLIBC_x.y not found` inside an Alpine image.
- **Work on the host directory behind the bind mount.** You lose path fidelity: the tool
  reports `/tmp/tmp.XYZ/src/main.rs` where the container calls it `/work/repo/src/main.rs`,
  and you cannot see the image's own contents at all.

This prototype does it a fourth way: run the tool **outside** the container, but give it the
container's **filesystem view**. Paths match exactly, the image's own files are visible, and
the image needs no cooperation whatsoever.

Two forms, both working:

- a **host process** — the tool runs on the host, borrowing the container's view
- a **sidecar container** — the tool runs in *its own* image, borrowing the container's view

The sidecar form matters because tools are so often distributed as images. It runs one
unmodified, straight from a registry.

Throughout, the container being looked *into* is called the **target container**.

## It works. Results on this machine

Podman 4.9.3 rootless, runc, kernel 7.0.0-28, Python 3.12.3. The demo targets are stock
`docker.io/library/rust:1-bookworm` (glibc/Debian, ships a Rust toolchain at
`/usr/local/cargo`) and `docker.io/library/alpine:latest` (musl), with a project bind-mounted
at `/work/repo`.

| # | Check | Result |
|---|---|---|
| 1 | Container-resident program via `nsenter` | `ID=debian` / `ID=alpine`, project at `/work/repo` |
| 2 | **Static host binary, not present in the image** | ran; saw the image's root and its `cargo`/`rustup`, and **not** the host's `$HOME` |
| 3 | Same static binary against an **Alpine** target | identical -- **libc coupling gone** |
| 4 | Host `node` (dynamic) with host root grafted at `/mnt` | `node v18.19.1`, container paths |
| 5 | Host process writes into `/work/repo` | lands as uid/gid `1000` on both sides, no chown |
| 6 | Graft visible to the target container? | **no** -- `ls /mnt` in the container is empty |
| 7 | `podman rm -f` with a live launched process | exit 0, container gone, **process survives** (see Gotchas) |
| 8 | Mount/process leaks after teardown | none |
| 9 | **A static MCP server over stdio** | full handshake, `list_files`/`read_file` served from the container, no bind mount, no `podman exec` |
| 10 | Sidecar via `--volumes-from` | bind mounts **do** propagate; project at the identical path, target rootfs not included |
| 11 | Sidecar joins the target's mount namespace | Alpine sidecar sees the Debian target's rootfs, toolchain and volumes |
| 12 | **Unmodified `docker.io/mcp/filesystem` as a sidecar** | Alpine/musl node 22 serving a Debian/glibc target's project over stdio |

Check #9 in full — note the binary does not exist inside the container it is serving:

```
$ ./03-mcp-demo.sh
== the server binary, as the container sees it ==
ls: cannot access '.../mcp-fs': No such file or directory    <- only on the host

server pid: 1210210   <- a DIRECT child, because enterfs does setns in-process
initialize -> mcp-fs 0.1.0
tools/list -> list_files, read_file

list_files(/work/repo):
[FILE] written-by-host.txt
[FILE] README.md
[FILE] main.rs
read_file(/work/repo/main.rs):
fn main() { println!("hello from the mounted project"); }
server exited cleanly: True
```

`mcp-fs` is a ~200-line static C stand-in (`mcp-fs.c`) so this repo depends on no particular
MCP implementation; check #12 uses a real third-party one.

## How it works

```
host process                            container
  ├─ mount ns  ── setns ──────────────►  /  = image rootfs + volumes
  ├─ net ns    ── stays host ─────────►  internet, orchestrator
  ├─ pid ns    ── stays host ─────────►  parent can wait()/kill() it
  └─ cgroup    ── stays host
```

Only the mount namespace is entered. Everything else stays host-side, which is the
entire point: the process remains an ordinary child of whoever spawned it.

**No `podman unshare` wrapper.** Namespace entry happens in-process. `podman unshare`
forks, so the caller would get podman's pid instead of the program's -- fatal for an
orchestrator that needs to `wait()` on the MCP server or kill it. Verified: with
in-process setns, `$!` equals the program's own `getpid()`.

That is allowed without privilege because the kernel grants capabilities over a user
namespace whose owner uid matches your euid, and the launcher runs as the same user that
created the container. **Ordering is forced:**

```
setns(pidfd_open(<pause>), CLONE_NEWUSER)   # first, or...
setns(pidfd_open(<ctr>),   CLONE_NEWNS)     # ...this is EPERM
```

(A *pidfd* can carry several namespace flags in one `setns()`; an `/proc/<pid>/ns/*` fd
can only carry one. Rung 3 uses `CLONE_NEWUSER | CLONE_NEWNS` in a single call.)

`<pause>` is the rootless pause process (`$XDG_RUNTIME_DIR/libpod/tmp/pause.pid`), which
owns the user namespace every rootless container is created inside.

We join the **rootless** user namespace, not the container's. That keeps `unshare()` and
`move_mount()` inside one user namespace, and under `--userns=keep-id` rootless-userns
uid 0 *is* container uid 1000 -- so files land with exactly the ownership the container's
processes expect. (`--enter-userns` joins the container's instead; it also works, and
reports uid 1000 directly.)

## The two rungs

`enterfs.py` picks automatically by reading the binary's ELF `PT_INTERP`.

### Rung 2 -- static binary (the interesting one)

`open()` the binary on the host, `setns()`, then fexecve it -- `os.execve()` accepts a file
descriptor, so no ctypes needed. The open fd survives the namespace switch, so the binary
runs even though its path no longer exists. Nothing resolves through the container -- no
interpreter, no libraries -- so the image's libc is irrelevant. This is what makes check
\#3 pass.

```sh
gcc -static -o probe probe.c
./enterfs.py -c podman-shared-fs-demo -- ./probe
```

### Rung 3 -- dynamically linked binary

The loader and libraries are gone after `setns()`, so before switching,
`open_tree(OPEN_TREE_CLONE|AT_RECURSIVE)` snapshots the host root; after switching,
`unshare(CLONE_NEWNS)` gives a private copy of the container's tree and `move_mount()`
grafts the host snapshot in at `--host-prefix`. The program is then run through the host
loader with an explicit `--library-path`.

```sh
./enterfs.py -c podman-shared-fs-demo --host-prefix /mnt \
    --host-bind /usr/share -- /usr/bin/node -e 'console.log(1)'
```

## Sidecars: when the tool ships as a container image

Plenty of tools are distributed as images rather than host binaries — MCP servers especially.
Running one on the host just relocates the "users must install things" burden. A **sidecar**
removes it: run the tool in its own container, from its own image, but give it the *target*
container's filesystem view. The tool's image supplies the runtime; the target container
supplies the files. Neither image has to know about the other.

Podman shares every namespace **except the one we need**:

| flag | shares |
|---|---|
| `--pid=container:id`, `--userns=container:id`, `--network=`, `--ipc=`, `--uts=`, `--cgroupns=` | those namespaces |
| `--volumes-from CONTAINER[:ro]` | the source container's mounts |
| — | **no mount-namespace flag exists** |

So there are two routes, and the cheap one may be enough.

### `--volumes-from` -- baseline, no privileges

```sh
podman run --rm --volumes-from podman-shared-fs-demo --userns=keep-id alpine ...
```

**Bind mounts do propagate** (podman's man page only promises "volumes"; the mounts here are
plain binds). The sidecar sees `/work/repo` at the identical path, with correct uid 1000.

What it does *not* get: the target image's rootfs. No `cargo`, no toolchain, its own
`/etc/os-release`. And the mount is re-bound from the **host** source, so it is the host's
view of that directory, not the target container's -- nested mounts inside the repo would not
appear. For a filesystem MCP that only needs the repo, this is likely sufficient.

### `setns` from inside the sidecar -- full fidelity

`sidecar-enter.c` is the same technique as `enterfs.py`, relocated: the sidecar's own rootfs
plays exactly the role the host root played in rung 3.

```sh
podman run --rm -i \
  --userns=container:<target> \
  --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE \
  -v /proc/<target-pid>/ns:/target-ns:ro \
  -v $PWD/sidecar-enter:/sidecar-enter:ro \
  --entrypoint /sidecar-enter \
  docker.io/mcp/filesystem:latest \
  --ns-file /target-ns/mnt --graft /mnt -- \
  /usr/local/bin/node /mnt/app/dist/index.js /work/repo
```

Each requirement was pinned down by a negative test, not assumed:

| requirement | needed? | why |
|---|---|---|
| `--userns=container:<target>` | **yes** | must be in the user namespace that *owns* the target mount namespace |
| `--cap-add=SYS_ADMIN` | **yes** | without it `setns(CLONE_NEWNS)` returns EPERM; the default seccomp profile gates `setns` on this capability |
| `--cap-add=SYS_PTRACE` | **yes** | opening *any* nsfs file needs ptrace-mode read of its owning process |
| `--pid=container:<target>` | **optional** | convenience (target becomes PID 1). Binding `/proc/<pid>/ns` instead keeps the sidecar's own PID namespace |

Verified with `docker.io/mcp/filesystem` — Docker's packaging of the reference filesystem
server, **completely unmodified**: Alpine/musl, `node /app/dist/index.js`. Against a
**Debian/glibc** target container it serves `list_directory` and `read_file` over stdio from
`/work/repo`. A musl binary running on a glibc rootfs, fully decoupled — the same
property that makes the static rung work, arrived at from the other direction.

**The argument asymmetry is the idea made concrete.** In that command line:

```
/mnt/app/dist/index.js    <- SIDECAR path, needs the graft prefix
/work/repo      <- TARGET path, used bare
```

Arguments naming the MCP's own files must be prefixed; arguments naming the work must not.
`sidecar-enter` rewrites the *program* path only — it cannot know which of your arguments is
which, and guessing would be worse than making you say it.

### Sidecar vs. host process

|  | host process | sidecar |
|---|---|---|
| MCP distribution | must be installed on the host | **any container image, unmodified** |
| target image | untouched | untouched |
| sandboxing | none — host network, host capabilities | still a container: cgroups, network policy, seccomp apply |
| privileges | none beyond the user's own | **CAP_SYS_ADMIN + CAP_SYS_PTRACE** in the rootless userns |
| supervision | direct child, pid preserved | `podman run` is the child, as today |

Neither dominates. The sidecar's capabilities are scoped to the rootless user namespace, not
host root, so they are far weaker than they read — but they are still the price for what the
host process gets for free.

## Gotchas found the hard way

- **`nsenter -w` resolves the directory on the *caller's* side.** `--wd=/workspace` fails
  ENOENT because /workspace is a container path. Use `-W/--wdns` (util-linux 2.39+).

- **Rung 3 can silently load the container's files.** Debian/Ubuntu `node` loads runtime
  assets by absolute path (`/usr/share/nodejs/...`). After the graft that resolves to the
  *container's* copy. On Alpine it aborts loudly -- but on our Debian demo image it
  **succeeded while quietly using the container's JavaScript**, which is worse. Hence
  `--host-bind PATH`, which binds the host's copy back over the container's inside the
  private namespace. A self-contained runtime (official Node tarball, which resolves
  relative to `execPath`) avoids this entirely. **Static binaries have none of this
  problem**, which is a real argument for rung 2.

- **A launched process outlives `podman rm -f`.** The container's mount namespace stays
  alive as long as a process holds it, so an orphan keeps happily reading a repo whose
  container is gone -- serving stale state instead of failing. Verified. Whoever spawns
  these must kill them on container teardown; it will not self-heal. No storage leak once
  the process exits.

- **Bind/graft targets must already exist in the image.** Creating them writes through to
  the container's real filesystem. `/mnt` is the default because it is conventionally
  present and empty.

- **`os.setns(..., CLONE_NEWUSER)` requires a single-threaded process.** Fine for a script;
  a constraint worth remembering for a Rust port, which must do the setns before spawning
  a runtime.

- **The container must be running.** A `Created` container reports `State.Pid=0` and has no
  mount namespace. `podman unshare podman mount` is the stopped-container fallback, but it
  gives you the image rootfs without volumes.

## Security note (read before shipping this)

Today the MCP server is confined *by* the container. A host process that merely borrows the
filesystem view is **not**: it keeps host network, host capabilities, and the container's
`--cap-drop` / `--security-opt=no-new-privileges` / network policy do not apply to it. This
trades sandboxing for convenience. A real deployment should apply `no_new_privs` and a
seccomp policy in the launcher itself, and treat the borrowed filesystem view as the *only*
thing the container is providing.

## Files

| File | |
|---|---|
| `lib.sh` | shared shell helpers |
| `demo-up.sh` / `demo-down.sh` | demo target containers |
| `probe.c` | static payload; reports the filesystem view it actually got |
| `01-enter.sh` | rung 1, `nsenter`, container-resident programs |
| `enterfs.py` | rungs 2 and 3, the actual launcher |
| `mcp-fs.c` | minimal static MCP server, so the demo needs no external implementation |
| `03-mcp-demo.sh` | end-to-end MCP server, host-side, container view |
| `sidecar-enter.c` | static in-sidecar launcher (the same technique, relocated) |
| `20-sidecar-volumes.sh` | sidecar baseline: `--volumes-from` |
| `21-sidecar-setns.sh` | sidecar full fidelity, both variants + negative tests |
| `22-sidecar-mcp-demo.sh` | real `docker.io/mcp/filesystem`, unmodified |
| `test.sh` | the 25 checks behind the results tables |

```sh
./demo-up.sh && ./test.sh          # 25 passed, 0 failed
./demo-down.sh
```

## Adopting this

If you are wiring this into something real, the parts that matter:

- **Nothing has to enter the target image.** Whatever you were bind-mounting in and
  `podman exec`-ing can move outside, which also dissolves the libc coupling. If you
  currently ship a musl build purely so a host binary can run inside an unknown image, you
  no longer need one.

- **Do the `setns` calls in-process, not via `podman unshare`.** The wrapper forks, so a
  supervisor would hold the wrong pid. In a language with a threaded runtime this means
  doing it before the runtime starts — in Rust, `Command::pre_exec` or a `fork()` with the
  setns in the child, since `setns(CLONE_NEWUSER)` requires a single-threaded process.

- **The stdio contract is unchanged.** For a tool spoken to over pipes, the launcher is a
  transparent shim: same stdin/stdout, and process supervision gets *more* reliable than
  `podman exec`, because the tool is a direct child rather than a grandchild.

- **The sidecar form lets a config name an image instead of a command.** Rather than "this
  tool must already exist in your image at this path", a spec can say "run this image
  against that container" — the tool brings its own runtime and the target image stays
  untouched. That is the version of this worth building if tools are distributed as images.

- **Kill launched processes on teardown.** They outlive `podman rm -f` and keep serving a
  filesystem whose container is gone. Nothing else will clean that up.
