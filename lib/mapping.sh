#!/usr/bin/env bash
# mapping.sh — bay ↔ DID ↔ WWN ↔ /dev/sdX ↔ by-id ↔ ZFS vdev resolver.
# Cached in-memory for a single invocation; --refresh clears the cache.
# shellcheck shell=bash
# All MAP_* and DEV_BY_* arrays below are read by lib/workflows.sh and lib/ui.sh
# after sourcing — shellcheck cannot follow that across files when checking lib/
# in isolation, so we suppress the unused-variable noise here.
# shellcheck disable=SC2034

# Per-resolved-bay attributes are stored in associative arrays keyed by "EID:Slot".
declare -gA MAP_PD_JSON          # raw PD JSON object
declare -gA MAP_DID
declare -gA MAP_WWN
declare -gA MAP_SERIAL
declare -gA MAP_MODEL
declare -gA MAP_SIZE_BYTES
declare -gA MAP_INTERFACE        # SATA / SAS / NVMe
declare -gA MAP_MEDIA            # SSD / HDD
declare -gA MAP_PERC_STATE
declare -gA MAP_PERC_VD          # VD index (or "")
declare -gA MAP_KERNEL_DEV       # /dev/sdX
declare -gA MAP_BY_ID            # /dev/disk/by-id/...
declare -gA MAP_POOL
declare -gA MAP_VDEV
declare -gA MAP_VDEV_STATE
declare -gA MAP_USED_BYTES
declare -gA MAP_TOTAL_BYTES

# Ordered list of bay keys (controller-relative) we know about.
declare -ga MAP_BAY_KEYS=()

# Lookup helpers populated by maps_load_devices.
declare -gA DEV_BY_WWN           # wwn (no 0x prefix, lowercase) -> /dev/sdX
declare -gA DEV_BY_SERIAL        # serial -> /dev/sdX
declare -gA BYID_FOR_DEV         # /dev/sdX -> /dev/disk/by-id/...

MAP_LOADED=0

map_clear_cache() {
    MAP_PD_JSON=(); MAP_DID=(); MAP_WWN=(); MAP_SERIAL=(); MAP_MODEL=();
    MAP_SIZE_BYTES=(); MAP_INTERFACE=(); MAP_MEDIA=(); MAP_PERC_STATE=();
    MAP_PERC_VD=(); MAP_KERNEL_DEV=(); MAP_BY_ID=(); MAP_POOL=();
    MAP_VDEV=(); MAP_VDEV_STATE=(); MAP_USED_BYTES=(); MAP_TOTAL_BYTES=();
    DEV_BY_WWN=(); DEV_BY_SERIAL=(); BYID_FOR_DEV=();
    MAP_BAY_KEYS=(); PERCCLI_PD_JSON=""; PERCCLI_VD_JSON=""
    MAP_LOADED=0
}

# maps_load_devices — populate DEV_BY_WWN, DEV_BY_SERIAL, BYID_FOR_DEV.
maps_load_devices() {
    if [[ -d /dev/disk/by-id ]]; then
        local link target dev
        local entry
        for entry in /dev/disk/by-id/*; do
            [[ -e "$entry" ]] || continue
            target="$(readlink -f "$entry" 2>/dev/null)" || continue
            [[ -b "$target" ]] || continue
            # Only keep whole-disk symlinks (skip partition entries).
            if [[ "$target" =~ [0-9]p?[0-9]+$ ]] && [[ ! "$target" =~ /nvme[0-9]+n[0-9]+$ ]]; then
                # partition like /dev/sda1 — skip
                continue
            fi
            local base="${entry##*/}"
            # Prefer wwn-* > scsi-* > ata-* — store the "best" one we've seen.
            if [[ -z "${BYID_FOR_DEV[$target]:-}" ]]; then
                BYID_FOR_DEV[$target]="$entry"
            else
                local existing="${BYID_FOR_DEV[$target]##*/}"
                if [[ "$base" == wwn-* && "$existing" != wwn-* ]]; then
                    BYID_FOR_DEV[$target]="$entry"
                elif [[ "$base" == scsi-* && "$existing" != wwn-* && "$existing" != scsi-* ]]; then
                    BYID_FOR_DEV[$target]="$entry"
                fi
            fi

            if [[ "$base" == wwn-0x* ]]; then
                local w="${base#wwn-0x}"
                DEV_BY_WWN[${w,,}]="$target"
            fi
        done
    fi

    # Build serial table via udevadm (best effort).
    if command -v udevadm >/dev/null 2>&1; then
        local d
        for d in /dev/sd?* /dev/nvme?n? ; do
            [[ -b "$d" ]] || continue
            # skip partitions
            if [[ "$d" =~ ^/dev/sd[a-z]+[0-9]+$ ]]; then continue; fi
            if [[ "$d" =~ ^/dev/nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then continue; fi
            local props serial wwn
            props="$(udevadm info --query=property --name="$d" 2>/dev/null || true)"
            serial="$(awk -F= '/^ID_SERIAL_SHORT=/ { print $2; exit }' <<< "$props")"
            [[ -z "$serial" ]] && serial="$(awk -F= '/^ID_SCSI_SERIAL=/ { print $2; exit }' <<< "$props")"
            [[ -z "$serial" ]] && serial="$(awk -F= '/^ID_SERIAL=/ { print $2; exit }' <<< "$props")"
            wwn="$(awk -F= '/^ID_WWN=/ { print $2; exit }' <<< "$props")"
            wwn="${wwn#0x}"
            [[ -n "$serial" ]] && DEV_BY_SERIAL[$serial]="$d"
            [[ -n "$wwn"    ]] && DEV_BY_WWN[${wwn,,}]="$d"
        done
    fi
}

# _strip_wwn <wwn-string> — normalize to lowercase hex (no 0x, no leading zeroes? no — keep length)
_strip_wwn() {
    local w="${1,,}"
    w="${w#0x}"
    # PERC sometimes prints WWN with hyphens or naa. prefix
    w="${w//naa./}"
    w="${w//-/}"
    printf '%s' "$w"
}

# map_resolve_pool_for_device <device-path> -> sets MAP_POOL/MAP_VDEV via parsing all pools' status.
# Implementation here is folded into the main load loop for efficiency.

# maps_load — entry point. After this returns, all MAP_* arrays are populated.
maps_load() {
    [[ "$MAP_LOADED" = "1" ]] && [[ "${ZB_FLAGS[refresh]:-0}" != "1" ]] && return 0
    if [[ "${ZB_FLAGS[refresh]:-0}" = "1" ]]; then map_clear_cache; fi

    maps_load_devices
    perccli_load_pds || true
    perccli_load_vds || true

    # If perccli isn't present, we have no bays — return empty.
    if [[ -z "$PERCCLI_PD_JSON" ]]; then MAP_LOADED=1; return 0; fi

    # Build VD index: PD-EID:Slt -> VD index (for single-disk RAID0 detection).
    declare -A VD_FOR_PD=()
    if [[ -n "$PERCCLI_VD_JSON" ]]; then
        local vd_pairs
        vd_pairs="$(perccli_vd_array | jq -r '.[]
            | (.["DG/VD"] // "") as $dgvd
            | ((.PDs // []) | map(.["EID:Slt"] // "") | .[])
            | "\(.)\t\($dgvd)"' 2>/dev/null || true)"
        local pd_es vd_id
        while IFS=$'\t' read -r pd_es vd_id; do
            [[ -n "$pd_es" ]] && VD_FOR_PD[$pd_es]="${vd_id##*/}"
        done <<< "$vd_pairs"
    fi

    # Iterate PDs.
    local pd_array
    pd_array="$(perccli_pd_array)"
    local pd_count
    pd_count="$(printf '%s' "$pd_array" | jq 'length')"
    local i
    for ((i=0; i<pd_count; i++)); do
        local obj eid_slt eid slot
        obj="$(printf '%s' "$pd_array" | jq -c ".[$i]")"
        eid_slt="$(printf '%s' "$obj" | jq -r '."EID:Slt" // empty')"
        [[ -n "$eid_slt" ]] || continue
        eid="${eid_slt%%:*}"; slot="${eid_slt##*:}"

        local key="$eid_slt"
        MAP_BAY_KEYS+=("$key")
        MAP_PD_JSON[$key]="$obj"
        MAP_DID[$key]="$(printf '%s' "$obj" | jq -r '.DID // empty')"
        # WWN field name varies across perccli versions: WWN / NAA / "World Wide Name".
        MAP_WWN[$key]="$(printf '%s' "$obj" | jq -r '.WWN // .NAA // ."World Wide Name" // empty')"
        # SN often has trailing whitespace in detailed Device attributes.
        MAP_SERIAL[$key]="$(printf '%s' "$obj" | jq -r '.SN // ."Serial Number" // empty' | sed 's/[[:space:]]*$//')"
        MAP_MODEL[$key]="$(printf '%s' "$obj" | jq -r '.Model // ."Model Number" // empty' | sed 's/[[:space:]]*$//')"
        MAP_INTERFACE[$key]="$(printf '%s' "$obj" | jq -r '.Intf // empty')"
        MAP_MEDIA[$key]="$(printf '%s' "$obj" | jq -r '.Med // empty')"
        MAP_PERC_STATE[$key]="$(printf '%s' "$obj" | jq -r '.State // empty')"
        MAP_PERC_VD[$key]="${VD_FOR_PD[$key]:-}"

        # Size: PERC reports e.g. "447.130 GB" or "3.637 TB"; convert to bytes.
        local size_str size_bytes
        size_str="$(printf '%s' "$obj" | jq -r '.Size // empty')"
        size_bytes="$(_size_to_bytes "$size_str")"
        MAP_SIZE_BYTES[$key]="$size_bytes"

        # Match to kernel device.
        local wwn_norm wwn_clean dev=""
        wwn_norm="$(_strip_wwn "${MAP_WWN[$key]}")"
        wwn_clean="${wwn_norm:0:16}"
        if [[ -n "$wwn_norm" ]] && [[ "$wwn_norm" != 0000000000000000* ]]; then
            dev="${DEV_BY_WWN[$wwn_norm]:-}"
            [[ -z "$dev" ]] && dev="${DEV_BY_WWN[$wwn_clean]:-}"
        fi
        if [[ -z "$dev" ]] && [[ -n "${MAP_SERIAL[$key]}" ]]; then
            dev="${DEV_BY_SERIAL[${MAP_SERIAL[$key]}]:-}"
        fi
        MAP_KERNEL_DEV[$key]="$dev"
        MAP_BY_ID[$key]="${BYID_FOR_DEV[$dev]:-}"

        MAP_POOL[$key]=""
        MAP_VDEV[$key]=""
        MAP_VDEV_STATE[$key]=""
        MAP_USED_BYTES[$key]=""
        MAP_TOTAL_BYTES[$key]="$size_bytes"
    done

    # Resolve pool/vdev membership by walking each pool's status once.
    _maps_attach_pool_info

    MAP_LOADED=1
}

# _size_to_bytes "447.130 GB" -> integer bytes
_size_to_bytes() {
    local s="$1"
    [[ -n "$s" ]] || { printf '0'; return; }
    awk -v s="$s" '
        BEGIN {
            n = s+0
            unit = ""
            if (match(s, /[KMGTP]B?/)) unit = substr(s, RSTART, RLENGTH)
            mult = 1
            if (unit ~ /^K/) mult = 1024
            else if (unit ~ /^M/) mult = 1024*1024
            else if (unit ~ /^G/) mult = 1024*1024*1024
            else if (unit ~ /^T/) mult = 1024*1024*1024*1024
            else if (unit ~ /^P/) mult = 1024*1024*1024*1024*1024
            printf "%.0f", n * mult
        }'
}

_maps_attach_pool_info() {
    local pool
    while IFS= read -r pool; do
        [[ -n "$pool" ]] || continue
        local txt; txt="$(zfs_pool_status_text "$pool")"
        # Build a quick lookup: device-path -> "vdev<TAB>state"
        # by walking the indented status output.
        local rows
        rows="$(awk '
            /^ *config:/ { inblk=1; next }
            /^ *errors:/ { inblk=0 }
            inblk {
                indent = match($0, /[^ \t]/) - 1
                if (indent < 1) next
                if (indent <= 4 && $1 ~ /^(mirror|raidz[0-9]?|draid|spare|replacing|log|cache|special|dedup)/) {
                    parent = $1
                }
                if ($1 ~ /^\//) {
                    state = $2
                    printf "%s\t%s\t%s\n", $1, parent, state
                }
            }
        ' <<< "$txt")"
        local p v st key
        while IFS=$'\t' read -r p v st; do
            [[ -n "$p" ]] || continue
            # Resolve symlink to underlying device.
            local resolved="$p"
            if [[ -L "$p" ]]; then resolved="$(readlink -f "$p" 2>/dev/null || echo "$p")"; fi
            for key in "${MAP_BAY_KEYS[@]}"; do
                local dev="${MAP_KERNEL_DEV[$key]}"
                local byid="${MAP_BY_ID[$key]}"
                if [[ -n "$dev"  && "$resolved" = "$dev" ]] || [[ -n "$byid" && "$p" = "$byid" ]] || [[ -n "$dev" && "$p" = "$dev" ]]; then
                    MAP_POOL[$key]="$pool"
                    MAP_VDEV[$key]="$v"
                    MAP_VDEV_STATE[$key]="$st"
                    break
                fi
            done
        done <<< "$rows"
    done < <(zfs_pool_names)
}

# resolve_bay <user-input> -> echoes "EID:Slot" or empty (via stdout); returns 0/1.
# Accepts "N" (slot only, default enclosure) or "EID:Slot" verbatim.
resolve_bay() {
    local input="$1"
    [[ -n "$input" ]] || return 1
    if [[ "$input" =~ ^[0-9]+:[0-9]+$ ]]; then
        printf '%s' "$input"; return 0
    fi
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then return 1; fi
    local eid="${ZB_ENCLOSURE:-}"
    if [[ -z "$eid" ]]; then eid="$(perccli_default_enclosure)"; fi
    if [[ -z "$eid" ]]; then
        log_error "ตรวจไม่พบ enclosure อัตโนมัติ — ระบุด้วย --enclosure / Detail: multiple or zero enclosures detected"
        return 1
    fi
    local nctrl; nctrl="$(perccli_count_controllers)"
    if [[ "${nctrl:-0}" =~ ^[0-9]+$ ]] && (( nctrl > 1 )); then
        log_error "หลาย controller พบ — ระบุด้วย --controller / Detail: $nctrl controllers detected"
        return 1
    fi
    printf '%s:%s' "$eid" "$input"
}

# Render-friendly: returns "32:4" or "4" depending on UI preference (we always print the full form).
bay_pretty() { printf '%s' "$1"; }

# map_pd_json_for_bay <bay>  -> echoes the cached PD object json (or empty).
map_pd_json_for_bay() { printf '%s' "${MAP_PD_JSON[$1]:-}"; }
