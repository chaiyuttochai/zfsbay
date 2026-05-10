#!/usr/bin/env bash
# Common helpers for bats tests.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export ZFSBAY_LIB="$REPO_ROOT/lib"
export FIXTURES="$REPO_ROOT/test/fixtures"

# Stub out global state that lib/common.sh expects.
export ZB_DRY_RUN=1 ZB_VERBOSE=0 ZB_QUIET=1 ZB_JSON=0 ASSUME_YES=1
export ZB_USE_COLOR=0
declare -gA ZB_FLAGS=( [refresh]=0 [json]=0 [yes]=1 [dry_run]=1 [no_color]=1 \
    [verbose]=0 [quiet]=1 [force]=0 [force_boot]=0 [clear_foreign]=0 [delete_vd]=0 )
declare -ga ZB_POSITIONAL=()
export ZB_CONTROLLER=0 ZB_ENCLOSURE=32

# Color vars must exist (referenced by ui.sh, common.sh)
c_red=""; c_yellow=""; c_green=""; c_dim=""; c_bold=""; c_reset=""

# Source the libs we need.
load_lib() {
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/common.sh"
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/ui.sh"
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/perccli.sh"
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/smartctl.sh"
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/zfs.sh"
    # shellcheck source=/dev/null
    source "$ZFSBAY_LIB/mapping.sh"
    # Re-stub colors after sourcing.
    c_red=""; c_yellow=""; c_green=""; c_dim=""; c_bold=""; c_reset=""
}

# Run zfsbay from the repo (no install).
zfsbay_cmd() {
    "$REPO_ROOT/zfsbay" "$@"
}
