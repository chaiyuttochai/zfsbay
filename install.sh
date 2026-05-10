#!/usr/bin/env bash
# Install zfsbay onto a Proxmox VE 8 host.
# Idempotent: re-runs are safe.
set -Eeuo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ต้องรันด้วย root: sudo ./install.sh" >&2
    exit 4
fi

LIB_DIR="/usr/local/lib/zfsbay"
BIN_PATH="/usr/local/sbin/zfsbay"
CONF_PATH="/etc/zfsbay.conf"
COMP_PATH="/etc/bash_completion.d/zfsbay"

echo "==> Installing libraries to $LIB_DIR"
install -d -m 0755 "$LIB_DIR"
install -m 0644 "$src_dir/lib/"*.sh "$LIB_DIR/"

echo "==> Installing entrypoint to $BIN_PATH"
install -m 0755 "$src_dir/zfsbay" "$BIN_PATH"

echo "==> Installing config to $CONF_PATH (if missing)"
if [[ ! -e "$CONF_PATH" ]]; then
    install -m 0644 "$src_dir/etc/zfsbay.conf.example" "$CONF_PATH"
else
    echo "    (existing $CONF_PATH preserved)"
fi

echo "==> Installing bash completion to $COMP_PATH"
install -d -m 0755 "$(dirname "$COMP_PATH")"
install -m 0644 "$src_dir/completions/zfsbay.bash" "$COMP_PATH"

echo "==> Touching log file /var/log/zfsbay.log"
: > /var/log/zfsbay.log
chmod 0640 /var/log/zfsbay.log || true

echo
echo "เสร็จเรียบร้อย — ลองรัน: zfsbay version"
