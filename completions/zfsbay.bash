# bash completion for zfsbay
# Source from /etc/bash_completion.d/ or ~/.bashrc

_zfsbay_complete() {
    local cur prev words cword
    _init_completion 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    local subs="pool bay check locate version help"
    local flags="--json --yes --dry-run --no-color --verbose --quiet --refresh --force --force-boot --clear-foreign --delete-vd --controller --enclosure --config"

    if (( cword == 1 )); then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "$subs $flags" -- "$cur") )
        return
    fi

    case "${words[1]}" in
        pool)
            if (( cword == 2 )); then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "status" -- "$cur") )
            elif (( cword == 3 )) && [[ "${words[2]}" = "status" ]]; then
                local pools=""
                command -v zpool >/dev/null 2>&1 && pools="$(zpool list -H -o name 2>/dev/null)"
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$pools" -- "$cur") )
            fi
            ;;
        bay)
            if (( cword == 2 )); then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "status 0 1 2 3 4 5 6 7 8 9 10 11" -- "$cur") )
            elif (( cword == 3 )) && [[ "${words[2]}" != "status" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "remove replace join" -- "$cur") )
            elif (( cword == 4 )) && [[ "${words[3]}" = "join" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "pool" -- "$cur") )
            elif (( cword == 5 )) && [[ "${words[3]}" = "join" ]] && [[ "${words[4]}" = "pool" ]]; then
                local pools=""
                command -v zpool >/dev/null 2>&1 && pools="$(zpool list -H -o name 2>/dev/null)"
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "$pools" -- "$cur") )
            elif (( cword == 6 )) && [[ "${words[3]}" = "join" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "as" -- "$cur") )
            fi
            ;;
        check)
            if (( cword == 2 )); then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "sync" -- "$cur") )
            elif (( cword == 3 )) && [[ "${words[2]}" = "sync" ]]; then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "bay" -- "$cur") )
            fi
            ;;
        locate)
            if (( cword == 3 )); then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "on off" -- "$cur") )
            fi
            ;;
        help)
            if (( cword == 2 )); then
                # shellcheck disable=SC2207
                COMPREPLY=( $(compgen -W "pool bay check locate" -- "$cur") )
            fi
            ;;
    esac

    if [[ "$cur" = -* ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
    fi
}

complete -F _zfsbay_complete zfsbay
