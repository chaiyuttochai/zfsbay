#!/usr/bin/env bash
# zfs.sh — wrappers for zpool/zfs and parsers for `zpool status` output.
# shellcheck shell=bash

# zfs_pool_list -> tab-separated rows: name size alloc free health frag cap
zfs_pool_list() {
    if ! command -v zpool >/dev/null 2>&1; then return 0; fi
    zpool list -H -o name,size,alloc,free,health,frag,cap 2>/dev/null || true
}

# zfs_pool_names -> one pool name per line
zfs_pool_names() {
    if ! command -v zpool >/dev/null 2>&1; then return 0; fi
    zpool list -H -o name 2>/dev/null || true
}

# zfs_pool_status_text [<pool>] -> raw `zpool status -P -v` output
zfs_pool_status_text() {
    local pool="${1:-}"
    if ! command -v zpool >/dev/null 2>&1; then return 0; fi
    if [[ -n "$pool" ]]; then
        zpool status -P -v "$pool" 2>/dev/null || true
    else
        zpool status -P -v 2>/dev/null || true
    fi
}

# zfs_pool_ashift <pool>
zfs_pool_ashift() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    zpool get -H -o value ashift "$p" 2>/dev/null || true
}

# zfs_parse_resilver <text> -> tab-separated: in_progress<TAB>percent<TAB>eta_seconds<TAB>scanned_bytes<TAB>total_bytes<TAB>rate_bps
# in_progress is 0/1. Empty fields are "" (not "0").
# Designed to handle several phrasings observed in OpenZFS 0.8 / 2.0 / 2.2.
zfs_parse_resilver() {
    local text="$1"
    awk '
        BEGIN {
            in_progress = 0; pct = ""; eta_sec = "";
            scanned_b = ""; total_b = ""; rate_bps = "";
        }
        function to_bytes(v, unit) {
            unit = toupper(unit); v += 0
            if (unit == "B" || unit == "")    return int(v)
            if (unit ~ /^K/)  return int(v * 1024)
            if (unit ~ /^M/)  return int(v * 1024 * 1024)
            if (unit ~ /^G/)  return int(v * 1024 * 1024 * 1024)
            if (unit ~ /^T/)  return int(v * 1024 * 1024 * 1024 * 1024)
            if (unit ~ /^P/)  return int(v * 1024 * 1024 * 1024 * 1024 * 1024)
            return int(v)
        }
        function parse_eta(s,    parts, n) {
            n = split(s, parts, ":")
            if (n == 3) return parts[1] * 3600 + parts[2] * 60 + parts[3]
            return 0
        }
        /resilver in progress/  { in_progress = 1 }
        /resilvered/ {
            # phrasings:  "45.6G resilvered, 12.34% done, 03:14:15 to go"
            #             "X resilvered, 12.34% done, no estimated completion time"
            for (i=1; i<=NF; i++) {
                if ($i ~ /%$/)        { tmp = $i; sub(/%/, "", tmp); pct = tmp }
                if ($i ~ /^[0-9]{1,3}:[0-9]{2}:[0-9]{2}$/) {
                    eta_sec = parse_eta($i)
                }
            }
        }
        /scanned at|issued at|scanned/ {
            # OpenZFS 2.x:  "1.23T scanned at 234M/s, 567G issued at 89M/s, 2.34T total"
            # OpenZFS 0.8:  "1.23T scanned out of 2.34T at 234M/s, 03:14:15 to go"
            # OpenZFS 2.2:  "900G / 2.34T scanned, 458G / 2.34T issued at 89M/s"
            for (i=1; i<=NF; i++) {
                token = $i; nxt = (i < NF ? $(i+1) : "")
                lastch = substr(token, length(token), 1)
                # Prefix-form: "1.23T scanned"
                if (token ~ /^[0-9.]+[KMGTPB]?$/ && nxt ~ /^scanned/)           { scanned_b = to_bytes(token, lastch) }
                if (token ~ /^[0-9.]+[KMGTPB]?$/ && nxt == "total")             { total_b   = to_bytes(token, lastch) }
                # "of <total>"
                if (token == "of" && nxt ~ /^[0-9.]+[KMGTPB]?$/)                { total_b   = to_bytes(nxt, substr(nxt, length(nxt), 1)) }
                # "/  <total>" (2.2 form)
                if (token == "/" && nxt ~ /^[0-9.]+[KMGTPB]?$/ && total_b == "") { total_b   = to_bytes(nxt, substr(nxt, length(nxt), 1)) }
                # rate in form "234M/s" preceded by "at"
                if (token ~ /^[0-9.]+[KMGTPB]?\/s,?$/ && i > 1 && $(i-1) == "at") {
                    r = token; sub(/\/s.*/, "", r); u = substr(r, length(r), 1)
                    rate_bps = to_bytes(r, u)
                }
                # ETA HH:MM:SS appearing on same line (only set if not already from "% done" line)
                if (token ~ /^[0-9]{1,3}:[0-9]{2}:[0-9]{2}$/ && eta_sec == "") {
                    eta_sec = parse_eta(token)
                }
            }
        }
        /no estimated completion time/ { eta_sec = "" }
        END {
            # Use | as separator: tab is treated as IFS-whitespace by bash and
            # collapses consecutive empty fields, which we need to preserve.
            printf "%d|%s|%s|%s|%s|%s\n", in_progress, pct, eta_sec, scanned_b, total_b, rate_bps
        }
    ' <<< "$text"
}

# zfs_pool_state <text> -> ONLINE / DEGRADED / FAULTED / etc.
zfs_pool_state() {
    local text="$1"
    awk '/^ *state:/ { print $2; exit }' <<< "$text"
}

# zfs_parse_vdevs <text> -> rows: indent<TAB>name<TAB>state<TAB>read<TAB>write<TAB>cksum<TAB>note
# `note` captures suffix annotations like "(resilvering)" or "(awaiting resilver)".
zfs_parse_vdevs() {
    local text="$1"
    awk '
        BEGIN { in_config = 0 }
        /^ *config:/        { in_config = 1; next }
        /^ *errors:/        { in_config = 0; next }
        in_config && NF >= 5 && $1 != "NAME" {
            # Match indent (leading spaces) before $1
            indent = match($0, /[^ \t]/) - 1
            if (indent < 1) { in_config = (NF == 0 ? in_config : in_config); next }
            name = $1; state = $2; r = $3; w = $4; c = $5
            note = ""
            for (i=6; i<=NF; i++) note = (note ? note " " : "") $i
            printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", indent, name, state, r, w, c, note
        }
    ' <<< "$text"
}

# zfs_pool_for_device <device-by-id-or-path> -> pool name (empty if not in any pool)
# Strategy: scan all pools' status output for an exact path match.
zfs_pool_for_device() {
    local dev="$1" pool
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        local txt; txt="$(zfs_pool_status_text "$pool")"
        if printf '%s' "$txt" | awk -v d="$dev" '
            /^ *config:/  { inblk=1; next }
            /^ *errors:/  { inblk=0 }
            inblk && $1 == d { found=1; exit }
            END           { exit !found }
        '; then
            printf '%s' "$pool"
            return 0
        fi
    done < <(zfs_pool_names)
    return 0
}

# zfs_vdev_for_device <device> -> name of parent vdev (mirror-N, raidzN-N, etc.)
# Walks the indented vdev tree.
zfs_vdev_for_device() {
    local dev="$1" pool="$2"
    local txt; txt="$(zfs_pool_status_text "$pool")"
    awk -v d="$dev" '
        /^ *config:/ { inblk=1; next }
        /^ *errors:/ { inblk=0 }
        inblk {
            indent = match($0, /[^ \t]/) - 1
            if (indent < 1) next
            if ($1 == d)  { print parent; exit }
            # Parent vdev names: mirror-N, raidzN-N, draid*, spare-N, replacing-N, log, cache, special, dedup
            if (indent <= 4 && $1 ~ /^(mirror|raidz[0-9]?|draid|spare|replacing|log|cache|special|dedup)/) {
                parent = $1
            }
        }
    ' <<< "$txt"
}

# zfs_count_healthy_children <pool> <vdev>
# Counts non-FAULTED/UNAVAIL children of named parent vdev.
zfs_count_healthy_children() {
    local pool="$1" vdev="$2"
    local txt; txt="$(zfs_pool_status_text "$pool")"
    awk -v v="$vdev" '
        /^ *config:/ { inblk=1; next }
        /^ *errors:/ { inblk=0 }
        inblk {
            indent = match($0, /[^ \t]/) - 1
            if (indent < 1) next
            if ($1 == v)        { in_v = 1; v_indent = indent; next }
            if (in_v && indent <= v_indent) { in_v = 0 }
            if (in_v && indent > v_indent && $2 ~ /^(ONLINE|DEGRADED)$/) cnt++
        }
        END { print cnt+0 }
    ' <<< "$txt"
}

# zfs_vdev_redundancy_floor <vdev-name>  -> minimum healthy children before data loss
# (i.e. resulting redundancy = healthy - floor).
# mirror needs ≥1, raidz1 needs ≥(N-1) but always ≥2 children, raidz2 ≥(N-2)... we keep it simple:
# returns the smallest count below which an additional removal is fatal.
zfs_vdev_min_after_remove() {
    local v="$1"
    case "$v" in
        mirror*)    printf '1' ;;     # need at least 1 left after removal
        raidz1*)    printf '2' ;;     # raidz1 tolerates 1 missing; after offline+remove must keep N-1
        raidz2*)    printf '3' ;;
        raidz3*)    printf '4' ;;
        draid1*)    printf '2' ;;
        draid2*)    printf '3' ;;
        draid3*)    printf '4' ;;
        replacing*|spare*) printf '1' ;;
        *)          printf '1' ;;
    esac
}

# ---- state-changing wrappers ----------------------------------------------

zfs_offline() { run_cmd_state zpool offline "$1" "$2"; }
zfs_online()  { run_cmd_state zpool online  "$1" "$2"; }
zfs_replace() {
    if [[ $# -eq 3 ]]; then run_cmd_state zpool replace "$1" "$2" "$3"
    else                    run_cmd_state zpool replace "$1" "$2"
    fi
}
zfs_attach()  { run_cmd_state zpool attach  "$1" "$2" "$3"; }
zfs_add_spare() { run_cmd_state zpool add "$1" spare "$2"; }
zfs_remove()  { run_cmd_state zpool remove "$1" "$2"; }
zfs_clear()   { run_cmd_state zpool clear  "$1"; }
