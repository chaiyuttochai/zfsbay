#!/usr/bin/env bats
# Top-level CLI smoke tests — entrypoint, help, --json schemas.

load test_helper

@test "zfsbay version prints 0.x.y" {
    run zfsbay_cmd version
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^zfsbay\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "zfsbay --version JSON" {
    run zfsbay_cmd --json version
    [ "$status" -eq 0 ]
    run jq -e .version <<< "$output"
    [ "$status" -eq 0 ]
}

@test "zfsbay help prints subcommand list" {
    run zfsbay_cmd help
    [ "$status" -eq 0 ]
    [[ "$output" = *"pool status"* ]]
    [[ "$output" = *"bay status"* ]]
    [[ "$output" = *"check sync"* ]]
    [[ "$output" = *"locate"* ]]
}

@test "unknown subcommand exits 2" {
    run zfsbay_cmd nonsense
    [ "$status" -eq 2 ]
}

@test "unknown flag exits 2" {
    run zfsbay_cmd --no-such-flag version
    [ "$status" -eq 2 ]
}

@test "pool status --json on system without ZFS yields {pools: []}" {
    run zfsbay_cmd --json pool status
    [ "$status" -eq 0 ]
    run jq -e '.pools | type == "array"' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "check sync --json yields {pools: []} when no zpool" {
    run zfsbay_cmd --json check sync
    [ "$status" -eq 0 ]
    run jq -e '.pools | type == "array"' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "bay status --json yields {controller, enclosure, bays}" {
    # Without perccli on this dev box, bays will be empty — that's fine.
    run zfsbay_cmd --json bay status
    [ "$status" -eq 0 ]
    run jq -e '.controller != null and (.bays | type == "array")' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "state-changing ops refused without root or without resolvable bay" {
    # On a dev box (no perccli, no zpool, non-root), bay <N> remove must NOT proceed
    # to actually mutate state. Acceptable failures: 2 (cannot resolve bay), 3 (no
    # perccli), 4 (not root), 5 (hardware error).
    skip_if_root
    run zfsbay_cmd --dry-run bay 0 remove
    case "$status" in 2|3|4|5) ;; *) false ;; esac
}

skip_if_root() {
    if [ "$(id -u)" -eq 0 ]; then skip "running as root"; fi
}
