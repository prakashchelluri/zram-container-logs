#!/bin/sh
# Plain POSIX shell tests for zram-logs.sh: argument handling, 'plan' output
# and the non-root guards. Needs no root, no zram and no kubelet.
# Run with: sh tests/test_zram_logs.sh   (SH=bash or SH=dash picks the shell under test)
set -u
cd "$(dirname "$0")/.." || exit 1
SH=${SH:-sh}
passed=0
failed=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pods=$tmp/pods

# check NAME WANT_EXIT FIXED_STRING ARGS... : run the script, compare exit code and output
check() {
    name=$1
    want=$2
    pattern=$3
    shift 3
    out=$($SH ./zram-logs.sh "$@" 2>&1)
    got=$?
    if [ "$got" -eq "$want" ] && printf '%s\n' "$out" | grep -qF -- "$pattern"; then
        passed=$((passed + 1))
        echo "ok   - $name"
    else
        failed=$((failed + 1))
        echo "FAIL - $name (exit $got, want $want; expected output to contain: $pattern)"
        printf '%s\n' "$out" | sed 's/^/       /'
    fi
}

# Argument handling
check "no command" 2 "missing command"
check "unknown command" 2 "unknown command: frobnicate" frobnicate
check "help" 0 "Usage: zram-logs.sh COMMAND" --help
check "unknown option" 2 "unknown option: --bogus" plan --bogus
check "size needs a value" 2 "--size needs a value" plan --size
check "size without unit" 2 "invalid size '1024'" plan --size 1024
check "size with bad unit" 2 "invalid size '1T'" plan --size 1T
check "zero size" 2 "invalid size '0G'" plan --size 0G
check "relative mount point" 2 "must be an absolute path" plan --mount var/log/pods
check "root as mount point" 2 "refusing to use / as the mount point" plan --mount /

# plan: shows every step, changes nothing
check "plan header" 0 "mount point : $pods" plan --mount "$pods"
check "plan default size" 0 "size        : 1G" plan --mount "$pods"
check "plan creates missing dir" 0 "+ mkdir -p $pods" plan --mount "$pods"
check "plan sizes the device" 0 "+ zramctl --algorithm zstd|lz4 --size 512M /dev/zramN" \
    plan --mount "$pods" --size 512M
check "plan mkfs" 0 "+ mkfs.ext4 -q -m 0 -O ^has_journal -L zram-logs /dev/zramN" plan --mount "$pods"
check "plan mount" 0 "+ mount -o noatime,discard /dev/zramN $pods" plan --mount "$pods"
check "plan footer" 0 "No changes made." plan --mount "$pods" --size 2G
check "trailing slash stripped" 0 "mount point : $pods" plan --mount "$pods/"
if [ -e "$pods" ]; then
    failed=$((failed + 1))
    echo "FAIL - plan must not create $pods"
else
    passed=$((passed + 1))
    echo "ok   - plan changed nothing"
fi

mkdir "$pods"
chmod 750 "$pods"
# Some file systems (e.g. NTFS under Git Bash) ignore chmod; only check where it sticks.
if [ "$(stat -c %a "$pods")" = 750 ]; then
    check "plan keeps directory mode" 0 "+ chmod 750 $pods" plan --mount "$pods"
fi
check "plan keeps directory owner" 0 "+ chown $(id -u):$(id -g) $pods" plan --mount "$pods"

export ZRAM_LOGS_SIZE=256M
check "size from environment" 0 "size        : 256M" plan --mount "$pods"
unset ZRAM_LOGS_SIZE

# Guards that need no root to exercise
check "status when inactive" 3 "not active on $pods" status --mount "$pods"
check "remove when inactive" 0 "nothing to remove" remove --mount "$pods"
if [ "$(id -u)" -ne 0 ]; then
    check "apply needs root" 1 "'apply' must run as root" apply --mount "$pods"
fi

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
