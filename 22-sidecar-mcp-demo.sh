#!/usr/bin/env bash
# Sidecar experiment 3 -- a REAL third-party containerized MCP server serving the
# target container's filesystem.
#
#   ./22-sidecar-mcp-demo.sh [target-container]
#
# docker.io/mcp/filesystem is Docker's packaging of the reference filesystem MCP
# server: Alpine/musl, `node /app/dist/index.js <allowed-dirs...>`. Nothing about
# it is modified. The target container is Debian/glibc. The sidecar's rootfs supplies
# node; the target container supplies the files.
#
# Note the argument asymmetry, which is the whole idea made concrete:
#   /mnt/app/dist/index.js   <- SIDECAR path, so it needs the graft prefix
#   /work/repo               <- TARGET path, used bare

source "$(dirname "$0")/lib.sh"
require_tools podman gcc
set +e +o pipefail

MCP_IMAGE="${MCP_IMAGE:-docker.io/mcp/filesystem:latest}"
ctr="${1:-$DEMO_CTR}"
cpid=$(container_pid "$ctr")

podman image exists "$MCP_IMAGE" || podman pull "$MCP_IMAGE" || die "cannot pull $MCP_IMAGE"
[ -x ./sidecar-enter ] || gcc -static -O2 -o sidecar-enter sidecar-enter.c || die "build failed"

hdr "the MCP image, untouched"
podman image inspect "$MCP_IMAGE" --format \
    '  entrypoint: {{json .Config.Entrypoint}}
  base:       {{index .Config.Env 1}}' 2>/dev/null
printf '  base os:    '; podman run --rm --entrypoint sh "$MCP_IMAGE" -c 'grep -m1 ^ID= /etc/os-release'
printf '  target:      %s -> ' "$ctr"; podman exec "$ctr" grep -m1 ^ID= /etc/os-release

hdr "driving the real server over stdio, against $ctr"
exec python3 - "$ctr" "$cpid" "$MCP_IMAGE" "$PWD" <<'PY'
import json, subprocess, sys

ctr, cpid, image, here = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

cmd = [
    "podman", "run", "--rm", "-i",
    f"--userns=container:{ctr}",
    "--cap-add=SYS_ADMIN", "--cap-add=SYS_PTRACE",
    "-v", f"/proc/{cpid}/ns:/target-ns:ro",
    "-v", f"{here}/sidecar-enter:/sidecar-enter:ro",
    "--entrypoint", "/sidecar-enter",
    image,
    "--ns-file", "/target-ns/mnt", "--graft", "/mnt", "--cwd", "/",
    "--",
    "/usr/local/bin/node", "/mnt/app/dist/index.js", "/work/repo",
]
srv = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       text=True, bufsize=1)

def call(method, params=None, want_reply=True):
    msg = {"jsonrpc": "2.0", "method": method}
    if want_reply:
        call.n += 1
        msg["id"] = call.n
    if params is not None:
        msg["params"] = params
    srv.stdin.write(json.dumps(msg) + "\n"); srv.stdin.flush()
    if not want_reply:
        return None
    while True:
        line = srv.stdout.readline()
        if not line:
            raise SystemExit("server closed the pipe (see stderr above)")
        try:
            reply = json.loads(line)
        except json.JSONDecodeError:
            continue                      # server chatter on stdout, skip
        if reply.get("id") == msg["id"]:
            return reply
call.n = 0

def text(reply):
    if "error" in reply:
        return f"ERROR {reply['error']}"
    return "\n".join(c.get("text", "") for c in reply.get("result", {}).get("content", []))

init = call("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "sidecar-demo", "version": "0"}})
info = init.get("result", {}).get("serverInfo", {})
print(f"initialize -> {info.get('name')} {info.get('version')}\n")
call("notifications/initialized", want_reply=False)

tools = [t["name"] for t in call("tools/list").get("result", {}).get("tools", [])]
print("tools/list ->", ", ".join(tools), "\n")

def pick(*names):
    return next((n for n in names if n in tools), None)

allowed = pick("list_allowed_directories")
if allowed:
    print("list_allowed_directories:\n" + text(call("tools/call",
          {"name": allowed, "arguments": {}})) + "\n")

lister = pick("list_directory", "directory_tree")
if lister:
    print(f"{lister}(/work/repo):\n" + text(call("tools/call",
          {"name": lister, "arguments": {"path": "/work/repo"}})) + "\n")

reader = pick("read_text_file", "read_file")
if reader:
    print(f"{reader}(/work/repo/main.rs):\n" + text(call("tools/call",
          {"name": reader, "arguments": {"path": "/work/repo/main.rs"}})) + "\n")

srv.stdin.close()
srv.wait(timeout=15)
print("server exited cleanly:", srv.returncode == 0)
PY
