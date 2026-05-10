#!/usr/bin/env bats
# ZFS status parsing tests across multiple OpenZFS phrasings.

load test_helper

setup() {
    load_lib
}

@test "Healthy pool: zfs_pool_state == ONLINE" {
    local t; t="$(cat "$FIXTURES/zpool_status_healthy.txt")"
    run zfs_pool_state "$t"
    [ "$output" = "ONLINE" ]
}

@test "Degraded pool: zfs_pool_state == DEGRADED" {
    local t; t="$(cat "$FIXTURES/zpool_status_degraded.txt")"
    run zfs_pool_state "$t"
    [ "$output" = "DEGRADED" ]
}

@test "Resilver in progress, OpenZFS 2.x: percent and ETA extracted" {
    local t; t="$(cat "$FIXTURES/zpool_status_resilver.txt")"
    run zfs_parse_resilver "$t"
    [ "$status" -eq 0 ]
    local rip rpct reta rscan rtot rrate
    IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$output"
    [ "$rip" = "1" ]
    [ "$rpct" = "12.34" ]
    [ "$reta" = "11655" ]
    [ -n "$rtot" ]
}

@test "Resilver, OpenZFS 0.8 phrasing ('out of'): percent and ETA extracted" {
    local t; t="$(cat "$FIXTURES/zpool_status_resilver_v0_8.txt")"
    run zfs_parse_resilver "$t"
    local rip rpct reta rscan rtot rrate
    IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$output"
    [ "$rip" = "1" ]
    [ "$rpct" = "52.30" ]
    [ "$reta" = "11655" ]
}

@test "Resilver, OpenZFS 2.2 phrasing (no ETA): in_progress, percent set, ETA empty" {
    local t; t="$(cat "$FIXTURES/zpool_status_resilver_2_2.txt")"
    run zfs_parse_resilver "$t"
    local rip rpct reta rscan rtot rrate
    IFS='|' read -r rip rpct reta rscan rtot rrate <<< "$output"
    [ "$rip" = "1" ]
    [ "$rpct" = "19.55" ]
    [ -z "$reta" ]
}

@test "Healthy pool: no resilver" {
    local t; t="$(cat "$FIXTURES/zpool_status_healthy.txt")"
    run zfs_parse_resilver "$t"
    local rip _rest
    IFS='|' read -r rip _rest <<< "$output"
    [ "$rip" = "0" ]
}

@test "vdev tree parsing finds raidz1-0 as parent for FAULTED disk" {
    local t; t="$(cat "$FIXTURES/zpool_status_degraded.txt")"
    run awk '
        /^[[:space:]]*config:/  { inblk=1; next }
        /^[[:space:]]*errors:/  { inblk=0 }
        inblk && $1 == "/dev/disk/by-id/wwn-0x5000c5006b1afff8" { print parent; exit }
        inblk && $1 ~ /^(mirror|raidz[0-9]?|draid|spare|replacing)/ { parent = $1 }
    ' <<< "$t"
    [ "$output" = "raidz1-0" ]
}

@test "find available spare from a pool's status text" {
    # Stub zfs_pool_status_text so the helper reads our fixture.
    zfs_pool_status_text() { cat "$FIXTURES/zpool_status_with_spare.txt"; }
    run zfs_find_available_spare rpool
    [ "$status" -eq 0 ]
    [ "$output" = "/dev/disk/by-id/wwn-0x50000397dc901811" ]
}

@test "find available spare returns empty when no spares present" {
    zfs_pool_status_text() { cat "$FIXTURES/zpool_status_healthy.txt"; }
    run zfs_find_available_spare tank
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "redundancy floor: mirror -> 1, raidz1 -> 2, raidz2 -> 3" {
    run zfs_vdev_min_after_remove mirror-0
    [ "$output" = "1" ]
    run zfs_vdev_min_after_remove raidz1-0
    [ "$output" = "2" ]
    run zfs_vdev_min_after_remove raidz2-0
    [ "$output" = "3" ]
    run zfs_vdev_min_after_remove raidz3-0
    [ "$output" = "4" ]
}
