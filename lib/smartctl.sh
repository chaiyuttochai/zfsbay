#!/usr/bin/env bash
# smartctl.sh — wrappers + endurance/health attribute parsing.
# shellcheck shell=bash

# Cache for the megaraid SCSI generic device path.
SMART_MEGARAID_DEV=""

# smart_megaraid_dev — resolve the SCSI generic device to pass to smartctl
# for "megaraid,DID" addressing. Returns first /dev/bus/0 if present, else
# the first sg* whose driver is megaraid_sas, else /dev/sda.
smart_megaraid_dev() {
    if [[ -n "$SMART_MEGARAID_DEV" ]]; then printf '%s' "$SMART_MEGARAID_DEV"; return; fi
    if [[ -e /dev/bus/0 ]]; then SMART_MEGARAID_DEV=/dev/bus/0; printf '%s' "$SMART_MEGARAID_DEV"; return; fi
    local sg
    for sg in /sys/class/scsi_generic/sg*; do
        [[ -e "$sg" ]] || continue
        local drv_path="$sg/device/../driver"
        if [[ -L "$drv_path" ]]; then
            local drv
            drv="$(basename "$(readlink -f "$drv_path")")"
            if [[ "$drv" = "megaraid_sas" ]]; then
                SMART_MEGARAID_DEV="/dev/$(basename "$sg")"
                printf '%s' "$SMART_MEGARAID_DEV"; return
            fi
        fi
    done
    SMART_MEGARAID_DEV=/dev/sda
    printf '%s' "$SMART_MEGARAID_DEV"
}

# Per-call wall-clock cap for smartctl. Set ZFSBAY_SMART_TIMEOUT in env to
# override; 0 disables the cap. The default is conservative because smartctl
# on a drive behind PERC can stall for tens of seconds when the disk is in
# standby or the megaraid driver is queued.
: "${ZFSBAY_SMART_TIMEOUT:=8}"

_smart_with_timeout() {
    if (( ZFSBAY_SMART_TIMEOUT > 0 )) && command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=2 "${ZFSBAY_SMART_TIMEOUT}s" "$@" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

# smart_run_megaraid <DID> [smartctl-args...] -> stdout
# Tries SAT layered first (works for SATA SSDs behind PERC), then falls back to plain megaraid.
smart_run_megaraid() {
    local did="$1"; shift
    local dev; dev="$(smart_megaraid_dev)"
    local out
    out="$(_smart_with_timeout smartctl "$@" -d "sat+megaraid,${did}" "$dev" || true)"
    if printf '%s' "$out" | grep -qE 'Permission denied|Unknown USB bridge|Unable to detect device type|Smartctl open device|^$'; then
        out="$(_smart_with_timeout smartctl "$@" -d "megaraid,${did}" "$dev" || true)"
    elif [[ -z "$out" ]]; then
        out="$(_smart_with_timeout smartctl "$@" -d "megaraid,${did}" "$dev" || true)"
    fi
    printf '%s' "$out"
}

# smart_run_native <devnode> [smartctl-args...] -> stdout
smart_run_native() {
    local node="$1"; shift
    _smart_with_timeout smartctl "$@" "$node" || true
}

# smart_overall <text> -> "PASSED"|"FAILED"|"UNKNOWN"
smart_overall() {
    local text="$1"
    if   printf '%s' "$text" | grep -qE 'SMART overall-health.*:?\s*PASSED|SMART Health Status:\s*OK';   then printf 'PASSED'
    elif printf '%s' "$text" | grep -qE 'SMART overall-health.*:?\s*FAILED|SMART Health Status:\s*FAIL'; then printf 'FAILED'
    else printf 'UNKNOWN'
    fi
}

# smart_attr_value <text> <attr-id> -> normalized value (or empty)
smart_attr_value() {
    local text="$1" id="$2"
    printf '%s' "$text" \
        | awk -v id="$id" '
            $1 == id && NF >= 4 && $4 ~ /^[0-9]+$/ { print ($4 + 0); exit }
          '
}

smart_attr_raw() {
    local text="$1" id="$2"
    printf '%s' "$text" \
        | awk -v id="$id" '
            $1 == id && NF >= 10 { for(i=10;i<=NF;i++) printf "%s ", $i; print ""; exit }
          ' | sed 's/[[:space:]]*$//'
}

# smart_endurance_pct_sata <text> -> 0..100 or "N/A" or "?"
# Uses the priority order from the reference table.
smart_endurance_pct_sata() {
    local text="$1"
    local v
    # 231 SSD_Life_Left
    v="$(smart_attr_value "$text" 231)"; if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    # 233 Media_Wearout_Indicator  (some Crucial firmware reports 233 as Total_LBAs_Written
    # raw counter but normalized still tracks life; we trust the normalized value)
    v="$(smart_attr_value "$text" 233)"; if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    # 202 Percent_Lifetime_Remain
    v="$(smart_attr_value "$text" 202)"; if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    # 177 Wear_Leveling_Count (Samsung)
    v="$(smart_attr_value "$text" 177)"; if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    # 173 — vendor inconsistency: SanDisk reports % remaining (normalized=100 new),
    # Kingston some firmware reports % used. Heuristic: if value > 100, drop. Otherwise use.
    v="$(smart_attr_value "$text" 173)"; if [[ -n "$v" ]] && [[ "$v" =~ ^[0-9]+$ ]] && (( v <= 100 )); then printf '%s' "$v"; return; fi
    # 169 Remaining_Lifetime_Perc (Apple/Toshiba)
    v="$(smart_attr_value "$text" 169)"; if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
    printf '?'
}

# smart_endurance_pct_sas_ssd <text> -> percent left (100 - "Percentage Used Endurance Indicator")
# `text` should be the output of `smartctl -l ssd ...`
smart_endurance_pct_sas_ssd() {
    local text="$1"
    local used
    used="$(printf '%s' "$text" \
        | awk 'tolower($0) ~ /percentage[ _]used[ _]endurance[ _]indicator/ {
            n = split($0, parts, ":");
            if (n >= 2) {
                v = parts[2]; gsub(/[^0-9]/, "", v);
                if (v != "") { print v; exit }
            }
            match($0, /[0-9]+/); if(RSTART > 0) { print substr($0, RSTART, RLENGTH); exit }
        }')"
    if [[ -n "$used" ]]; then
        printf '%s' "$((100 - used))"
    else
        printf '?'
    fi
}

# smart_endurance_pct_nvme <smartctl-text-OR-nvme-smart-log-text>
smart_endurance_pct_nvme() {
    local text="$1"
    local used
    used="$(printf '%s' "$text" \
        | awk 'tolower($0) ~ /^percentage[ _]used/ {
            n = split($0, parts, ":");
            if (n >= 2) { v = parts[2]; gsub(/[^0-9]/, "", v); if (v != "") { print v; exit } }
            match($0, /[0-9]+/); if (RSTART > 0) { print substr($0, RSTART, RLENGTH); exit }
        }')"
    if [[ -n "$used" ]]; then
        printf '%s' "$((100 - used))"; return
    fi
    used="$(printf '%s' "$text" \
        | awk -F: '/percentage_used/ { gsub(/[^0-9]/, "", $2); if($2!="") { print $2; exit } }')"
    if [[ -n "$used" ]]; then
        printf '%s' "$((100 - used))"; return
    fi
    printf '?'
}

# smart_health_pct <text> [perc-pd-json]
# Computes the heuristic 0..100 health score.
smart_health_pct() {
    local text="$1" pd_json="${2:-}"
    local score=100 overall
    overall="$(smart_overall "$text")"
    if [[ "$overall" = "FAILED" ]]; then printf '0'; return; fi

    local realloc pending crc temp
    realloc="$(smart_attr_raw "$text" 5)"
    pending="$(smart_attr_raw "$text" 197)"
    crc="$(smart_attr_raw "$text" 199)"
    # Temp from raw col 10 of attr 194, NOT the normalized value (which is meaningless as celsius).
    temp="$(printf '%s' "$text" | awk '$1 == 194 && NF >= 10 { for(i=10;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }')"

    # Strip non-numerics from raw counters; default 0.
    realloc="${realloc//[^0-9]/}"; realloc="${realloc:-0}"
    pending="${pending//[^0-9]/}"; pending="${pending:-0}"
    crc="${crc//[^0-9]/}";         crc="${crc:-0}"

    (( realloc > 0 )) && score=$(( score - 20 ))
    (( pending > 0 )) && score=$(( score - 30 ))
    (( crc     > 100 )) && score=$(( score - 10 ))

    # SAS-style: "Elements in grown defect list: N"
    local grown
    grown="$(printf '%s' "$text" | awk -F: '/Elements in grown defect list/ { gsub(/[^0-9]/,"",$2); print $2; exit }')"
    if [[ -n "$grown" ]] && [[ "$grown" =~ ^[0-9]+$ ]] && (( grown > 0 )); then
        score=$(( score - 20 ))
    fi

    # Predictive failure
    if printf '%s' "$text" | grep -qiE 'predictive failure|warning.*temperature.*excessive|FAILING_NOW'; then
        score=$(( score - 50 ))
    fi

    if [[ -n "$pd_json" ]]; then
        local merr oerr pf
        merr="$(printf '%s' "$pd_json" | jq -r '."Media Error Count" // 0')"
        oerr="$(printf '%s' "$pd_json" | jq -r '."Other Error Count" // 0')"
        pf="$(  printf '%s' "$pd_json" | jq -r '."Predictive Failure Count" // 0')"
        merr="${merr//[^0-9]/}"; merr="${merr:-0}"
        oerr="${oerr//[^0-9]/}"; oerr="${oerr:-0}"
        pf="${pf//[^0-9]/}";     pf="${pf:-0}"
        (( merr > 0  )) && score=$(( score - 10 ))
        (( oerr > 10 )) && score=$(( score - 10 ))
        (( pf   > 0  )) && score=$(( score - 50 ))
    fi

    # Temperature: smartctl shows "Current Drive Temperature: 38 C" or attr 194.
    local cur_temp
    cur_temp="$(printf '%s' "$text" | awk -F: '/Current Drive Temperature/ { gsub(/[^0-9]/, "", $2); print $2; exit }')"
    [[ -n "$cur_temp" ]] || cur_temp="$temp"
    if [[ -n "$cur_temp" ]] && [[ "$cur_temp" =~ ^[0-9]+$ ]] && (( cur_temp > 60 )); then
        score=$(( score - 10 ))
    fi

    (( score < 0 )) && score=0
    printf '%s' "$score"
}

# smart_temperature <text> -> integer celsius or empty
smart_temperature() {
    local text="$1"
    local t
    t="$(printf '%s' "$text" | awk -F: '/Current Drive Temperature/ { gsub(/[^0-9]/,"",$2); print $2; exit }')"
    [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    printf '%s' "$text" | awk '
        $1 == 194 && NF >= 10 {
            # raw form often looks like "38 (Min/Max 25/45)" — first int wins
            for(i=10;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit }
        }'
}

smart_power_on_hours() {
    local text="$1"
    local v
    v="$(printf '%s' "$text" | awk -F: '/Accumulated power on time|number of hours powered up/ { gsub(/[^0-9.]/,"",$2); print $2; exit }')"
    [[ -n "$v" ]] && { printf '%s' "${v%.*}"; return; }
    printf '%s' "$text" | awk '
        $1 == 9 && NF >= 10 { for(i=10;i<=NF;i++) if ($i ~ /^[0-9]+$/) { print $i; exit } }'
}

smart_reallocated_sectors() {
    local v
    v="$(smart_attr_raw "$1" 5)"; v="${v//[^0-9]/}"; printf '%s' "${v:-0}"
}

smart_pending_sectors() {
    local v
    v="$(smart_attr_raw "$1" 197)"; v="${v//[^0-9]/}"; printf '%s' "${v:-0}"
}

# Endurance dispatcher — picks the right method by interface / media.
# args: <intf-SATA|SAS|NVMe|...> <media-HDD|SSD> <DID> [native_node]
smart_endurance_for_drive() {
    local intf="$1" media="$2" did="$3" native="${4:-}"
    case "${media^^}" in
        HDD) printf 'N/A'; return ;;
    esac
    case "${intf^^}" in
        SATA)
            local t; t="$(smart_run_megaraid "$did" -A 2>/dev/null)"
            smart_endurance_pct_sata "$t"
            ;;
        SAS)
            local t; t="$(smart_run_megaraid "$did" -l ssd 2>/dev/null)"
            smart_endurance_pct_sas_ssd "$t"
            ;;
        NVMe|NVME)
            if [[ -n "$native" ]] && [[ -e "$native" ]]; then
                local t; t="$(smart_run_native "$native" -a 2>/dev/null)"
                smart_endurance_pct_nvme "$t"
            else
                printf '?'
            fi
            ;;
        *) printf '?' ;;
    esac
}
