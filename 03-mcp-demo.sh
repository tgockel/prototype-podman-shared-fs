#!/usr/bin/env bash
# End to end: CocoClaw's REAL cococlaw-needs-explorer MCP server, running as a
# host process, serving the container's filesystem over stdio.
#
# Compare with what CocoClaw does today:
#   - today:  copy the binary to a tempdir, bind-mount it at /cococlaw/bin,
#             `podman exec -i --user=... <ctr> /cococlaw/bin/cococlaw-needs-explorer`
#   - here:   `enterfs.py -c <ctr> -- /path/on/host/cococlaw-needs-explorer`
#
# No bind mount. No podman exec. The image is untouched and never consulted for
# a libc, which is the coupling recorded in plan/next/needs-explorer-musl-build.md.

source "$(dirname "$0")/lib.sh"

COCOCLAW_SRC="${COCOCLAW_SRC:-/home/travis/projects/open-source/cococlaw}"
BIN="${EXPLORER_BIN:-$HERE/.target/x86_64-unknown-linux-musl/release/cococlaw-needs-explorer}"

if [ ! -x "$BIN" ]; then
    hdr "building cococlaw-needs-explorer as a static musl binary"
    [ -d "$COCOCLAW_SRC" ] || die "set COCOCLAW_SRC or EXPLORER_BIN; not found: $COCOCLAW_SRC"
    rustup target add x86_64-unknown-linux-musl
    ( cd "$COCOCLAW_SRC" && CARGO_TARGET_DIR="$HERE/.target" \
        cargo build -p cococlaw-needs-explorer --target x86_64-unknown-linux-musl --release )
fi

ctr="${1:-$DEMO_CTR}"
container_pid "$ctr" >/dev/null

hdr "the server binary, as the container sees it"
./01-enter.sh "$ctr" -- ls -l "$BIN" 2>&1 | grep -v '^.\[2m' || true
note "^ absent inside the container -- it only exists on the host"

hdr "driving it over stdio"
exec python3 - "$ctr" "$BIN" <<'PY'
import json, os, subprocess, sys

ctr, binary = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__)) if "__file__" in dir() else os.getcwd()

srv = subprocess.Popen(
    [os.path.join(os.getcwd(), "enterfs.py"), "-c", ctr, "--", binary],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
)
print(f"server pid: {srv.pid}  <- a DIRECT child, because enterfs does setns in-process\n")

def call(method, params=None, want_reply=True):
    msg = {"jsonrpc": "2.0", "method": method}
    if want_reply:
        call.n += 1
        msg["id"] = call.n
    if params is not None:
        msg["params"] = params
    srv.stdin.write(json.dumps(msg) + "\n")
    srv.stdin.flush()
    if not want_reply:
        return None
    while True:
        line = srv.stdout.readline()
        if not line:
            raise SystemExit("server closed the pipe")
        reply = json.loads(line)
        if reply.get("id") == msg["id"]:
            return reply
call.n = 0

def show(label, reply):
    if "error" in reply:
        print(f"{label}: ERROR {reply['error']}")
        return
    content = reply.get("result", {}).get("content")
    if content:
        for c in content:
            print(f"{label}:\n{c.get('text', c)}")
    else:
        print(f"{label}: {json.dumps(reply.get('result'))[:300]}")
    print()

init = call("initialize", {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": {"name": "podman-shared-fs-demo", "version": "0"},
})
info = init.get("result", {}).get("serverInfo", {})
print(f"initialize -> {info.get('name')} {info.get('version')}\n")
call("notifications/initialized", want_reply=False)

tools = call("tools/list").get("result", {}).get("tools", [])
print("tools/list ->", ", ".join(t["name"] for t in tools), "\n")

show("list_files(repo)", call("tools/call", {"name": "list_files", "arguments": {"path": "repo"}}))
show("read_file(repo/main.rs)",
     call("tools/call", {"name": "read_file", "arguments": {"path": "repo/main.rs"}}))

srv.stdin.close()
srv.wait(timeout=10)
print("server exited cleanly:", srv.returncode == 0)
PY
