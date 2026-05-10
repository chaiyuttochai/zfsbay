#!/usr/bin/env bash
# common.sh — logging, color, prompts, run_cmd, dependency check.
# Sourced by zfsbay; do not execute directly.
# shellcheck shell=bash

# Defaults (overridable by /etc/zfsbay.conf or env)
: "${PERCCLI:=}"
: "${DEFAULT_CONTROLLER:=0}"
: "${DEFAULT_ENCLOSURE:=}"
: "${LOG_FILE:=/var/log/zfsbay.log}"
: "${COLOR_HEALTH_GREEN_MIN:=80}"
: "${COLOR_HEALTH_YELLOW_MIN:=50}"
: "${COLOR_ENDURANCE_GREEN_MIN:=80}"
: "${COLOR_ENDURANCE_YELLOW_MIN:=50}"
: "${PREFER_ZFS_PATH_FORM:=auto}"
: "${DRY_RUN_DEFAULT:=0}"

# Colors — assigned by apply_flag_state. Read by ui.sh and workflows.sh.
# shellcheck disable=SC2034  # cross-module references
c_red=""; c_yellow=""; c_green=""; c_dim=""; c_bold=""; c_reset=""

# Internal state booleans (set by apply_flag_state)
ZB_USE_COLOR=0
ZB_DRY_RUN=0
ZB_VERBOSE=0
ZB_QUIET=0
ZB_JSON=0
ASSUME_YES=0

apply_flag_state() {
    ZB_DRY_RUN="${ZB_FLAGS[dry_run]}"
    ZB_VERBOSE="${ZB_FLAGS[verbose]}"
    ZB_QUIET="${ZB_FLAGS[quiet]}"
    ZB_JSON="${ZB_FLAGS[json]}"
    ASSUME_YES="${ZB_FLAGS[yes]}"
    [[ "${DRY_RUN_DEFAULT:-0}" = "1" ]] && ZB_DRY_RUN=1

    # Color decision
    if [[ "${ZB_FLAGS[no_color]}" = "1" ]] || [[ "${NO_COLOR:-0}" = "1" ]] || [[ "$ZB_JSON" = "1" ]]; then
        ZB_USE_COLOR=0
    elif [[ -t 1 ]]; then
        ZB_USE_COLOR=1
    else
        ZB_USE_COLOR=0
    fi

    if [[ "$ZB_USE_COLOR" = "1" ]]; then
        # shellcheck disable=SC2034  # all c_* vars are read by ui.sh / workflows.sh
        { c_red=$'\e[31m'; c_yellow=$'\e[33m'; c_green=$'\e[32m'
          c_dim=$'\e[2m'; c_bold=$'\e[1m'; c_reset=$'\e[0m'; }
    fi

    [[ -n "$ZB_CONTROLLER" ]] || ZB_CONTROLLER="$DEFAULT_CONTROLLER"
    [[ -n "$ZB_ENCLOSURE"  ]] || ZB_ENCLOSURE="$DEFAULT_ENCLOSURE"
}

load_config() {
    local f="$1"
    if [[ -z "$f" ]]; then
        if   [[ -r /etc/zfsbay.conf ]];  then f=/etc/zfsbay.conf
        elif [[ -r "$HOME/.zfsbay.conf" ]]; then f="$HOME/.zfsbay.conf"
        else return 0
        fi
    fi
    [[ -r "$f" ]] || die 2 "config not readable: $f"
    # shellcheck disable=SC1090  # config path is user-supplied at runtime
    source "$f"
    apply_flag_state  # re-apply in case config changed defaults
}

# ---- logging ---------------------------------------------------------------

_log_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_log_to_file() {
    local line="$1"
    [[ -n "${LOG_FILE:-}" ]] || return 0
    # Best-effort: silently skip if not writable.
    { printf '%s\n' "$line" >> "$LOG_FILE"; } 2>/dev/null || true
}

log_info()  {
    local msg="$1"; local line; line="$(_log_ts) INFO  $msg"
    [[ "$ZB_QUIET" = "1" ]] || [[ "$ZB_JSON" = "1" ]] || printf '%s\n' "$line" >&2
    _log_to_file "$line"
}
log_warn()  {
    local msg="$1"; local line; line="$(_log_ts) WARN  $msg"
    [[ "$ZB_JSON" = "1" ]] || printf '%s%s%s\n' "$c_yellow" "$line" "$c_reset" >&2
    _log_to_file "$line"
}
log_error() {
    local msg="$1"; local line; line="$(_log_ts) ERROR $msg"
    [[ "$ZB_JSON" = "1" ]] || printf '%s%s%s\n' "$c_red" "$line" "$c_reset" >&2
    _log_to_file "$line"
}
log_debug() {
    local msg="$1"; local line; line="$(_log_ts) DEBUG $msg"
    [[ "$ZB_VERBOSE" = "1" ]] && [[ "$ZB_JSON" != "1" ]] && printf '%s%s%s\n' "$c_dim" "$line" "$c_reset" >&2
    _log_to_file "$line"
}

die() {
    # die <exit_code> <message>
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

on_error() {
    local code="$1" line="$2"
    log_error "internal error: line $line exited $code"
}
trap 'on_error $? $LINENO' ERR

# ---- run_cmd: dry-run + verbose aware --------------------------------------

# run_cmd captures stdout, leaves stderr passthrough.
# usage: out="$(run_cmd cmd args...)" || rc=$?
#
# Read-only by contract — ALWAYS executes, even in dry-run mode. Read-only
# queries (perccli show, zpool status, smartctl -a) populate the in-memory
# state that the dry-run plan describes; if we skip them, planning itself
# breaks (e.g. resolve_bay can't autodetect the enclosure). State-changing
# commands must use run_cmd_state instead.
run_cmd() {
    if [[ "$ZB_VERBOSE" = "1" ]]; then
        printf '%s+ %s%s\n' "$c_dim" "$(_quote_cmd "$@")" "$c_reset" >&2
    fi
    _log_to_file "$(_log_ts) CMD   $(_quote_cmd "$@")"
    "$@"
}

# run_cmd_state: like run_cmd but ALWAYS skipped in dry-run mode (state-changing only).
run_cmd_state() {
    if [[ "$ZB_DRY_RUN" = "1" ]]; then
        printf '%s[dry-run] would run: %s%s\n' "$c_dim" "$(_quote_cmd "$@")" "$c_reset" >&2
        _log_to_file "$(_log_ts) DRYRUN $(_quote_cmd "$@")"
        return 0
    fi
    if [[ "$ZB_VERBOSE" = "1" ]]; then
        printf '%s+ %s%s\n' "$c_dim" "$(_quote_cmd "$@")" "$c_reset" >&2
    fi
    _log_to_file "$(_log_ts) CMD   $(_quote_cmd "$@")"
    "$@"
}

_quote_cmd() {
    # Best-effort shell-quoting for log/echo.
    local out=""
    local a
    for a in "$@"; do
        if [[ "$a" =~ [^a-zA-Z0-9_./:=@%+-] ]]; then
            out+=" '${a//\'/\'\\\'\'}'"
        else
            out+=" $a"
        fi
    done
    printf '%s' "${out# }"
}

# ---- prompts ---------------------------------------------------------------

confirm() {
    local q="$1"
    if [[ "$ASSUME_YES" = "1" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then
        log_error "ต้องการการยืนยัน แต่ stdin ไม่ใช่ terminal — ใช้ --yes ถ้าต้องการข้าม"
        return 1
    fi
    local ans
    printf '%s [y/N] ' "$q" >&2
    read -r ans || return 1
    case "${ans,,}" in y|yes) return 0 ;; *) return 1 ;; esac
}

# ---- dependency / root checks ----------------------------------------------

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die 4 "ต้องรันด้วย root / Detail: this operation requires root privileges"
    fi
}

# Resolve perccli64 path; sets global PERCCLI_BIN.
PERCCLI_BIN=""
resolve_perccli() {
    if [[ -n "$PERCCLI_BIN" ]]; then return 0; fi
    local candidates=(
        "${PERCCLI:-}"
        /opt/MegaRAID/perccli/perccli64
        /usr/sbin/perccli64
        /usr/local/sbin/perccli64
        /opt/MegaRAID/storcli/storcli64
        /usr/sbin/storcli64
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -n "$c" ]] || continue
        if [[ -x "$c" ]]; then PERCCLI_BIN="$c"; return 0; fi
    done
    if command -v perccli64 >/dev/null 2>&1; then
        PERCCLI_BIN="$(command -v perccli64)"; return 0
    fi
    if command -v storcli64 >/dev/null 2>&1; then
        PERCCLI_BIN="$(command -v storcli64)"; return 0
    fi
    return 1
}

check_deps() {
    local need_state="${1:-0}"  # 1 if running a state-changing op
    local missing=()
    local hard=(bash awk sed grep printf jq)
    local soft=(column udevadm lsblk zpool smartctl)
    local d
    for d in "${hard[@]}"; do command -v "$d" >/dev/null 2>&1 || missing+=("$d"); done
    if (( ${#missing[@]} > 0 )); then
        die 3 "ขาดเครื่องมือที่จำเป็น: ${missing[*]} / Detail: install via apt: apt install -y ${missing[*]}"
    fi
    local soft_missing=()
    for d in "${soft[@]}"; do command -v "$d" >/dev/null 2>&1 || soft_missing+=("$d"); done
    if (( ${#soft_missing[@]} > 0 )); then
        log_warn "เครื่องมือเสริมหายไป (บางคำสั่งจะใช้งานไม่ได้): ${soft_missing[*]}"
    fi
    if ! resolve_perccli; then
        log_warn "ไม่พบ perccli64 / storcli64 — คำสั่งที่เกี่ยวกับ PERC จะใช้งานไม่ได้ / Install: download Dell perccli from Dell support site"
    fi
    if [[ "$need_state" = "1" ]]; then require_root; fi
}

# Exit code constants (documentation only; callers pass numeric)
# 0 ok / 1 generic / 2 usage / 3 missing dep / 4 not root / 5 hardware / 6 zfs / 7 user abort
