#!/bin/sh
# Install zram-logs.sh and its systemd unit so the RAM disk is recreated at
# every boot before kubelet and the container runtime start.
# It only enables the unit; the RAM disk is created at the next boot (or run
# 'systemctl start zram-container-logs' on a drained node with kubelet stopped).
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "install.sh: must run as root" >&2
    exit 1
}
here=$(cd "$(dirname "$0")" && pwd)

install -m 0755 "$here/../zram-logs.sh" /usr/local/sbin/zram-logs.sh
install -m 0644 "$here/zram-container-logs.service" /etc/systemd/system/zram-container-logs.service
# Keep an existing config file: it may hold a size tuned for this node.
if [ ! -e /etc/default/zram-container-logs ]; then
    install -m 0644 "$here/zram-container-logs.env" /etc/default/zram-container-logs
fi
systemctl daemon-reload
systemctl enable zram-container-logs.service
echo "install.sh: enabled zram-container-logs.service (active from next boot)"
