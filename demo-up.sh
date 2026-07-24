#!/usr/bin/env bash
# Create the demo containers.
#
#   ./demo-up.sh          both containers
#   ./demo-up.sh glibc    just the glibc/Debian one
#   ./demo-up.sh musl     just the musl/Alpine one
#
# The flags are typical of a sandboxed target container: a project bind-mounted in,
# --userns=keep-id so files written inside keep the invoking user's ownership, and
# `sleep infinity` as a long-lived init to exec against. Nothing here is special
# to this prototype -- these are the containers we want to look *into*.

source "$(dirname "$0")/lib.sh"
require_tools podman

which=${1:-both}

mkdir -p "$DEMO_REPO"
cat >"$DEMO_REPO/README.md" <<'EOF'
# demo-repo

Stands in for a project you would mount into a container. On the host it lives in
the prototype directory; inside the container it is at /work/repo.
EOF
printf 'fn main() { println!("hello from the mounted project"); }\n' >"$DEMO_REPO/main.rs"

start() {
    local name=$1 image=$2
    podman image exists "$image" || podman pull "$image" || die "cannot pull $image"
    podman rm -f "$name" >/dev/null 2>&1 || true
    podman run -d --rm --name "$name" \
        -v "$DEMO_REPO:$DEMO_REPO_CTR_PATH:rw" \
        -w "$DEMO_WORKDIR" \
        --userns=keep-id \
        --security-opt=no-new-privileges \
        "$image" sleep infinity >/dev/null
    printf '%-32s %-36s pid=%s\n' "$name" "$image" "$(container_pid "$name")"
}

case "$which" in
    glibc) start "$DEMO_CTR" "$DEMO_IMAGE" ;;
    musl)  start "$DEMO_CTR_MUSL" "$DEMO_IMAGE_MUSL" ;;
    both)
        start "$DEMO_CTR" "$DEMO_IMAGE"
        start "$DEMO_CTR_MUSL" "$DEMO_IMAGE_MUSL"
        ;;
    *) die "usage: $0 [glibc|musl|both]" ;;
esac
