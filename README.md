# podman-shared-fs

Run a program **outside** a Podman container whose **filesystem view is inside** it.

The target use case is CocoClaw: today its agent loop runs on the host but MCP tool
servers run *in* the task container over `podman exec -i` stdio, so every MCP server
has to exist in the user's image. CocoClaw already works around this once, by copying
`cococlaw-needs-explorer` into a tempdir, bind-mounting it read-only at `/cococlaw/bin`
and naming it as a toolset command (`cococlaw-agent.rs:1393-1477`) -- which couples the
host-built binary to the image's libc (`doc/agent/harness/toolsets.md`,
`plan/next/needs-explorer-musl-build.md`).

This prototype removes both problems: the server is an ordinary host process, and the
image needs no cooperation at all.

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
| `test.sh` | the 15 checks behind the results table |

```sh
./demo-up.sh && ./test.sh          # 15 passed, 0 failed
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
