#!/usr/bin/env bats
# Mapping resolver tests — verify that PD JSON parsing, bay-key indexing,
# and resolve_bay() behave correctly with fixtures.

load test_helper

setup() {
    load_lib
    PERCCLI_PD_JSON="$(cat "$FIXTURES/perccli_show_all.json")"
    PERCCLI_VD_JSON="$(cat "$FIXTURES/perccli_vall.json")"
    PERCCLI_FOREIGN_JSON="$(cat "$FIXTURES/perccli_foreign_empty.json")"
}

@test "perccli_pd_array extracts 5 PD entries" {
    local n; n="$(perccli_pd_array | jq length)"
    [ "$n" = "5" ]
}

@test "perccli_pd_lookup_by_eid_slot finds bay 32:0 (Intel)" {
    run perccli_pd_lookup_by_eid_slot 32 0
    [[ "$output" = *INTEL* ]]
    [[ "$output" = *Onln* ]]
}

@test "perccli_pd_lookup_by_eid_slot returns empty for missing bay" {
    run perccli_pd_lookup_by_eid_slot 32 99
    [ -z "$output" ]
}

@test "perccli_default_enclosure returns 32 for our fixture" {
    run perccli_default_enclosure
    [ "$output" = "32" ]
}

@test "perccli_foreign_count: 0 with empty fixture" {
    run perccli_foreign_count
    [ "$output" = "0" ]
}

@test "perccli_foreign_count: >=1 with foreign-present fixture" {
    PERCCLI_FOREIGN_JSON="$(cat "$FIXTURES/perccli_foreign_present.json")"
    run perccli_foreign_count
    [[ "$output" -ge 1 ]]
}

@test "_size_to_bytes 446.625 GB ~= 479G in bytes" {
    run _size_to_bytes "446.625 GB"
    # 446.625 * 1024^3 = 479559477657.6 ish
    [[ "$output" -gt 479000000000 ]]
    [[ "$output" -lt 480000000000 ]]
}

@test "_size_to_bytes 3.637 TB" {
    run _size_to_bytes "3.637 TB"
    [[ "$output" -gt 3990000000000 ]]
    [[ "$output" -lt 4010000000000 ]]
}

@test "_strip_wwn normalizes 0x prefix and uppercase" {
    run _strip_wwn 0x5000C5006B1A4FB8
    [ "$output" = "5000c5006b1a4fb8" ]
}

@test "resolve_bay accepts EID:Slot form verbatim" {
    run resolve_bay "32:4"
    [ "$output" = "32:4" ]
}

@test "resolve_bay treats bare digit as slot, defaulting enclosure to 32" {
    ZB_ENCLOSURE=32
    run resolve_bay "4"
    [ "$output" = "32:4" ]
}

@test "resolve_bay rejects non-numeric input" {
    run resolve_bay "abc"
    [ "$status" -ne 0 ]
}
