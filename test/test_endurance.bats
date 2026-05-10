#!/usr/bin/env bats
# Endurance dispatcher / per-vendor tests.

load test_helper

setup() {
    load_lib
}

@test "smart_attr_value extracts normalized value for Intel attr 233" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    run smart_attr_value "$text" 233
    [ "$output" = "85" ]
}

@test "smart_attr_value extracts normalized value for Samsung attr 177" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_samsung.txt")"
    run smart_attr_value "$text" 177
    [ "$output" = "92" ]
}

@test "smart_attr_value returns empty for non-existent attribute" {
    local text="ID# ATTRIBUTE_NAME ..."
    run smart_attr_value "$text" 999
    [ -z "$output" ]
}

@test "smart_attr_raw extracts raw value for power-on hours (attr 9)" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    run smart_attr_raw "$text" 9
    [ "$output" = "18234" ]
}

@test "Micron-style 202 takes precedence over 177 when both present" {
    # Synthesize: 202 normalized=70, 177 normalized=99 => endurance=70
    local synth='ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
177 Wear_Leveling_Count     0x0013   099   099   000    Pre-fail  Always       -       1
202 Percent_Lifetime_Remain 0x0032   070   070   000    Old_age   Always       -       30'
    run smart_endurance_pct_sata "$synth"
    [ "$output" = "70" ]
}

@test "Endurance dispatcher returns N/A for HDD media" {
    run smart_endurance_for_drive sas hdd 5
    [ "$output" = "N/A" ]
}

@test "Endurance returns ? when nothing parseable" {
    run smart_endurance_pct_sata "no smart attrs here"
    [ "$output" = "?" ]
}
