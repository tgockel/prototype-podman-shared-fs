#!/usr/bin/env bash
# Regression suite. Needs both demo containers: ./demo-up.sh first.
#
#   ./demo-up.sh && ./test.sh

source "$(dirname "$0")/lib.sh"
# lib.sh sets -euo pipefail, which is wrong for a test harness: several checks
# deliberately run a command that exits non-zero and grep its message, and
# pipefail would fail the pipeline even when the grep matched.
set +e +u +o pipefail

[ -x ./probe ] || gcc -static -o probe probe.c || die "cannot build probe"

pass=0; fail=0
check() {
    if eval "$2" >/tmp/podman-shared-fs-test.out 2>&1; then
        printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1))
    else
        printf '  \033[31mFAIL\033[0m  %s\n' "$1"; sed 's/^/        /' /tmp/podman-shared-fs-test.out | tail -3
        fail=$((fail+1))
    fi
}

hdr "rung 1 -- nsenter, container-resident programs"
check "debian image root"          "./01-enter.sh $DEMO_CTR -- grep -q '^ID=debian' /etc/os-release"
check "alpine image root"          "./01-enter.sh $DEMO_CTR_MUSL -- grep -q '^ID=alpine' /etc/os-release"

hdr "rung 2 -- static host binary, absent from the image"
check "runs at all (debian)"       "./enterfs.py -c $DEMO_CTR -- ./probe | grep -q 'ID=debian'"
check "runs on musl image"         "./enterfs.py -c $DEMO_CTR_MUSL -- ./probe | grep -q 'ID=alpine'"
check "sees the image toolchain"   "./enterfs.py -c $DEMO_CTR -- ./probe | grep -q '/usr/local/cargo/bin/cargo *present'"
check "host root NOT visible"      "./enterfs.py -c $DEMO_CTR -- ./probe | grep -q '/home/travis *ABSENT'"
check "binary absent in container" "! ./01-enter.sh $DEMO_CTR -- test -e $HERE/probe"
check "pid is preserved"           './enterfs.py -c '"$DEMO_CTR"' -- ./probe >/tmp/pp.out 2>&1 & p=$!; wait $p; [ "$(grep "^pid:" /tmp/pp.out | awk "{print \$2}")" = "$p" ]'

hdr "rung 3 -- dynamically linked host binary"
check "host node on debian"        "./enterfs.py -c $DEMO_CTR --host-prefix /mnt -- /usr/bin/node -e 'require(\"fs\").readdirSync(\"/cococlaw/needs/repo\")'"
check "host node on alpine"        "./enterfs.py -c $DEMO_CTR_MUSL --host-prefix /mnt --host-bind /usr/share -- /usr/bin/node -e 'require(\"fs\").readdirSync(\"/cococlaw/needs/repo\")'"
check "graft hidden from container" "test -z \"\$(podman exec $DEMO_CTR ls /mnt)\""

hdr "options and failure modes"
check "--enter-userns gives uid 1000" "./enterfs.py -c $DEMO_CTR --enter-userns -- ./probe | grep -q 'uid/euid: *1000/1000'"
check "--host-bind missing target"    "./enterfs.py -c $DEMO_CTR_MUSL --host-bind /usr/share/nodejs -- /usr/bin/node -e '1' 2>&1 | grep -q 'Bind an existing parent'"
check "unknown container is clean"    "! ./enterfs.py -c no-such-container -- ./probe 2>&1 | grep -q Traceback"

hdr "end to end"
check "cococlaw-needs-explorer over stdio" "./03-mcp-demo.sh | grep -q 'server exited cleanly: True'"

printf '\n\033[1mpassed=%d failed=%d\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
