#!/usr/bin/env bash
# Install zfsbay onto a Proxmox VE host (Debian-based).
# Idempotent: re-runs are safe.
#
# Flags:
#   --skip-perccli   don't try to install vendor/perccli/*.deb
#   -h, --help       this help
set -Eeuo pipefail

src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_PERCCLI=1
for arg in "$@"; do
    case "$arg" in
        --skip-perccli) INSTALL_PERCCLI=0 ;;
        -h|--help)
            sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *)  echo "install.sh: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

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
[[ -e /var/log/zfsbay.log ]] || : > /var/log/zfsbay.log
chmod 0640 /var/log/zfsbay.log 2>/dev/null || true

# ---- Bundled Dell PERCCLI (.deb) ------------------------------------------
# Auto-install vendor/perccli/*.deb on Debian-based hosts when:
#   - flag --skip-perccli not set
#   - perccli64 not already installed
#   - dpkg is available
#   - the .deb is present in the repo
PERCCLI_BIN="/opt/MegaRAID/perccli/perccli64"
if [[ "$INSTALL_PERCCLI" = "1" ]]; then
    if [[ -x "$PERCCLI_BIN" ]]; then
        echo "==> PERCCLI already installed at $PERCCLI_BIN — skipping"
    elif ! command -v dpkg >/dev/null 2>&1; then
        echo "==> dpkg not available — skipping PERCCLI install (RHEL? use vendor/perccli/*.rpm manually)"
    else
        deb=""
        for f in "$src_dir/vendor/perccli/"*.deb; do
            [[ -e "$f" ]] || continue
            deb="$f"; break
        done
        if [[ -z "$deb" ]]; then
            echo "==> No vendor/perccli/*.deb found — skipping (download from dell.com/support if needed)"
        else
            echo "==> Installing bundled PERCCLI: $(basename "$deb")"
            if dpkg -i "$deb"; then
                if [[ -x "$PERCCLI_BIN" ]]; then
                    echo "    PERCCLI installed at $PERCCLI_BIN"
                    # Wire it into /etc/zfsbay.conf if not already explicitly set.
                    if ! grep -qE '^\s*PERCCLI=' "$CONF_PATH"; then
                        printf 'PERCCLI=%q\n' "$PERCCLI_BIN" >> "$CONF_PATH"
                        echo "    Added PERCCLI=$PERCCLI_BIN to $CONF_PATH"
                    fi
                else
                    echo "    Warning: dpkg succeeded but $PERCCLI_BIN is missing"
                fi
            else
                echo "    Warning: dpkg -i returned non-zero — install vendor/perccli/*.deb manually"
            fi
        fi
    fi
fi

echo
echo "เสร็จเรียบร้อย — ลองรัน: zfsbay version"
