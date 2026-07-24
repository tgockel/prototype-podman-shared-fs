#!/usr/bin/env bash
# Destroy the demo containers. Kept separate from demo-up.sh because one of the
# things worth observing is whether a live launched process holds the container's
# mount namespace open and interferes with removal.

source "$(dirname "$0")/lib.sh"

for name in "$DEMO_CTR" "$DEMO_CTR_MUSL"; do
    if podman container exists "$name"; then
        podman rm -f "$name" >/dev/null && note "removed $name"
    fi
done
