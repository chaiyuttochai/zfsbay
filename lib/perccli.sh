#!/usr/bin/env bash
# perccli.sh — wrappers and parsers for perccli64 / storcli64 (LSI MegaRAID).
# All command syntax verified against the reference table in zfsbay README.
# Sourced by zfsbay (which sources common.sh first); not run standalone.
# shellcheck shell=bash

# Cache populated by perccli_load_pds.
# PERCCLI_PD_JSON: raw JSON of `/cX/eall/sall show all J`
PERCCLI_PD_JSON=""
PERCCLI_VD_JSON=""
PERCCLI_FOREIGN_JSON=""

# perccli_run <args...>  -> stdout = perccli text/JSON output, rc = perccli rc.
# perccli64 returns 0 even on logical errors; callers must inspect output.
perccli_run() {
    [[ -n "$PERCCLI_BIN" ]] || die 5 "perccli64 ไม่ได้ติดตั้ง / Detail: install Dell perccli first"
    run_cmd "$PERCCLI_BIN" "$@"
}

# perccli_run_state — state-changing perccli call (skipped in dry-run).
perccli_run_state() {
    [[ -n "$PERCCLI_BIN" ]] || die 5 "perccli64 ไม่ได้ติดตั้ง / Detail: install Dell perccli first"
    run_cmd_state "$PERCCLI_BIN" "$@"
}

# perccli_load_pds [<controller>] — fetch PD JSON, populating PERCCLI_PD_JSON.
# Falls back to text-mode parsing if jq rejects JSON output.
perccli_load_pds() {
    local cN="${1:-$ZB_CONTROLLER}"
    if [[ -n "$PERCCLI_PD_JSON" ]] && [[ "${ZB_FLAGS[refresh]:-0}" != "1" ]]; then return 0; fi
    if [[ -z "$PERCCLI_BIN" ]]; then PERCCLI_PD_JSON=""; return 1; fi
    local out
    out="$(perccli_run "/c${cN}/eall/sall" show all J 2>/dev/null || true)"
    if [[ -z "$out" ]]; then PERCCLI_PD_JSON=""; return 1; fi
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        PERCCLI_PD_JSON="$out"
    else
        log_warn "perccli JSON parse failed; falling back to text mode (PERCCLI_PD_JSON empty)"
        PERCCLI_PD_JSON=""
        # Text fallback can be invoked via perccli_load_pds_text.
        return 1
    fi
}

# perccli_load_vds [<controller>]
perccli_load_vds() {
    local cN="${1:-$ZB_CONTROLLER}"
    if [[ -n "$PERCCLI_VD_JSON" ]] && [[ "${ZB_FLAGS[refresh]:-0}" != "1" ]]; then return 0; fi
    if [[ -z "$PERCCLI_BIN" ]]; then PERCCLI_VD_JSON=""; return 1; fi
    local out
    out="$(perccli_run "/c${cN}/vall" show all J 2>/dev/null || true)"
    if [[ -n "$out" ]] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        PERCCLI_VD_JSON="$out"
    else
        PERCCLI_VD_JSON=""
    fi
}

perccli_load_foreign() {
    local cN="${1:-$ZB_CONTROLLER}"
    if [[ -n "$PERCCLI_FOREIGN_JSON" ]] && [[ "${ZB_FLAGS[refresh]:-0}" != "1" ]]; then return 0; fi
    if [[ -z "$PERCCLI_BIN" ]]; then PERCCLI_FOREIGN_JSON=""; return 1; fi
    local out
    out="$(perccli_run "/c${cN}/fall" show J 2>/dev/null || true)"
    if [[ -n "$out" ]] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        PERCCLI_FOREIGN_JSON="$out"
    else
        PERCCLI_FOREIGN_JSON=""
    fi
}

# perccli_pd_array — emit the PD array from cached JSON (or empty array).
# Walks Controllers[].Response Data["Drive Information"] which is the standard schema
# for `/cN/eall/sall show all J` on perccli64 7.2x firmware.
perccli_pd_array() {
    [[ -n "$PERCCLI_PD_JSON" ]] || { printf '[]'; return; }
    printf '%s' "$PERCCLI_PD_JSON" | jq -c '
        [ (.Controllers // [])[]
          | (."Response Data" // {})
          | to_entries[]
          | select(.key | test("Drive Information"; "i"))
          | .value[]
        ]
    '
}

# perccli_vd_array — array of VD info objects across all controllers.
perccli_vd_array() {
    [[ -n "$PERCCLI_VD_JSON" ]] || { printf '[]'; return; }
    printf '%s' "$PERCCLI_VD_JSON" | jq -c '
        [ (.Controllers // [])[]
          | (."Response Data" // {})
          | to_entries[]
          | select(.key | test("VD LIST|Virtual Drives"; "i"))
          | .value[]?
        ]
    '
}

perccli_foreign_count() {
    [[ -n "$PERCCLI_FOREIGN_JSON" ]] || { printf '0'; return; }
    printf '%s' "$PERCCLI_FOREIGN_JSON" | jq -r '
        [ (.Controllers // [])[]
          | (."Response Data" // {})
          | to_entries[]
          | select(.key | test("foreign"; "i"))
          | .value
          | if type == "array" then length else 1 end
        ] | add // 0
    '
}

# perccli_pd_lookup_by_eid_slot <EID> <Slot>  -> JSON object or empty
perccli_pd_lookup_by_eid_slot() {
    local eid="$1" slot="$2"
    perccli_pd_array | jq -c --arg eid "$eid" --arg slot "$slot" '
        .[] | select( (."EID:Slt" // "") == ($eid + ":" + $slot) )
    ' | head -1
}

# perccli_pd_field <pd-json> <field> — pull a field with several possible key spellings.
perccli_pd_field() {
    local obj="$1" key="$2"
    printf '%s' "$obj" | jq -r --arg k "$key" '.[$k] // empty'
}

# perccli_default_enclosure — return enclosure id of the only non-empty enclosure
# on controller $ZB_CONTROLLER, or empty if ambiguous.
perccli_default_enclosure() {
    perccli_load_pds || { printf ''; return; }
    perccli_pd_array | jq -r '
        [ .[] | (."EID:Slt" // "") | split(":")[0] ]
        | unique
        | map(select(. != ""))
        | if length == 1 then .[0] else "" end
    '
}

perccli_count_controllers() {
    [[ -n "$PERCCLI_BIN" ]] || { printf '0'; return; }
    local out
    out="$(perccli_run show ctrlcount J 2>/dev/null || true)"
    if [[ -n "$out" ]] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$out" | jq -r '
            [.Controllers[]? | ."Response Data"?."Controller Count"?] | add // 0
        '
    else
        printf '0'
    fi
}

# ---- state-changing operations --------------------------------------------

perccli_locate_on()   { perccli_run_state "/c${1}/e${2}/s${3}" start locate; }
perccli_locate_off()  { perccli_run_state "/c${1}/e${2}/s${3}" stop  locate; }
perccli_set_offline() { perccli_run_state "/c${1}/e${2}/s${3}" set offline; }
perccli_set_online()  { perccli_run_state "/c${1}/e${2}/s${3}" set online;  }
perccli_set_good()    { perccli_run_state "/c${1}/e${2}/s${3}" set good force; }
perccli_set_jbod()    { perccli_run_state "/c${1}/e${2}/s${3}" set jbod; }
perccli_spindown()    { perccli_run_state "/c${1}/e${2}/s${3}" spindown; }
perccli_spinup()      { perccli_run_state "/c${1}/e${2}/s${3}" spinup; }
perccli_add_r0_vd()   { perccli_run_state "/c${1}" add vd r0 "drives=${2}:${3}"; }
perccli_clear_foreign() { perccli_run_state "/c${1}/fall" delete; }
perccli_show_rebuild() { perccli_run "/c${1}/e${2}/s${3}" show rebuild; }

# perccli_delete_vd_for_pd <c> <e> <s>
# Looks up the VD that contains the PD at e:s and deletes it.
perccli_delete_vd_for_pd() {
    local cN="$1" eid="$2" slot="$3"
    perccli_load_vds "$cN"
    local vd
    vd="$(perccli_vd_array | jq -r --arg es "${eid}:${slot}" '
        .[] | select((.PDs // [])[]?.["EID:Slt"]? == $es) | (.["DG/VD"] // empty)
    ' | head -1)"
    if [[ -z "$vd" ]]; then
        log_warn "ไม่พบ VD ที่ครอบคลุม PD ${eid}:${slot} — ข้ามการลบ VD"
        return 0
    fi
    # DG/VD is "0/3" form — VD index is after the slash.
    local vidx="${vd##*/}"
    perccli_run_state "/c${cN}/v${vidx}" del
}
