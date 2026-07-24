# Shared helpers for the podman-shared-fs prototype. Source this; don't run it.
#
# Everything here assumes rootless podman. The one non-obvious fact these scripts
# lean on: `podman unshare` puts you in the rootless *user* namespace AND its own
# *mount* namespace, both owned by the rootless pause process. Task containers are
# created inside that user namespace, so from `podman unshare` we hold CAP_SYS_ADMIN
# over the container's namespaces and setns is permitted.

set -euo pipefail

# BASH_SOURCE is unset when this is sourced from zsh, which is the shell here.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

DEMO_CTR="${DEMO_CTR:-podman-shared-fs-demo}"
DEMO_CTR_MUSL="${DEMO_CTR_MUSL:-podman-shared-fs-demo-musl}"
# glibc/Debian base carrying a Rust toolchain at /usr/local/cargo -- one of the
# images CocoClaw actually builds, so the demo shows a real image toolchain being
# visible to a host process. The musl/Alpine one is the interesting case: it has a
# different libc than the host, which is precisely what breaks the current
# bind-mount-a-host-binary approach.
DEMO_IMAGE="${DEMO_IMAGE:-localhost/outrig-standard:60e465cbb1bcd8e6}"
DEMO_IMAGE_MUSL="${DEMO_IMAGE_MUSL:-localhost/outrig-e2e-custom-ref:latest}"
DEMO_REPO="${DEMO_REPO:-$HERE/demo-repo}"
# Where CocoClaw mounts a need repo (crates/cococlaw-config/src/agent.rs:80-82).
DEMO_REPO_CTR_PATH="${DEMO_REPO_CTR_PATH:-/cococlaw/needs/repo}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '\033[2m%s\033[0m\n' "$*" >&2; }
hdr() { printf '\n\033[1m== %s ==\033[0m\n' "$*" >&2; }

# PID of the container's init process, in the *host* PID namespace. This is the
# setns target. A created-but-not-running container reports 0 and has no mount
# namespace at all, which is the single most common way these scripts fail.
container_pid() {
    local name=$1 pid
    pid=$(podman inspect --format '{{.State.Pid}}' "$name" 2>/dev/null) \
        || die "no such container: $name  (run ./demo-up.sh)"
    [ "$pid" != 0 ] \
        || die "container $name is not running (State.Pid=0); there is no mount namespace to enter"
    printf '%s\n' "$pid"
}

# The container's WORKDIR, defaulting to / -- after setns our old cwd no longer
# exists in the new mount namespace, so somebody has to chdir somewhere valid.
container_workdir() {
    local wd
    wd=$(podman inspect --format '{{.Config.WorkingDir}}' "$1" 2>/dev/null || true)
    printf '%s\n' "${wd:-/}"
}

# True when we are already inside the rootless user namespace, i.e. re-execing
# under `podman unshare` would be a no-op.
in_podman_userns() {
    local pause_pid
    pause_pid=$(cat "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/libpod/tmp/pause.pid" 2>/dev/null) || return 1
    [ -e "/proc/$pause_pid/ns/user" ] || return 1
    [ "$(readlink "/proc/self/ns/user")" = "$(readlink "/proc/$pause_pid/ns/user")" ]
}

require_tools() {
    local t
    for t in "$@"; do
        command -v "$t" >/dev/null || die "missing required tool: $t"
    done
}
