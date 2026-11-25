# zram-container-logs

Puts Kubernetes container logs on a compressed RAM disk (zram) to take log-write I/O off the
node's physical disk.

> Lab project: a clean-room reference implementation of a pattern I use at work. It contains no employer code or data.

## The problem

On nodes with slow or IOPS-limited disks, everything that writes competes for the same small
I/O budget. Container logs are a steady, never-ending writer: every line a pod prints ends up in
`/var/log/pods/...` on the node's disk. I have seen this on non-production Kubernetes clusters
where etcd was already timing out because of storage IOPS limits; container log writes added
to the node's disk I/O and made the pressure worse.

One mitigation that worked there: keep the most recent container logs in a small compressed RAM
disk, rotate them aggressively, and rely on the log shipper to get them off the node. Log
writes then cost RAM and a little CPU instead of disk I/O. This repository packages that as a
script, a systemd unit and an Ansible role.

**Read the trade-offs section before using this.** Logs on a RAM disk are gone after a reboot or
crash.

## What is in here

| Path | What it is |
| --- | --- |
| `zram-logs.sh` | POSIX shell tool: `plan`, `apply`, `status`, `remove` |
| `systemd/zram-container-logs.service` | Recreates the RAM disk at boot, before kubelet and the runtime |
| `systemd/zram-container-logs.env` | Size and mount point (installed as `/etc/default/zram-container-logs`) |
| `systemd/install.sh` | Installs the script, unit and config, enables the unit |
| `kubelet/kubelet-config-snippet.yaml` | `containerLogMaxSize` / `containerLogMaxFiles` sized for 1 GiB |
| `logrotate/zram-node-agents` | logrotate example for logs kubelet does not rotate |
| `roles/zram_container_logs/` | Ansible role doing the same for a fleet |
| `examples/site.yml` | Example playbook using the role |
| `tests/test_zram_logs.sh` | Shell tests (no root needed) |

## Quick start

Requirements on the node: Linux with the `zram` module, util-linux (`zramctl`, `findmnt`),
e2fsprogs (`mkfs.ext4`), systemd.

```sh
# 1. See exactly what would change (no root needed, changes nothing)
./zram-logs.sh plan --size 1G --mount /var/log/pods

# 2. Set kubelet log rotation to fit the device (see "Sizing log rotation")
#    and make sure your log shipper (e.g. Fluent Bit) is running on the node.

# 3. Install the boot-time unit; the RAM disk is created at the next reboot
sudo systemd/install.sh

# 4. Drain and reboot the node, then check
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
sudo reboot
sudo zram-logs.sh status
kubectl uncordon <node>
```

To switch a node without a reboot: drain it, stop kubelet and the container runtime, run
`sudo zram-logs.sh apply`, then start them again. `apply` refuses to run while kubelet,
containerd, CRI-O or docker is active (unless `--force`), because they would keep writing to
open files hidden underneath the new mount.

For a fleet, use the Ansible role:

```sh
ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory examples/site.yml
```

The role installs the script, unit and config and enables the unit. By default the change takes
effect at each node's next reboot. Set `zram_logs_start_now: true` only for nodes that are
already drained with kubelet and the runtime stopped. Variables are in
`roles/zram_container_logs/defaults/main.yml`. The role does not edit kubelet's config, because
where that lives differs between distributions; apply the kubelet snippet with whatever already
manages your kubelet configuration.

## Example output

Real output from running the script on my workstation (Git Bash on Windows, no zram). Because
`/var/log/pods` does not exist there, the plan includes `mkdir` and `root:root 755`; on a node
it copies the owner and mode of the existing directory instead.

```text
$ ./zram-logs.sh plan
Plan: zram-backed container logs
  mount point : /var/log/pods
  size        : 1G
  compression : zstd if the kernel supports it, else lz4
  filesystem  : ext4, no journal, label zram-logs, mounted noatime,discard
Steps:
  + modprobe zram
  + mkdir -p /var/log/pods
  + zramctl --find                  (first free device, shown here as /dev/zramN)
  + zramctl --algorithm zstd|lz4 --size 1G /dev/zramN
  + mkfs.ext4 -q -m 0 -O ^has_journal -L zram-logs /dev/zramN
  + mount -o noatime,discard /dev/zramN /var/log/pods
  + chown 0:0 /var/log/pods
  + chmod 755 /var/log/pods
No changes made.

$ ./zram-logs.sh apply
zram-logs: error: 'apply' must run as root

$ ./zram-logs.sh status; echo "exit=$?"
zram-logs: not active on /var/log/pods
exit=3
```

On a node where it is active, `status` prints the mount, `zramctl` columns `DATA` (bytes
stored), `COMPR` (compressed size) and `TOTAL` (RAM actually used, including metadata), and
`df -h` for the mount. `DATA / TOTAL` is the compression ratio you are really getting.

## How it works

`apply`:

1. Exits successfully if a zram device is already mounted on the target (idempotent), and refuses
   if something else is mounted there.
2. Checks for root, the required tools, that kubelet and the runtime are stopped, and loads the
   `zram` module (fails clearly if the kernel does not have it).
3. Records the owner, mode and (when SELinux is enabled) the security context of the existing
   directory.
4. `zramctl --find` gets a free device; the algorithm is `zstd` if listed in
   `/sys/block/zramN/comp_algorithm`, else `lz4`.
5. `mkfs.ext4` without a journal (the data does not survive a reboot, so a journal only costs RAM)
   and with no reserved blocks.
6. Mounts with `noatime,discard`. `discard` matters: when kubelet deletes a rotated log, ext4
   tells zram and the RAM is freed. Without it, deleted files keep using memory.
7. Restores owner, mode and SELinux context on the new mount point. If mkfs or mount fails, the
   zram device is reset.

`remove` unmounts and resets the device (also refusing while kubelet or the runtime is active).
`plan` is `apply` in dry-run mode: the same code path, printing each command instead of running
it, so the plan cannot drift from what `apply` does.

### Boot ordering

A RAM disk is empty after every boot, so it has to be recreated before anything writes container
logs. The unit is a `Type=oneshot` service with `RemainAfterExit=yes`:

- `RequiresMountsFor=/var/log` and `After=local-fs.target`: `/var/log` (often a separate file
  system) must be mounted before we mount on top of a directory inside it.
- `After=systemd-modules-load.service`: honours a `zram` entry in `/etc/modules-load.d` if you
  have one; otherwise the script loads the module itself.
- `Before=kubelet.service containerd.service crio.service docker.service`: the runtime writes
  the log files and kubelet creates the pod log directories, so both must start after the mount
  exists. `Before=` only orders; it does not pull those units in, and units that are not
  installed are ignored.
- On shutdown the order is reversed: `ExecStop` (`remove`) runs after kubelet and the runtime
  have stopped.

If the unit fails at boot, kubelet still starts and logs go to the physical disk as before. To
make kubelet refuse to start without the RAM disk instead, add a drop-in for kubelet with
`Requires=zram-container-logs.service`.

### Sizing log rotation

Kubelet rotates container logs itself. Per container it keeps at most `containerLogMaxFiles`
files of up to `containerLogMaxSize` each (older rotated files are gzip-compressed, so this is
an upper bound). The worst case for the whole node is therefore:

```text
containers on the node x containerLogMaxFiles x containerLogMaxSize  <=  usable space
```

Leave headroom, because kubelet checks sizes periodically (every 10 s by default) and a chatty
container can overshoot between checks, and rotated files exist uncompressed until kubelet
gzips them. With 25% headroom on a 1 GiB device:

```text
usable space         = 1024 MiB x 0.75          = 768 MiB

kubelet defaults     = 5 files x 10 MiB         = 50 MiB per container
                       768 MiB / 50 MiB         = 15 containers   -> too few for most nodes

this repo's snippet  = 3 files x 4 MiB          = 12 MiB per container
                       768 MiB / 12 MiB         = 64 containers
```

Count every container: init containers, sidecars, and the previous instance of a restarted
container (kubelet keeps its log for `kubectl logs --previous`). If your nodes run more
containers, make the device bigger or the files smaller, e.g. `3 x 2Mi` = 6 MiB fits 128.

The settings are in `kubelet/kubelet-config-snippet.yaml`. On OpenShift, set the same two
fields through a `KubeletConfig` resource instead of editing the file.

For logs kubelet does not rotate (for example node agents writing to a second RAM disk created
with `zram-logs.sh apply --mount /var/log/node-agents --size 256M`), use logrotate:
see `logrotate/zram-node-agents`. Do not point logrotate at `/var/log/pods`.

## Trade-offs and limitations

- **Logs are lost on reboot or node crash.** Everything on the RAM disk disappears, including the
  logs that would explain why a node crashed. Ship logs to a central store first (e.g. Fluent Bit
  to Elasticsearch/ELK or Graylog) and treat the node copy as a short buffer. Do not use this
  where node-local log retention is a requirement.
- **RAM is taken from pods.** zram only allocates memory for what is stored, but in the worst case
  a full 1 GiB device uses 1 GiB divided by the compression ratio, plus metadata. That memory is
  not visible to the scheduler: reserve it with kubelet's `systemReserved` memory so pods are not
  scheduled into it. Size carefully on small nodes.
- **Short retention.** With 12 MiB per container, a noisy container keeps only minutes of logs on
  the node. `kubectl logs` shows only what is still there.
- **CPU for compression.** zstd compresses better, lz4 is cheaper on CPU. The script prefers zstd.
- **Mounting over a directory hides its old contents** (they stay on disk underneath, unused).
  That is why `apply` wants kubelet and the runtime stopped.
- **This reduces I/O; it does not fix slow storage.** If etcd or workloads need more IOPS than the
  disk provides, this only buys headroom. Measure the disk (for etcd, see my `etcd-disk-check`).
- Alternatives: `systemd-zram-generator` can create zram devices declaratively but is aimed at
  swap and `/tmp`; a plain `tmpfs` is simpler but uncompressed.

## Verification

CI (`.github/workflows/ci.yml`) runs shellcheck on all scripts, the shell tests under both `dash`
and `bash`, `systemd-analyze verify` on the unit, yamllint on the role and examples, and
`ansible-playbook --syntax-check`. The tests cover argument handling, `plan` output and the
non-root guards. `apply` and `remove` need root and a zram-capable kernel, so they are not
exercised in CI; try them on a disposable VM first.

```sh
sh tests/test_zram_logs.sh
```

## License

MIT
