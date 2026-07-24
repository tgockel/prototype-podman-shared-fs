# podman-shared-fs

Run a program **outside** a Podman container whose **filesystem view is inside** it.

The target use case is CocoClaw: today its agent loop runs on the host but MCP tool
servers run *in* the task container over `podman exec -i` stdio, so every MCP server
has to exist in the user's image. CocoClaw already works around this once, by copying
`cococlaw-needs-explorer` into a tempdir, bind-mounting it read-only at `/cococlaw/bin`
and naming it as a toolset command (`cococlaw-agent.rs:1393-1477`) -- which couples the
host-built binary to the image's libc (`doc/agent/harness/toolsets.md`,
`plan/next/needs-explorer-musl-build.md`).

This prototype removes both problems, two ways. The MCP server runs either as an ordinary
**host process** or as a **sidecar container** — and in both cases the user's task image
needs no cooperation at all. The sidecar form matters because most MCP servers ship as
container images: it runs one unmodified, straight from a registry.

## It works. Results on this machine

Podman 4.9.3 rootless, runc, kernel 7.0.0-28, Python 3.12.3.

| # | Check | Result |
|---|---|---|
| 1 | Container-resident program via `nsenter` | `ID=debian` / `ID=alpine`, repo at `/cococlaw/needs/repo` |
| 2 | **Static host binary, not present in the image** | ran; saw image root, image's `cargo`/`rustup`, **no** `/home/travis` |
| 3 | Same static binary against an **Alpine** container | identical -- **glibc coupling gone** |
| 4 | Host `node` (dynamic) with host root grafted at `/mnt` | `node v18.19.1`, container paths |
| 5 | Host process writes into `/cococlaw/needs/repo` | lands as uid/gid `1000` on both sides, no chown |
| 6 | Graft visible to the container? | **no** -- `ls /mnt` in the container is empty |
| 7 | `podman rm -f` with a live launched process | exit 0, container gone, **process survives** (see Gotchas) |
| 8 | Mount/process leaks after teardown | none |
| 9 | **CocoClaw's real `cococlaw-needs-explorer` over stdio** | full MCP handshake, `list_files`/`read_file` served from the container, no bind mount, no `podman exec` |
| 10 | Sidecar via `--volumes-from` | bind mounts **do** propagate; repo at the identical path, task rootfs not included |
| 11 | Sidecar joins the task's mount namespace | Alpine sidecar sees the Debian task rootfs, its toolchain and its volumes |
| 12 | **Unmodified `docker.io/mcp/filesystem` as a sidecar** | Alpine/musl node 22 serving a Debian/glibc task container's repo over stdio |

Check #9 is the whole point, so in full:

```
$ ./03-mcp-demo.sh
== the server binary, as the container sees it ==
ls: cannot access '.../cococlaw-needs-explorer': No such file or directory   <- only on the host

server pid: 820603            <- a DIRECT child, because enterfs does setns in-process
initialize -> cococlaw-needs-explorer 0.0.0
tools/list -> grep_files, list_files, read_file

list_files(repo):
{"entries":[{"path":"repo/README.md","type":"file"}, ...],"root":"/cococlaw/needs","truncated":false}
read_file(repo/main.rs):
{"bytes":52,"content":"fn main() { println!(\"hello from the need repo\"); }\n", ...}
server exited cleanly: True
```

Built with `cargo build -p cococlaw-needs-explorer --target x86_64-unknown-linux-musl
--release` -- a 4.0M static-pie binary, which `enterfs.py` routes to rung 2 automatically.

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
namespace whose owner uid matches your euid, and CocoClaw's agent is the same user that
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

### Rung 2 -- static binary (this is the one CocoClaw wants)

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

## Sidecars: when the MCP ships as a container image

Most MCP servers are distributed as images, not host binaries. Running them on the host
just relocates the "users must install things" burden. A **sidecar** fixes that: run the
MCP server in its own container, from its own image, but give it the *task* container's
filesystem view. The MCP image supplies the runtime; the task container supplies the files.

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

**Bind mounts do propagate** (podman's man page only promises "volumes"; CocoClaw's needs are
binds). The sidecar sees `/cococlaw/needs/repo` at the identical path, with correct uid 1000.

What it does *not* get: the task image's rootfs. No `cargo`, no toolchain, its own
`/etc/os-release`. And the mount is re-bound from the **host** source, so it is the host's
view of that directory, not the task container's -- nested mounts inside the repo would not
appear. For a filesystem MCP that only needs the repo, this is likely sufficient.

### `setns` from inside the sidecar -- full fidelity

`sidecar-enter.c` is the same technique as `enterfs.py`, relocated: the sidecar's own rootfs
plays exactly the role the host root played in rung 3.

```sh
podman run --rm -i \
  --userns=container:<task> \
  --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE \
  -v /proc/<task-pid>/ns:/task-ns:ro \
  -v $PWD/sidecar-enter:/sidecar-enter:ro \
  --entrypoint /sidecar-enter \
  docker.io/mcp/filesystem:latest \
  --ns-file /task-ns/mnt --graft /mnt -- \
  /usr/local/bin/node /mnt/app/dist/index.js /cococlaw/needs/repo
```

Each requirement was pinned down by a negative test, not assumed:

| requirement | needed? | why |
|---|---|---|
| `--userns=container:<task>` | **yes** | must be in the user namespace that *owns* the target mount namespace |
| `--cap-add=SYS_ADMIN` | **yes** | without it `setns(CLONE_NEWNS)` returns EPERM; the default seccomp profile gates `setns` on this capability |
| `--cap-add=SYS_PTRACE` | **yes** | opening *any* nsfs file needs ptrace-mode read of its owning process |
| `--pid=container:<task>` | **optional** | convenience (target becomes PID 1). Binding `/proc/<pid>/ns` instead keeps the sidecar's own PID namespace |

Verified with `docker.io/mcp/filesystem` — Docker's packaging of the reference filesystem
server, **completely unmodified**: Alpine/musl, `node /app/dist/index.js`. Against a
**Debian/glibc** task container it serves `list_directory` and `read_file` over stdio from
`/cococlaw/needs/repo`. A musl binary running on a glibc rootfs, fully decoupled — the same
property that makes the static rung work, arrived at from the other direction.

**The argument asymmetry is the idea made concrete.** In that command line:

```
/mnt/app/dist/index.js    <- SIDECAR path, needs the graft prefix
/cococlaw/needs/repo      <- TASK path, used bare
```

Arguments naming the MCP's own files must be prefixed; arguments naming the work must not.
`sidecar-enter` rewrites the *program* path only — it cannot know which of your arguments is
which, and guessing would be worse than making you say it.

### Sidecar vs. host process

|  | host process | sidecar |
|---|---|---|
| MCP distribution | must be installed on the host | **any container image, unmodified** |
| task image | untouched | untouched |
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
| `demo-up.sh` / `demo-down.sh` | demo containers, using CocoClaw's real podman flags |
| `probe.c` | static payload; reports the filesystem view it actually got |
| `01-enter.sh` | rung 1, `nsenter`, container-resident programs |
| `enterfs.py` | rungs 2 and 3, the actual launcher |
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

## What this would change in CocoClaw

- Deletes `EXPLORER_BIN_DIR` / `stage_explorer_mount` / `inject_explorer_mount`
  (`cococlaw-agent.rs:1393-1477`) and the `COCOCLAW_NEEDS_EXPLORER_BIN` musl escape hatch --
  the binary no longer has to enter the container at all.
- Adds a third `McpBackend` beside `Outrig`/`Remote`, spawned where `mcp.rs:134-148` builds
  the `podman exec -i` child. The stdio contract is unchanged, so `rmcp::service::serve_client`
  is untouched, and `kill_on_drop` becomes *more* reliable than today because the server is a
  direct child rather than a grandchild behind `podman exec`.
- A Rust port should do the two `setns` calls itself rather than shelling out, and must do so
  before starting the tokio runtime (single-threaded requirement above). The usual shape is a
  `fork()` + setns in the child, or `Command::pre_exec`.

The sidecar form suggests a second, larger change: a harness could name an **MCP image**
rather than a command that must already exist in the task image. `ToolsetSpec::Mcp` gains an
`image` field; the runner starts the sidecar with `--userns=container:<task>`, the two
capabilities, and the ns bind, and keeps the stdio pipe exactly as `mcp.rs:134-148` does now.
That turns "install these MCP servers into your image" into "name the image you want", which
is the whole problem this prototype set out to remove.
