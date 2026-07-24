#!/usr/bin/env bash
# Sidecar experiment 2 -- full fidelity: the sidecar joins the TASK container's
# mount namespace, so it sees the target image's entire rootfs plus its volumes,
# while its own image supplies the program and runtime.
#
#   ./21-sidecar-setns.sh [target-container]
#
# Two variants are exercised, plus the negative tests that pin down which
# capabilities are actually load-bearing.

source "$(dirname "$0")/lib.sh"
require_tools podman gcc
# The negative tests below deliberately run commands that exit non-zero and grep
# their message; lib.sh's -e/pipefail would misreport those as script failures.
set +e +o pipefail

SIDECAR_IMAGE="${SIDECAR_IMAGE:-docker.io/library/alpine:latest}"
ctr="${1:-$DEMO_CTR}"
cpid=$(container_pid "$ctr")

[ -x ./sidecar-enter ] || gcc -static -O2 -o sidecar-enter sidecar-enter.c || die "build failed"
[ -x ./probe ] || gcc -static -o probe probe.c || die "build failed"

mounts=(-v "$PWD/sidecar-enter:/sidecar-enter:ro" -v "$PWD/probe:/probe:ro")

hdr "A -- sharing the PID namespace (target is PID 1)"
note "podman run --pid=container:$ctr --userns=container:$ctr --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE"
podman run --rm \
    --pid="container:$ctr" \
    --userns="container:$ctr" \
    --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE \
    "${mounts[@]}" \
    "$SIDECAR_IMAGE" /sidecar-enter --target 1 -- /probe

hdr "B -- no PID namespace sharing (bind the ns directory instead)"
note "the sidecar keeps its own PID namespace; only the mount namespace is joined"
podman run --rm \
    --userns="container:$ctr" \
    --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE \
    -v "/proc/$cpid/ns:/target-ns:ro" \
    "${mounts[@]}" \
    "$SIDECAR_IMAGE" /sidecar-enter --ns-file /target-ns/mnt -- /probe

hdr "negative tests -- which flags are actually required"

printf '  without --cap-add=SYS_ADMIN:   '
podman run --rm --pid="container:$ctr" --userns="container:$ctr" --cap-add=SYS_PTRACE \
    "${mounts[@]}" "$SIDECAR_IMAGE" /sidecar-enter --target 1 -- /probe 2>&1 \
    | grep -o 'setns.*' | head -1 || echo "UNEXPECTEDLY SUCCEEDED"

printf '  without --cap-add=SYS_PTRACE:  '
podman run --rm --pid="container:$ctr" --userns="container:$ctr" --cap-add=SYS_ADMIN \
    "${mounts[@]}" "$SIDECAR_IMAGE" /sidecar-enter --target 1 -- /probe 2>&1 \
    | grep -o '/proc/1/ns/mnt.*' | head -1 || echo "UNEXPECTEDLY SUCCEEDED"

printf '  binding the nsfs FILE (not dir): '
podman run --rm --userns="container:$ctr" --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE \
    -v "/proc/$cpid/ns/mnt:/target-mnt-ns:ro" "${mounts[@]}" \
    "$SIDECAR_IMAGE" /sidecar-enter --ns-file /target-mnt-ns -- /probe 2>&1 \
    | grep -o 'invalid argument' | head -1 || echo "worked"
echo "    ^ podman's -v always adds MS_REC, which nsfs rejects; bind the DIRECTORY"

hdr "is the graft visible to the target container?"
printf '  ls /mnt inside %s -> ' "$ctr"
out=$(podman exec "$ctr" ls -A /mnt 2>&1)
[ -z "$out" ] && echo "empty (private to the sidecar, as intended)" || echo "LEAKED: $out"
