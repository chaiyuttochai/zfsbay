#!/usr/bin/env bash
# workflows.sh — orchestration for the user-facing subcommands.
# Sourced by zfsbay; depends on common.sh, ui.sh, perccli.sh, smartctl.sh,
# zfs.sh, mapping.sh.
# shellcheck shell=bash
# Cross-module color/state vars come from common.sh / mapping.sh.
# shellcheck disable=SC2154,SC2034

# ---- helpers ---------------------------------------------------------------

# rpool detection — returns 0 if device-path is part of the boot/rpool.
is_rpool_device() {
    local dev="$1"
    [[ -n "$dev" ]] || return 1
    if command -v proxmox-boot-tool >/dev/null 2>&1; then
        local out; out="$(proxmox-boot-tool status 2>/dev/null || true)"
        if printf '%s' "$out" | grep -Fq "$dev"; then return 0; fi
    fi
    # Fall back: compare against rpool's vdev paths.
    local pool="${MAP_POOL[${1:-__none__}]:-}"
    [[ "$pool" = "rpool" ]] && return 0 || return 1
}

# wait_for_device <wwn> <serial> <timeout-seconds>
# Polls /dev/disk/by-id and returns 0 if a matching device appears.
# Outputs the matched device path on stdout.
wait_for_device() {
    local wwn="$1" serial="$2" timeout="${3:-60}"
    local elapsed=0 found=""
    if command -v udevadm >/dev/null 2>&1; then
        run_cmd_state udevadm settle --timeout=10 >/dev/null || true
    fi
    while (( elapsed < timeout )); do
        # Refresh kernel-side maps each loop.
        DEV_BY_WWN=(); DEV_BY_SERIAL=(); BYID_FOR_DEV=()
        maps_load_devices
        local norm; norm="$(_strip_wwn "$wwn")"
        if [[ -n "$norm" ]]; then
            found="${DEV_BY_WWN[$norm]:-}"
            [[ -z "$found" ]] && found="${DEV_BY_WWN[${norm:0:16}]:-}"
        fi
        if [[ -z "$found" ]] && [[ -n "$serial" ]]; then
            found="${DEV_BY_SERIAL[$serial]:-}"
        fi
        if [[ -n "$found" ]]; then printf '%s' "$found"; return 0; fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
    done
    return 1
}

# best_zfs_path <kernel-dev> <bay-key>
# Picks the right /dev/disk/by-id form to use when adding back to a pool.
best_zfs_path() {
    local kdev="$1" key="$2"
    local byid=""
    [[ -n "$kdev" ]] && byid="${BYID_FOR_DEV[$kdev]:-}"
    [[ -n "$byid" ]] || byid="${MAP_BY_ID[$key]:-}"

    # Honor PREFER_ZFS_PATH_FORM if a specific form is requested.
    case "$PREFER_ZFS_PATH_FORM" in
        wwn)
            local n="${MAP_WWN[$key]:-}"
            n="$(_strip_wwn "$n")"
            if [[ -n "$n" ]] && [[ -e "/dev/disk/by-id/wwn-0x${n}" ]]; then
                printf '/dev/disk/by-id/wwn-0x%s' "$n"; return
            fi
            ;;
        by-id-ata|by-id-scsi)
            local prefix="${PREFER_ZFS_PATH_FORM#by-id-}"
            local cand
            for cand in /dev/disk/by-id/"$prefix"-*; do
                [[ -e "$cand" ]] || continue
                if [[ "$(readlink -f "$cand")" = "$kdev" ]]; then printf '%s' "$cand"; return; fi
            done
            ;;
    esac

    if [[ -n "$byid" ]]; then printf '%s' "$byid"; return; fi
    if [[ -n "$kdev" ]]; then
        log_warn "ไม่พบ /dev/disk/by-id/* — จะใช้ $kdev (เสี่ยงต่อการเปลี่ยนเลขลำดับ /dev/sdX)"
        printf '%s' "$kdev"
    fi
}

# ensure_default_controller — sanity check for state-changing ops.
ensure_default_controller() {
    if [[ -z "$ZB_CONTROLLER" ]]; then ZB_CONTROLLER=0; fi
    if [[ -z "$ZB_ENCLOSURE" ]]; then ZB_ENCLOSURE="$(perccli_default_enclosure)"; fi
}

# ---- pool status -----------------------------------------------------------

cmd_pool_status() {
    local pool="${1:-}"
    check_deps 0
    maps_load
    if [[ "$ZB_JSON" = "1" ]]; then
        _pool_status_json "$pool"
        return
    fi
    if [[ -n "$pool" ]]; then
        zfs_pool_status_text "$pool"
        return
    fi
    # Summary header
    printf '%s\n' "$(printf 'NAME\tSIZE\tALLOC\tFREE\tHEALTH\tFRAG\tCAP')"
    while IFS=$'\t' read -r n size alloc free health frag cap; do
        [[ -n "$n" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$n" "$size" "$alloc" "$free" "$(colorize_state "$health")" "$frag" "$cap"
    done < <(zfs_pool_list) | render_table
}

_pool_status_json() {
    local pool="${1:-}"
    local pools_arr='[]'
    local row size alloc free health frag cap n
    while IFS=$'\t' read -r n size alloc free health frag cap; do
        [[ -n "$n" ]] || continue
        if [[ -n "$pool" ]] && [[ "$n" != "$pool" ]]; then continue; fi
        local txt; txt="$(zfs_pool_status_text "$n")"
        local resilver
        resilver="$(zfs_parse_resilver "$txt")"
        local rip rpct reta rscan rtot rrate
        IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$resilver"
        row="$(jq -n \
            --arg name "$n" --arg size "$size" --arg alloc "$alloc" --arg free "$free" \
            --arg health "$health" --arg frag "$frag" --arg cap "$cap" \
            --argjson rip "${rip:-0}" \
            --arg rpct "$rpct" --arg reta "$reta" \
            --arg rscan "$rscan" --arg rtot "$rtot" --arg rrate "$rrate" \
            '{name:$name, size:$size, alloc:$alloc, free:$free,
              health:$health, frag:$frag, cap:$cap,
              resilver:{
                in_progress: ($rip == 1),
                percent: ($rpct | if . == "" then null else tonumber end),
                eta_seconds: ($reta | if . == "" then null else tonumber end),
                scanned_bytes: ($rscan | if . == "" then null else tonumber end),
                total_bytes: ($rtot | if . == "" then null else tonumber end),
                rate_bps: ($rrate | if . == "" then null else tonumber end)
              }}')"
        pools_arr="$(jq --argjson p "$row" '. + [$p]' <<< "$pools_arr")"
    done < <(zfs_pool_list)
    jq -n --argjson pools "$pools_arr" '{pools:$pools}'
}

# ---- bay status ------------------------------------------------------------

cmd_bay_status() {
    local input="${1:-}"
    check_deps 0
    maps_load

    if [[ "$ZB_JSON" = "1" ]]; then
        _bay_status_json "$input"
        return
    fi

    if [[ -n "$input" ]]; then
        local key; key="$(resolve_bay "$input")" || die 2 "bay ไม่ถูกต้อง: $input"
        if [[ -z "${MAP_PD_JSON[$key]:-}" ]]; then die 5 "ไม่พบ bay $key"; fi
        _bay_detail_human "$key"
        return
    fi
    _bay_status_human
}

_bay_status_human() {
    {
        printf 'BAY\tSERIAL\tDEVICE\tID\tSTATE\tHEALTH%%\tENDUR%%\tUSED/TOTAL\tPOOL\tVDEV\n'
        local key
        for key in "${MAP_BAY_KEYS[@]}"; do
            _emit_bay_row "$key"
        done
    } | render_table
}

_emit_bay_row() {
    local key="$1"
    local serial="${MAP_SERIAL[$key]:-}"
    local byid="${MAP_BY_ID[$key]:-}"
    local kdev="${MAP_KERNEL_DEV[$key]:-}"
    local state="${MAP_PERC_STATE[$key]:-}"
    local pool="${MAP_POOL[$key]:-}"
    local vdev="${MAP_VDEV[$key]:-}"
    local total_b="${MAP_TOTAL_BYTES[$key]:-0}"
    local used_b="${MAP_USED_BYTES[$key]:-}"

    local health="?" endurance="?"
    if [[ -n "${MAP_DID[$key]:-}" ]]; then
        local intf="${MAP_INTERFACE[$key]:-}" media="${MAP_MEDIA[$key]:-}"
        # Skip live SMART probes if we have no megaraid device (e.g. running on macOS dev box).
        if [[ -e /dev/bus/0 ]] || [[ -e /sys/class/scsi_generic ]]; then
            local smart_text=""
            case "${intf^^}" in
                SATA) smart_text="$(smart_run_megaraid "${MAP_DID[$key]}" -A 2>/dev/null)" ;;
                SAS)  smart_text="$(smart_run_megaraid "${MAP_DID[$key]}" -a 2>/dev/null)" ;;
                NVMe) [[ -n "$kdev" ]] && smart_text="$(smart_run_native "$kdev" -a 2>/dev/null)" ;;
            esac
            if [[ -n "$smart_text" ]]; then
                health="$(smart_health_pct "$smart_text" "${MAP_PD_JSON[$key]:-}")"
            fi
            endurance="$(smart_endurance_for_drive "$intf" "$media" "${MAP_DID[$key]}" "$kdev")"
        fi
    fi

    if [[ "${media:-${MAP_MEDIA[$key]}}" = "HDD" ]]; then endurance="N/A"; fi

    local size_h="-" used_h="-" total_h="-"
    [[ "$total_b" =~ ^[0-9]+$ ]] && [[ "$total_b" -gt 0 ]] && total_h="$(format_bytes "$total_b")"
    if [[ -n "$used_b" ]] && [[ "$used_b" =~ ^[0-9]+$ ]]; then
        used_h="$(format_bytes "$used_b")"
        size_h="${used_h}/${total_h}"
    else
        size_h="-/${total_h}"
    fi

    [[ -z "$serial" ]] && serial="-"
    [[ -z "$byid"   ]] && byid="-"
    [[ -z "$kdev"   ]] && kdev="-"
    [[ -z "$state"  ]] && state="-"
    [[ -z "$pool"   ]] && pool="-"
    [[ -z "$vdev"   ]] && vdev="-"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$key" "$serial" "$byid" "${kdev##*/}" \
        "$(colorize_state "$state")" \
        "$(colorize_health "$health")" \
        "$(colorize_endurance "$endurance")" \
        "$size_h" "$pool" "$vdev"
}

_bay_detail_human() {
    local key="$1"
    printf '%sBay %s%s\n' "$c_bold" "$key" "$c_reset"
    printf '  Model        : %s\n' "${MAP_MODEL[$key]:-}"
    printf '  Serial       : %s\n' "${MAP_SERIAL[$key]:-}"
    printf '  WWN          : %s\n' "${MAP_WWN[$key]:-}"
    printf '  DID          : %s\n' "${MAP_DID[$key]:-}"
    printf '  Size         : %s\n' "$(format_bytes "${MAP_SIZE_BYTES[$key]:-0}")"
    printf '  Interface    : %s\n' "${MAP_INTERFACE[$key]:-}"
    printf '  Media        : %s\n' "${MAP_MEDIA[$key]:-}"
    printf '  PERC state   : %s\n' "${MAP_PERC_STATE[$key]:-}"
    printf '  PERC VD      : %s\n' "${MAP_PERC_VD[$key]:--}"
    printf '  Kernel device: %s\n' "${MAP_KERNEL_DEV[$key]:--}"
    printf '  by-id        : %s\n' "${MAP_BY_ID[$key]:--}"
    printf '  Pool         : %s\n' "${MAP_POOL[$key]:--}"
    printf '  Vdev         : %s\n' "${MAP_VDEV[$key]:--}"
    printf '  Vdev state   : %s\n' "${MAP_VDEV_STATE[$key]:--}"
}

_bay_status_json() {
    local input="${1:-}"
    local arr='[]'
    local key
    for key in "${MAP_BAY_KEYS[@]}"; do
        if [[ -n "$input" ]]; then
            local target; target="$(resolve_bay "$input")" || true
            [[ "$key" = "$target" ]] || continue
        fi
        local intf="${MAP_INTERFACE[$key]:-}" media="${MAP_MEDIA[$key]:-}" did="${MAP_DID[$key]:-}"
        local kdev="${MAP_KERNEL_DEV[$key]:-}"
        local smart_text="" overall="UNKNOWN"
        local health=null endurance=null
        if [[ -n "$did" ]] && [[ -e /dev/bus/0 || -e /sys/class/scsi_generic ]]; then
            case "${intf^^}" in
                SATA) smart_text="$(smart_run_megaraid "$did" -A 2>/dev/null)" ;;
                SAS)  smart_text="$(smart_run_megaraid "$did" -a 2>/dev/null)" ;;
                NVMe) [[ -n "$kdev" ]] && smart_text="$(smart_run_native "$kdev" -a 2>/dev/null)" ;;
            esac
            if [[ -n "$smart_text" ]]; then
                overall="$(smart_overall "$smart_text")"
                local hv ev
                hv="$(smart_health_pct "$smart_text" "${MAP_PD_JSON[$key]:-}")"
                ev="$(smart_endurance_for_drive "$intf" "$media" "$did" "$kdev")"
                [[ "$hv" =~ ^[0-9]+$ ]] && health="$hv"
                [[ "$ev" =~ ^[0-9]+$ ]] && endurance="$ev"
            fi
        fi
        local total="${MAP_SIZE_BYTES[$key]:-0}"
        local used="${MAP_USED_BYTES[$key]:-}"
        local row
        row="$(jq -n \
            --arg bay "$key" \
            --arg slot "${key##*:}" \
            --arg did "$did" \
            --arg wwn "${MAP_WWN[$key]:-}" \
            --arg serial "${MAP_SERIAL[$key]:-}" \
            --arg model  "${MAP_MODEL[$key]:-}" \
            --argjson size "${total:-0}" \
            --arg intf "$intf" --arg media "$media" \
            --arg perc_state "${MAP_PERC_STATE[$key]:-}" \
            --arg perc_vd    "${MAP_PERC_VD[$key]:-}" \
            --arg kernel_dev "$kdev" \
            --arg by_id "${MAP_BY_ID[$key]:-}" \
            --arg overall "$overall" \
            --argjson health "$health" \
            --argjson endurance "$endurance" \
            --arg used "$used" \
            --arg pool "${MAP_POOL[$key]:-}" \
            --arg vdev "${MAP_VDEV[$key]:-}" \
            --arg vstate "${MAP_VDEV_STATE[$key]:-}" \
            '{bay:$bay, slot:($slot|tonumber? // null),
              did:($did|tonumber? // null), wwn:$wwn, serial:$serial,
              model:$model, size_bytes:$size, interface:$intf, media:$media,
              perc_state:$perc_state, perc_jbod:($perc_state == "JBOD"),
              perc_vd:($perc_vd | if . == "" then null else tonumber? end),
              kernel_device:(if $kernel_dev == "" then null else $kernel_dev end),
              by_id:(if $by_id == "" then null else $by_id end),
              smart_overall:$overall, health_pct:$health, endurance_pct:$endurance,
              used_bytes:($used | if . == "" then null else tonumber? end),
              total_bytes:$size,
              pool:(if $pool == "" then null else $pool end),
              vdev:(if $vdev == "" then null else $vdev end),
              vdev_state:(if $vstate == "" then null else $vstate end)
            }')"
        arr="$(jq --argjson r "$row" '. + [$r]' <<< "$arr")"
    done
    jq -n --argjson bays "$arr" \
          --argjson c "${ZB_CONTROLLER:-0}" \
          --arg e "${ZB_ENCLOSURE:-}" \
          '{controller:$c, enclosure:($e | if . == "" then null else tonumber? end), bays:$bays}'
}

# ---- check sync ------------------------------------------------------------

cmd_check_sync() {
    local bay="${1:-}"
    check_deps 0
    maps_load
    local target_pool=""
    if [[ -n "$bay" ]]; then
        local key; key="$(resolve_bay "$bay")" || die 2 "bay ไม่ถูกต้อง: $bay"
        target_pool="${MAP_POOL[$key]:-}"
        [[ -n "$target_pool" ]] || die 6 "bay $key ไม่ได้อยู่ใน ZFS pool"
    fi
    if [[ "$ZB_JSON" = "1" ]]; then _check_sync_json "$target_pool"; return; fi
    _check_sync_human "$target_pool"
}

_check_sync_human() {
    local target="${1:-}"
    local any=0 pool
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        if [[ -n "$target" ]] && [[ "$pool" != "$target" ]]; then continue; fi
        local txt; txt="$(zfs_pool_status_text "$pool")"
        local r; r="$(zfs_parse_resilver "$txt")"
        local rip rpct reta rscan rtot rrate
        IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$r"
        if [[ "$rip" = "1" ]]; then
            any=1
            local pct_int="${rpct%%.*}"
            local bar; bar="$(progress_bar "${pct_int:-0}" 30)"
            local sc=""; tot=""; eta=""
            [[ -n "$rscan" ]] && sc="$(format_bytes "$rscan")"
            [[ -n "$rtot"  ]] && tot="$(format_bytes "$rtot")"
            [[ -n "$reta"  ]] && eta="$(format_eta_seconds "$reta")"
            printf '%s: %s %s%% — %s to go — %s / %s\n' \
                "$pool" "$bar" "${rpct:-?}" "${eta:-unknown}" "${sc:-?}" "${tot:-?}"
        elif [[ -n "$target" ]]; then
            printf 'no resilver in progress for pool %s\n' "$pool"
        fi
    done < <(zfs_pool_names)
    if [[ "$any" = "0" ]] && [[ -z "$target" ]]; then
        printf 'no resilver in progress on any pool\n'
    fi
}

_check_sync_json() {
    local target="${1:-}"
    local arr='[]' pool
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        if [[ -n "$target" ]] && [[ "$pool" != "$target" ]]; then continue; fi
        local txt; txt="$(zfs_pool_status_text "$pool")"
        local r; r="$(zfs_parse_resilver "$txt")"
        local rip rpct reta rscan rtot rrate
        IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$r"
        local state; state="$(zfs_pool_state "$txt")"
        local row
        row="$(jq -n \
            --arg name "$pool" --arg state "$state" \
            --argjson rip "${rip:-0}" \
            --arg rpct "$rpct" --arg reta "$reta" \
            --arg rscan "$rscan" --arg rtot "$rtot" --arg rrate "$rrate" \
            '{name:$name, state:$state,
              resilver:{
                in_progress:($rip == 1),
                percent:($rpct | if . == "" then null else tonumber end),
                eta_seconds:($reta | if . == "" then null else tonumber end),
                scanned_bytes:($rscan | if . == "" then null else tonumber end),
                total_bytes:($rtot | if . == "" then null else tonumber end),
                rate_bps:($rrate | if . == "" then null else tonumber end)
              }}')"
        arr="$(jq --argjson p "$row" '. + [$p]' <<< "$arr")"
    done < <(zfs_pool_names)
    jq -n --argjson pools "$arr" '{pools:$pools}'
}

# ---- locate ----------------------------------------------------------------

cmd_locate() {
    local input="${1:-}" mode="${2:-on}"
    [[ -n "$input" ]] || die 2 "locate: ต้องระบุ bay"
    local key; key="$(resolve_bay "$input")" || die 2 "bay ไม่ถูกต้อง: $input"
    local eid="${key%%:*}" slot="${key##*:}"
    check_deps 1
    case "${mode,,}" in
        on)  perccli_locate_on  "$ZB_CONTROLLER" "$eid" "$slot"; log_info "locate ON: bay $key" ;;
        off) perccli_locate_off "$ZB_CONTROLLER" "$eid" "$slot"; log_info "locate OFF: bay $key" ;;
        *)   die 2 "locate: ใช้ on หรือ off เท่านั้น" ;;
    esac
}

# ---- bay remove ------------------------------------------------------------

cmd_bay_remove() {
    local input="$1"
    local key; key="$(resolve_bay "$input")" || die 2 "bay ไม่ถูกต้อง: $input"
    check_deps 1
    maps_load

    if [[ -z "${MAP_PD_JSON[$key]:-}" ]]; then die 5 "ไม่พบ bay $key"; fi

    local eid="${key%%:*}" slot="${key##*:}"
    local pool="${MAP_POOL[$key]:-}"
    local vdev="${MAP_VDEV[$key]:-}"
    local kdev="${MAP_KERNEL_DEV[$key]:-}"
    local byid="${MAP_BY_ID[$key]:-}"
    local zfs_path="${byid:-$kdev}"

    log_info "เริ่ม bay $key remove (pool=${pool:--}, vdev=${vdev:--})"

    if is_rpool_device "$zfs_path"; then
        if [[ "${ZB_FLAGS[force_boot]}" != "1" ]]; then
            die 1 "bay $key อยู่บน rpool/boot — ต้องใช้ --force-boot และเตรียม proxmox-boot-tool ด้วยตนเอง"
        fi
        log_warn "กำลังถอดดิสก์ rpool — หลังเสียบใหม่ต้องรัน: proxmox-boot-tool format <ESP> && proxmox-boot-tool init <ESP>"
    fi

    if [[ -z "$pool" ]]; then
        log_warn "bay $key ไม่ได้อยู่ใน ZFS pool ใด ๆ"
        confirm "ดำเนินการ locate + spindown ต่อหรือไม่?" || die 7 "ผู้ใช้ยกเลิก"
    else
        # Active resilver lockout
        local txt; txt="$(zfs_pool_status_text "$pool")"
        local r; r="$(zfs_parse_resilver "$txt")"
        local rip; rip="${r%%$'\t'*}"
        if [[ "$rip" = "1" ]] && [[ "${ZB_FLAGS[force]}" != "1" ]]; then
            die 6 "pool $pool กำลัง resilver อยู่ — รอจนเสร็จ หรือใช้ --force"
        fi

        # Redundancy check
        local healthy floor
        healthy="$(zfs_count_healthy_children "$pool" "$vdev")"
        floor="$(zfs_vdev_min_after_remove "$vdev")"
        if (( healthy - 1 < floor )) && [[ "${ZB_FLAGS[force]}" != "1" ]]; then
            die 6 "ห้ามถอด: vdev $vdev ใน pool $pool มี healthy=$healthy ถ้าถอดจะเหลือ $((healthy-1)) (ขั้นต่ำ $floor) — ใช้ --force ถ้ายืนยัน"
        fi

        confirm "Offline $zfs_path จาก pool $pool และเตรียมถอด?" || die 7 "ผู้ใช้ยกเลิก"

        zfs_offline "$pool" "$zfs_path" || die 6 "zpool offline ล้มเหลว"

        # Verify state changed (skip in dry-run).
        if [[ "$ZB_DRY_RUN" != "1" ]]; then
            sleep 1
            local new_state
            new_state="$(zfs_pool_status_text "$pool" | awk -v d="$zfs_path" '
                /^ *config:/ { inblk=1; next } /^ *errors:/ { inblk=0 }
                inblk && $1 == d { print $2; exit }')"
            if [[ "$new_state" != "OFFLINE" ]] && [[ "${ZB_FLAGS[force]}" != "1" ]]; then
                die 6 "ตรวจไม่พบสถานะ OFFLINE หลังคำสั่ง zpool offline (state=$new_state)"
            fi
        fi
    fi

    perccli_locate_on "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "locate LED command returned non-zero (ignored)"

    if [[ "${ZB_FLAGS[delete_vd]}" = "1" ]] && [[ -n "${MAP_PERC_VD[$key]:-}" ]]; then
        confirm "ลบ single-disk RAID0 VD ที่ครอบ bay $key ด้วย?" \
            && perccli_delete_vd_for_pd "$ZB_CONTROLLER" "$eid" "$slot"
    fi

    # Spindown only if drive is currently usable; ignore failures (already-failed drives may refuse).
    perccli_spindown "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "spindown returned non-zero (drive may be already offline/failed) — ignored"

    cat <<EOF
${c_green}✔ ไฟ LED ติดที่ bay $key แล้ว ปลอดภัยที่จะถอดดิสก์ออก${c_reset}
   ขั้นถัดไป: เสียบดิสก์ใหม่ จากนั้นรัน:
     zfsbay bay ${slot} replace ${pool:+   # pool=$pool}
EOF
    log_info "bay $key remove เสร็จเรียบร้อย"
}

# ---- bay replace -----------------------------------------------------------

cmd_bay_replace() {
    local input="$1"
    local key; key="$(resolve_bay "$input")" || die 2 "bay ไม่ถูกต้อง: $input"
    check_deps 1
    maps_load

    if [[ -z "${MAP_PD_JSON[$key]:-}" ]]; then die 5 "ไม่พบ PD ใน bay $key — มีดิสก์เสียบจริงหรือไม่?"; fi
    local eid="${key%%:*}" slot="${key##*:}"
    local state="${MAP_PERC_STATE[$key]:-}"
    log_info "เริ่ม bay $key replace (perc_state=$state)"

    # Foreign config detection
    perccli_load_foreign
    local foreign_n; foreign_n="$(perccli_foreign_count)"
    if [[ "${foreign_n:-0}" =~ ^[0-9]+$ ]] && (( foreign_n > 0 )); then
        if (( foreign_n > 1 )) && [[ "${ZB_FLAGS[clear_foreign]}" != "1" ]] && [[ "$ASSUME_YES" != "1" ]]; then
            die 5 "พบ foreign config หลายชุด ($foreign_n) — ใช้ --clear-foreign เพื่อยืนยันการลบทั้งหมด"
        fi
        if [[ "${ZB_FLAGS[clear_foreign]}" = "1" ]] || confirm "พบ foreign config — ลบทิ้ง?"; then
            perccli_clear_foreign "$ZB_CONTROLLER" || log_warn "clear foreign returned non-zero"
            PERCCLI_FOREIGN_JSON=""
        else
            die 7 "ผู้ใช้ยกเลิก (foreign config ยังคงค้างอยู่)"
        fi
    fi

    # Determine target mode by inspecting peers in same pool.
    local target_mode="jbod"  # default; overridden below if peers are RAID0
    local pool=""
    local k
    for k in "${MAP_BAY_KEYS[@]}"; do
        if [[ -n "${MAP_POOL[$k]:-}" ]] && [[ -n "${MAP_PERC_VD[$k]:-}" ]]; then
            pool="${MAP_POOL[$k]}"; target_mode="raid0"
            break
        fi
    done

    if [[ "$target_mode" = "jbod" ]]; then
        perccli_set_good "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set good returned non-zero"
        perccli_set_jbod "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set jbod returned non-zero"
    else
        perccli_set_good   "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set good returned non-zero"
        perccli_add_r0_vd  "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "add r0 vd returned non-zero"
    fi

    # Wait for udev to expose the new device.
    local pd_obj wwn serial new_dev=""
    pd_obj="${MAP_PD_JSON[$key]:-}"
    wwn="$(printf '%s' "$pd_obj" | jq -r '.WWN // empty')"
    serial="$(printf '%s' "$pd_obj" | jq -r '.SN // empty' | sed 's/[[:space:]]*$//')"

    if [[ "$ZB_DRY_RUN" != "1" ]]; then
        if ! new_dev="$(wait_for_device "$wwn" "$serial" 60)"; then
            die 5 "ไม่พบ /dev/sdX สำหรับดิสก์ใหม่ภายใน 60 วินาที"
        fi
    else
        new_dev="${MAP_KERNEL_DEV[$key]:-/dev/sdNEW}"
    fi

    # Refresh by-id table for the new device.
    BYID_FOR_DEV=()
    maps_load_devices
    local new_zfs; new_zfs="$(best_zfs_path "$new_dev" "$key")"
    log_info "ดิสก์ใหม่: $new_dev (zfs path: $new_zfs)"

    # Find the OFFLINE/UNAVAIL/FAULTED/REMOVED child to replace.
    local old_dev=""
    if [[ -z "$pool" ]]; then
        # No previous peer — try any pool with degraded vdev.
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            old_dev="$(zfs_pool_status_text "$p" | awk '
                /^ *config:/ { inblk=1; next } /^ *errors:/ { inblk=0 }
                inblk && $2 ~ /^(OFFLINE|UNAVAIL|FAULTED|REMOVED)$/ { print $1; exit }')"
            if [[ -n "$old_dev" ]]; then pool="$p"; break; fi
        done < <(zfs_pool_names)
    else
        old_dev="$(zfs_pool_status_text "$pool" | awk '
            /^ *config:/ { inblk=1; next } /^ *errors:/ { inblk=0 }
            inblk && $2 ~ /^(OFFLINE|UNAVAIL|FAULTED|REMOVED)$/ { print $1; exit }')"
    fi

    if [[ -n "$pool" ]] && [[ -n "$old_dev" ]]; then
        # ashift compatibility check
        local ashift
        ashift="$(zfs_pool_ashift "$pool")"
        if [[ -n "$ashift" ]] && command -v lsblk >/dev/null 2>&1; then
            local phy
            phy="$(lsblk -dno PHY-SEC "$new_dev" 2>/dev/null || true)"
            if [[ -n "$phy" ]] && [[ "$phy" =~ ^[0-9]+$ ]]; then
                local need=12  # default 4K -> ashift=12
                (( phy == 512 )) && need=9
                if (( need != ashift )) && [[ "${ZB_FLAGS[force]}" != "1" ]]; then
                    log_warn "ashift ของ pool=$ashift แต่ดิสก์ใหม่ phy-sec=$phy — เพิ่ม --force ถ้าต้องการลุยต่อ"
                    die 6 "ashift mismatch"
                fi
            fi
        fi
        zfs_replace "$pool" "$old_dev" "$new_zfs" || die 6 "zpool replace ล้มเหลว"
        log_info "เริ่ม resilver: pool=$pool old=$old_dev new=$new_zfs"
    else
        log_warn "ไม่พบ pool ที่มี vdev ในสถานะ OFFLINE/UNAVAIL — ข้าม zpool replace (ใช้ 'bay <N> join pool <name>' เพื่อเพิ่มเข้า pool)"
    fi

    perccli_locate_off "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "stop locate returned non-zero (ignored)"

    cat <<EOF
${c_green}✔ bay $key เปลี่ยนดิสก์เสร็จ${c_reset}
   ตรวจความคืบหน้า: zfsbay check sync bay $slot
EOF
}

# ---- bay join pool ---------------------------------------------------------

cmd_bay_join() {
    local input="$1" pool="$2" mode="${3:-}"
    [[ -n "$pool" ]] || die 2 "ต้องระบุชื่อ pool"
    local key; key="$(resolve_bay "$input")" || die 2 "bay ไม่ถูกต้อง: $input"
    check_deps 1
    maps_load

    if [[ -z "${MAP_PD_JSON[$key]:-}" ]]; then die 5 "ไม่พบ PD ใน bay $key"; fi
    if [[ -n "${MAP_POOL[$key]:-}" ]]; then die 6 "bay $key อยู่ใน pool ${MAP_POOL[$key]} อยู่แล้ว"; fi

    local eid="${key%%:*}" slot="${key##*:}"

    # Foreign config check
    perccli_load_foreign
    local fn; fn="$(perccli_foreign_count)"
    if [[ "${fn:-0}" =~ ^[0-9]+$ ]] && (( fn > 0 )); then
        if [[ "${ZB_FLAGS[clear_foreign]}" = "1" ]] || confirm "พบ foreign config — ลบทิ้ง?"; then
            perccli_clear_foreign "$ZB_CONTROLLER" || log_warn "clear foreign returned non-zero"
        else
            die 7 "ผู้ใช้ยกเลิก"
        fi
    fi

    # Mirror peer-mode (raid0 vs jbod)
    local target_mode="jbod"
    local k
    for k in "${MAP_BAY_KEYS[@]}"; do
        if [[ "${MAP_POOL[$k]:-}" = "$pool" ]] && [[ -n "${MAP_PERC_VD[$k]:-}" ]]; then
            target_mode="raid0"; break
        fi
    done
    if [[ "$target_mode" = "jbod" ]]; then
        perccli_set_good "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set good returned non-zero"
        perccli_set_jbod "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set jbod returned non-zero"
    else
        perccli_set_good   "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "set good returned non-zero"
        perccli_add_r0_vd  "$ZB_CONTROLLER" "$eid" "$slot" || log_warn "add r0 vd returned non-zero"
    fi

    local pd_obj; pd_obj="${MAP_PD_JSON[$key]:-}"
    local wwn serial new_dev=""
    wwn="$(printf '%s' "$pd_obj"   | jq -r '.WWN // empty')"
    serial="$(printf '%s' "$pd_obj" | jq -r '.SN // empty' | sed 's/[[:space:]]*$//')"
    if [[ "$ZB_DRY_RUN" != "1" ]]; then
        new_dev="$(wait_for_device "$wwn" "$serial" 60)" || die 5 "ไม่พบ /dev/sdX สำหรับดิสก์ใหม่ภายใน 60 วินาที"
    else
        new_dev="${MAP_KERNEL_DEV[$key]:-/dev/sdNEW}"
    fi
    BYID_FOR_DEV=(); maps_load_devices
    local new_zfs; new_zfs="$(best_zfs_path "$new_dev" "$key")"

    case "$mode" in
        ""|spare)        zfs_add_spare "$pool" "$new_zfs" ;;
        mirror=*)        local existing="${mode#mirror=}"; zfs_attach "$pool" "$existing" "$new_zfs" ;;
        replace=*)       local old="${mode#replace=}";    zfs_replace "$pool" "$old" "$new_zfs" ;;
        vdev=*)          die 2 "vdev=<type> ต้องการดิสก์อย่างน้อย 2 ตัว — ใช้ zpool add ด้วยตนเอง" ;;
        *)               die 2 "mode ไม่รู้จัก: $mode (mirror=<dev>|spare|replace=<old>)" ;;
    esac

    log_info "bay $key เพิ่มเข้า pool $pool (mode=${mode:-spare}) เรียบร้อย"
    cat <<EOF
${c_green}✔ bay $key เพิ่มเข้า pool $pool แล้ว${c_reset}
EOF
}
