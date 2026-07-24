#!/usr/bin/env bash
# End to end: an MCP server running as a HOST process, serving the container's
# filesystem over stdio.
#
#   ./03-mcp-demo.sh [container]
#
# The server is mcp-fs, built here as a static binary. Nothing is bind-mounted into
# the container and no `podman exec` is involved: the binary exists only on the
# host, is opened there, and is exec'd from that file descriptor after switching
# into the container's mount namespace. Its own libc never meets the image's.
#
# mcp-fs is a minimal stand-in, not a real MCP implementation -- see mcp-fs.c. The
# point being demonstrated is where the process runs and what it can see, not the
# protocol. For a genuine third-party MCP server, see 22-sidecar-mcp-demo.sh.

source "$(dirname "$0")/lib.sh"
require_tools podman gcc python3

ctr="${1:-$DEMO_CTR}"
container_pid "$ctr" >/dev/null

[ -x ./mcp-fs ] || gcc -static -O2 -o mcp-fs mcp-fs.c || die "cannot build mcp-fs"

hdr "the server binary, as the container sees it"
./01-enter.sh "$ctr" -- ls -l "$PWD/mcp-fs" 2>&1 | grep -v '^.\[2m' || true
note "^ absent inside the container -- it only exists on the host"

hdr "driving it over stdio"
exec python3 - "$ctr" "$PWD/mcp-fs" "$DEMO_REPO_CTR_PATH" <<'PY'
import json, os, subprocess, sys

ctr, binary, repo = sys.argv[1], sys.argv[2], sys.argv[3]

srv = subprocess.Popen(
    [os.path.join(os.getcwd(), "enterfs.py"), "-c", ctr, "--", binary, "--root", repo],
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
    for c in reply.get("result", {}).get("content", []):
        print(f"{label}:\n{c.get('text', c)}")
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

show(f"list_files({repo})",
     call("tools/call", {"name": "list_files", "arguments": {"path": "."}}))
show(f"read_file({repo}/main.rs)",
     call("tools/call", {"name": "read_file", "arguments": {"path": "main.rs"}}))

srv.stdin.close()
srv.wait(timeout=10)
print("server exited cleanly:", srv.returncode == 0)
PY
