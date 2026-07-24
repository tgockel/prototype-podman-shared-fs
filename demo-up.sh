#!/usr/bin/env bash
# Create the demo containers. Flags mirror what outrig actually passes for a
# CocoClaw task container (outrig-0.1.0/src/container/mod.rs:509-542) so the
# prototype is exercising the real shape, --userns=keep-id included.
#
#   ./demo-up.sh          both containers
#   ./demo-up.sh glibc    just the glibc one
#   ./demo-up.sh musl     just the musl one

source "$(dirname "$0")/lib.sh"
require_tools podman

which=${1:-both}

mkdir -p "$DEMO_REPO"
cat >"$DEMO_REPO/README.md" <<'EOF'
# demo-repo

Stands in for a CocoClaw need repo. On the host this lives in the prototype
directory; inside the container it is /cococlaw/needs/repo.
EOF
printf 'fn main() { println!("hello from the need repo"); }\n' >"$DEMO_REPO/main.rs"

start() {
    local name=$1 image=$2
    if ! podman image exists "$image"; then
        die "image not present locally: $image  (these scripts use --pull=never)"
    fi
    podman rm -f "$name" >/dev/null 2>&1 || true
    podman run -d --rm --name "$name" \
        -v "$DEMO_REPO:$DEMO_REPO_CTR_PATH:rw" \
        --userns=keep-id \
        --security-opt=no-new-privileges \
        --pull=never \
        "$image" sleep infinity >/dev/null
    printf '%-32s %-44s pid=%s\n' "$name" "$image" "$(container_pid "$name")"
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
