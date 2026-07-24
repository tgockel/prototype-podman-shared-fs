#!/usr/bin/env bash
# Sidecar experiment 1 -- the supported, boring baseline: --volumes-from.
#
# Podman shares every namespace but the one we want (--pid=container:, --userns=container:,
# --network=container:, --ipc=, --uts=, --cgroupns= ... and no mount-namespace flag). So the
# cheapest way to give a sidecar the task container's FILES is to re-mount its volumes.
#
# The question this answers, which the man page does not: CocoClaw's needs are BIND mounts
# (`-v host:ctr`, outrig container/mod.rs:571-587), not named volumes, and podman's docs only
# promise "already mounted volumes". Do binds come along?
#
# Uses an Alpine sidecar against the Debian task container so "whose rootfs am I looking at?"
# has an unambiguous answer.

source "$(dirname "$0")/lib.sh"
require_tools podman

SIDECAR_IMAGE="${SIDECAR_IMAGE:-docker.io/library/alpine:latest}"
ctr="${1:-$DEMO_CTR}"
container_pid "$ctr" >/dev/null

hdr "sidecar with --volumes-from $ctr"
note "sidecar image: $SIDECAR_IMAGE   task container: $ctr"

podman run --rm \
    --volumes-from "$ctr" \
    --userns=keep-id \
    "$SIDECAR_IMAGE" sh -c '
        printf "whose rootfs?          "; grep -m1 ^ID= /etc/os-release
        printf "task repo visible?     "
        if [ -d /cococlaw/needs/repo ]; then echo "yes -> $(ls /cococlaw/needs/repo | tr "\n" " ")"
        else echo "NO"; fi
        printf "task image toolchain?  "
        if [ -e /usr/local/cargo/bin/cargo ]; then echo "present"; else echo "ABSENT"; fi
        printf "uid/gid                "; id -u;
        printf "backing mount:         "; grep " /cococlaw/needs/repo " /proc/self/mounts | cut -d" " -f1-3
    '

hdr "what this does and does not get you"
cat <<'EOF'
  +  bind mounts DO propagate -- the repo is at the identical container path
  +  no capabilities, no namespace tricks, fully supported by podman
  -  the sidecar sees its OWN rootfs, not the task image's (no cargo, no toolchain)
  -  it is re-bound from the HOST source, so it is the host's view of that directory,
     not the task container's view of it -- nested mounts inside the repo would not show

  For a filesystem MCP that only needs the repo, this may simply be enough.
  When the MCP needs to see the task image itself, use 21-sidecar-setns.sh.
EOF
