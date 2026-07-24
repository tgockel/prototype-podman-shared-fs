#!/usr/bin/env bash
# Rung 1: run a CONTAINER-RESIDENT program in the container's mount namespace.
#
#   ./01-enter.sh <container> -- <program> [args...]
#   ./01-enter.sh podman-shared-fs-demo -- cat /etc/os-release
#
# This is the whole mechanism in one line. The catch, and the reason enterfs.py
# exists, is that nsenter resolves <program> *after* setns -- so the program has
# to already exist inside the container. A host path will just be ENOENT.
#
# Note we enter --mount only. Network, PID and cgroup namespaces stay the host's,
# which is what makes this useful: the process is still an ordinary host child
# that the orchestrator can wait() on and that can reach the network normally.

source "$(dirname "$0")/lib.sh"
require_tools podman nsenter

[ $# -ge 1 ] || die "usage: $0 <container> [--] <program> [args...]"
ctr=$1; shift
[ "${1:-}" = "--" ] && shift
[ $# -ge 1 ] || die "no program given"

pid=$(container_pid "$ctr")
wd=$(container_workdir "$ctr")

note "container=$ctr pid=$pid wd=$wd"
note "host mnt-ns:      $(readlink /proc/self/ns/mnt)"
note "container mnt-ns: $(readlink "/proc/$pid/ns/mnt" 2>/dev/null || echo '<needs podman unshare to read>')"

# --wdns, not --wd: -w resolves the directory in the CALLER's namespace (so a
# container-only path like /workspace fails with ENOENT), while -W resolves it
# after entering. util-linux 2.39+.
exec podman unshare nsenter --mount --target "$pid" --wdns="$wd" -- "$@"
