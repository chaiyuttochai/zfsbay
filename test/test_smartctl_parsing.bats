#!/usr/bin/env bats
# SMART parsing tests — verify endurance, health, attribute extraction
# work for SATA SSDs (multiple vendors), SAS SSD, NVMe, and HDD.

load test_helper

setup() {
    load_lib
}

@test "Intel SATA SSD: endurance from attribute 233 = 85" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    run smart_endurance_pct_sata "$text"
    [ "$status" -eq 0 ]
    [ "$output" = "85" ]
}

@test "Samsung SATA SSD: endurance from attribute 177 = 92" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_samsung.txt")"
    run smart_endurance_pct_sata "$text"
    [ "$status" -eq 0 ]
    [ "$output" = "92" ]
}

@test "SAS SSD: endurance from -l ssd output (12% used -> 88% left)" {
    local text; text="$(cat "$FIXTURES/smartctl_sas_ssd.txt")"
    run smart_endurance_pct_sas_ssd "$text"
    [ "$status" -eq 0 ]
    [ "$output" = "88" ]
}

@test "NVMe: endurance from Percentage Used (7 -> 93)" {
    local text; text="$(cat "$FIXTURES/smartctl_nvme.txt")"
    run smart_endurance_pct_nvme "$text"
    [ "$status" -eq 0 ]
    [ "$output" = "93" ]
}

@test "NVMe: endurance from nvme cli json field percentage_used" {
    local text="percentage_used : 4"
    run smart_endurance_pct_nvme "$text"
    [ "$status" -eq 0 ]
    [ "$output" = "96" ]
}

@test "HDD endurance is N/A via dispatcher" {
    run smart_endurance_for_drive "SAS" "HDD" "10"
    [ "$status" -eq 0 ]
    [ "$output" = "N/A" ]
}

@test "smart_overall: PASSED for SATA SSD fixture" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    run smart_overall "$text"
    [ "$output" = "PASSED" ]
}

@test "smart_overall: PASSED for SAS SSD (Health Status: OK)" {
    local text; text="$(cat "$FIXTURES/smartctl_sas_ssd.txt")"
    run smart_overall "$text"
    [ "$output" = "PASSED" ]
}

@test "smart_health_pct: Intel fixture -> 100" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    run smart_health_pct "$text" ""
    [ "$status" -eq 0 ]
    [ "$output" = "100" ]
}

@test "smart_health_pct: PERC PD with media errors deducts 10" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    local pd='{"Media Error Count": 5, "Other Error Count": 0, "Predictive Failure Count": 0}'
    run smart_health_pct "$text" "$pd"
    [ "$status" -eq 0 ]
    [ "$output" = "90" ]
}

@test "smart_health_pct: predictive failure count drops score by 50" {
    local text; text="$(cat "$FIXTURES/smartctl_sata_ssd_intel.txt")"
    local pd='{"Media Error Count": 0, "Other Error Count": 0, "Predictive Failure Count": 1}'
    run smart_health_pct "$text" "$pd"
    [ "$output" = "50" ]
}

@test "smart_temperature parses 'Current Drive Temperature: 34 C'" {
    local text; text="$(cat "$FIXTURES/smartctl_sas_ssd.txt")"
    run smart_temperature "$text"
    [ "$output" = "34" ]
}
