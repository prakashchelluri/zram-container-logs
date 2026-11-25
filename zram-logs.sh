#!/bin/sh
# zram-logs.sh - put Kubernetes container logs on a compressed RAM disk (zram)
# so that log writes stop generating I/O on the node's physical disk.
#
# Usage: zram-logs.sh {plan|apply|status|remove} [--size SIZE] [--mount PATH] [--force]
# Defaults can also come from the environment (used by the systemd unit):
#   ZRAM_LOGS_SIZE   (default 1G)
#   ZRAM_LOGS_MOUNT  (default /var/log/pods)
set -eu

SIZE=${ZRAM_LOGS_SIZE:-1G}
MOUNT=${ZRAM_LOGS_MOUNT:-/var/log/pods}
LABEL=zram-logs
FORCE=0
DRY_RUN=0
# Writers of /var/log/pods. Mounting over the directory while they run would
# leave them writing to files that are hidden under the new mount.
RUNTIME_UNITS="kubelet containerd crio docker"

usage() {
    cat <<EOF
Usage: zram-logs.sh COMMAND [options]

Commands:
  plan     show what 'apply' would do, change nothing (no root needed)
  apply    create the zram device, mkfs ext4 and mount it (idempotent)
  status   show the mount and zram compression stats (exit 3 if not active)
  remove   unmount and reset the zram device (logs on it are lost)

Options:
  --size SIZE    zram device size, e.g. 512M (default: 1G or \$ZRAM_LOGS_SIZE)
  --mount PATH   mount point (default: /var/log/pods or \$ZRAM_LOGS_MOUNT)
  --force        run apply/remove even if kubelet or a container runtime is active
  -h, --help     show this help
EOF
}

die() {
    echo "zram-logs: error: $*" >&2
    exit 1
}

usage_error() {
    echo "zram-logs: $*" >&2
    usage >&2
    exit 2
}

log() {
    echo "zram-logs: $*"
}

# Print the command in plan mode, run it otherwise.
run() {
    if [ "$DRY_RUN" = 1 ]; then
        echo "  + $*"
    else
        "$@"
    fi
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "'$1' must run as root"
}

need_tools() {
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || die "required command not found: $tool"
    done
}

# Source device mounted exactly on $MOUNT, or empty.
mounted_source() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o SOURCE --mountpoint "$MOUNT" 2>/dev/null || true
    fi
}

active_runtimes() {
    command -v systemctl >/dev/null 2>&1 || return 0
    for unit in $RUNTIME_UNITS; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf '%s ' "$unit"
        fi
    done
}

check_runtimes_stopped() {
    running=$(active_runtimes)
    [ -z "$running" ] && return 0
    if [ "$FORCE" = 1 ]; then
        log "warning: active: ${running}(continuing because of --force)"
    elif [ "$DRY_RUN" = 1 ]; then
        echo "  ! active: ${running}- apply would refuse; drain the node and stop them first"
    else
        die "active: ${running}- drain the node and stop them first, or use --force"
    fi
}

check_module() {
    if [ -d /sys/module/zram ]; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "  + modprobe zram"
        return 0
    fi
    modprobe zram 2>/dev/null || die "zram kernel module is not available (modprobe zram failed)"
}

# Pick zstd if the kernel offers it, else lz4. The list looks like "lzo lz4 [zstd]".
pick_algorithm() {
    algs=" $(tr -d '[]' <"/sys/block/$1/comp_algorithm") "
    case $algs in
        *" zstd "*) echo zstd ;;
        *" lz4 "*) echo lz4 ;;
        *) die "kernel zram supports neither zstd nor lz4 (has:$algs)" ;;
    esac
}

cmd_apply() {
    src=$(mounted_source)
    case $src in
        /dev/zram*)
            log "already applied: $src is mounted on $MOUNT"
            return 0
            ;;
        "") ;;
        *) die "$MOUNT is already a mount point for $src; refusing to mount over it" ;;
    esac

    if [ "$DRY_RUN" = 1 ]; then
        echo "Plan: zram-backed container logs"
        echo "  mount point : $MOUNT"
        echo "  size        : $SIZE"
        echo "  compression : zstd if the kernel supports it, else lz4"
        echo "  filesystem  : ext4, no journal, label $LABEL, mounted noatime,discard"
        echo "Steps:"
    else
        need_root apply
        need_tools zramctl mkfs.ext4 findmnt mount stat
    fi

    check_runtimes_stopped
    check_module

    if [ -d "$MOUNT" ]; then
        owner=$(stat -c '%u:%g' "$MOUNT")
        mode=$(stat -c '%a' "$MOUNT")
    else
        owner=0:0
        mode=755
        run mkdir -p "$MOUNT"
    fi
    selinux_ctx=""
    if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled && [ -d "$MOUNT" ]; then
        selinux_ctx=$(stat -c '%C' "$MOUNT")
    fi

    if [ "$DRY_RUN" = 1 ]; then
        dev=/dev/zramN
        echo "  + zramctl --find                  (first free device, shown here as $dev)"
        echo "  + zramctl --algorithm zstd|lz4 --size $SIZE $dev"
    else
        dev=$(zramctl --find)
        alg=$(pick_algorithm "${dev#/dev/}")
        zramctl --algorithm "$alg" --size "$SIZE" "$dev"
    fi

    # No journal: the data does not survive a reboot anyway, so journalling
    # would only cost RAM and CPU. 'discard' frees zram memory when rotated
    # log files are deleted.
    if ! run mkfs.ext4 -q -m 0 -O ^has_journal -L "$LABEL" "$dev"; then
        zramctl --reset "$dev"
        die "mkfs.ext4 failed on $dev"
    fi
    if ! run mount -o noatime,discard "$dev" "$MOUNT"; then
        zramctl --reset "$dev"
        die "mount of $dev on $MOUNT failed"
    fi
    run chown "$owner" "$MOUNT"
    run chmod "$mode" "$MOUNT"
    if [ -n "$selinux_ctx" ]; then
        run chcon "$selinux_ctx" "$MOUNT"
    fi

    if [ "$DRY_RUN" = 1 ]; then
        echo "No changes made."
    else
        log "mounted $dev ($alg, $SIZE) on $MOUNT"
    fi
}

cmd_status() {
    src=$(mounted_source)
    case $src in
        /dev/zram*) ;;
        *)
            echo "zram-logs: not active on $MOUNT"
            return 3
            ;;
    esac
    echo "zram-logs: active, $src mounted on $MOUNT"
    zramctl --output NAME,ALGORITHM,DISKSIZE,DATA,COMPR,TOTAL "$src"
    df -h "$MOUNT"
}

cmd_remove() {
    src=$(mounted_source)
    case $src in
        /dev/zram*) ;;
        "")
            log "nothing to remove: $MOUNT is not a mount point"
            return 0
            ;;
        *) die "$MOUNT is mounted from $src, not zram; refusing to touch it" ;;
    esac
    need_root remove
    check_runtimes_stopped
    umount "$MOUNT"
    zramctl --reset "$src"
    log "unmounted $MOUNT and reset $src (its logs are gone)"
}

[ $# -gt 0 ] || usage_error "missing command"
cmd=$1
shift
case $cmd in
    plan | apply | status | remove) ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) usage_error "unknown command: $cmd" ;;
esac

while [ $# -gt 0 ]; do
    case $1 in
        --size)
            [ $# -ge 2 ] || usage_error "--size needs a value"
            SIZE=$2
            shift 2
            ;;
        --mount)
            [ $# -ge 2 ] || usage_error "--mount needs a value"
            MOUNT=$2
            shift 2
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown option: $1" ;;
    esac
done

printf '%s\n' "$SIZE" | grep -Eq '^[1-9][0-9]*[KMG]$' ||
    usage_error "invalid size '$SIZE' (expected a number with K, M or G suffix, e.g. 1G)"
case $MOUNT in
    /) usage_error "refusing to use / as the mount point" ;;
    /*) MOUNT=${MOUNT%/} ;;
    *) usage_error "mount point must be an absolute path: $MOUNT" ;;
esac

case $cmd in
    plan)
        DRY_RUN=1
        cmd_apply
        ;;
    apply) cmd_apply ;;
    status) cmd_status ;;
    remove) cmd_remove ;;
esac
