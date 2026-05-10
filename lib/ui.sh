#!/usr/bin/env bash
# ui.sh — table rendering, progress bars, color thresholds.
# Sourced by zfsbay; relies on c_* color vars set in common.sh::apply_flag_state.
# shellcheck shell=bash
# c_red/c_yellow/c_green/c_dim/c_bold/c_reset come from common.sh.
# shellcheck disable=SC2154

# colorize_pct <value> <green_min> <yellow_min>
#   value=N/A or ?  -> dim
#   value>=green    -> green
#   value>=yellow   -> yellow
#   else            -> red
colorize_pct() {
    local v="$1" gmin="$2" ymin="$3"
    case "$v" in
        N/A|n/a|"?"|"-"|"")
            printf '%s%s%s' "$c_dim" "$v" "$c_reset"; return ;;
    esac
    if ! [[ "$v" =~ ^-?[0-9]+$ ]]; then
        printf '%s' "$v"; return
    fi
    if   (( v >= gmin )); then printf '%s%s%s' "$c_green"  "$v" "$c_reset"
    elif (( v >= ymin )); then printf '%s%s%s' "$c_yellow" "$v" "$c_reset"
    else                       printf '%s%s%s' "$c_red"    "$v" "$c_reset"
    fi
}

colorize_health()    { colorize_pct "$1" "$COLOR_HEALTH_GREEN_MIN"     "$COLOR_HEALTH_YELLOW_MIN"; }
colorize_endurance() { colorize_pct "$1" "$COLOR_ENDURANCE_GREEN_MIN"  "$COLOR_ENDURANCE_YELLOW_MIN"; }

# colorize_state <state>
colorize_state() {
    local s="$1"
    case "$s" in
        Onln|ONLINE)                    printf '%s%s%s' "$c_green"  "$s" "$c_reset" ;;
        Offln|OFFLINE)                  printf '%s%s%s' "$c_yellow" "$s" "$c_reset" ;;
        UGood|JBOD|AVAIL)               printf '%s%s%s' "$c_dim"    "$s" "$c_reset" ;;
        UBad|FAULTED|Failed|UNAVAIL)    printf '%s%s%s' "$c_red"    "$s" "$c_reset" ;;
        DEGRADED|Rbld|Frgn|Msng)        printf '%s%s%s' "$c_yellow" "$s" "$c_reset" ;;
        *)                              printf '%s' "$s" ;;
    esac
}

# render_table — read tab-separated rows on stdin (first row = header), print aligned.
render_table() {
    if command -v column >/dev/null 2>&1; then
        column -t -s $'\t'
    else
        # Fallback: best-effort using awk.
        awk -F'\t' '{ for(i=1;i<=NF;i++) printf "%-20s", $i; print "" }'
    fi
}

# format_bytes <integer-bytes>  -> human readable
format_bytes() {
    local b="${1:-0}"
    if ! [[ "$b" =~ ^[0-9]+$ ]]; then printf '%s' "$b"; return; fi
    awk -v b="$b" 'BEGIN{
        split("B K M G T P", u);
        i=1; while (b >= 1024 && i < 6) { b/=1024; i++ }
        if (i==1) printf "%d%s", b, u[i]; else printf "%.1f%s", b, u[i];
    }'
}

# format_eta_seconds <seconds> -> HH:MM:SS
format_eta_seconds() {
    local s="${1:-0}"
    if ! [[ "$s" =~ ^[0-9]+$ ]]; then printf '%s' "$s"; return; fi
    printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# progress_bar <pct> [width]
progress_bar() {
    local pct="$1" width="${2:-20}"
    if ! [[ "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf '[%*s]' "$width" ""
        return
    fi
    local filled
    filled=$(awk -v p="$pct" -v w="$width" 'BEGIN{ f=int(p*w/100); if(f<0)f=0; if(f>w)f=w; print f }')
    local i bar=""
    for ((i=0; i<filled; i++))           do bar+="#"; done
    for ((i=filled; i<width; i++))       do bar+="."; done
    printf '[%s]' "$bar"
}
