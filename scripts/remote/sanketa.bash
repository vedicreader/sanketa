# Sanketa remote layers: sets the terminal title to ⟦sanketa host=… layers=…⟧ … so the Mac panel
# can show what runs on this host. Installed by sanketa's scripts/remote-setup.sh.

# __sanketa_title [command line]: emit the title for the prompt, or for the command about to run
__sanketa_title() {
    local layers=bash w h d=$PWD re='^[A-Za-z_][A-Za-z0-9_]*=' words
    [ -n "${TMUX-}" ] && layers=$layers,tmux
    if [ -n "${1-}" ]; then
        read -ra words <<< "$1"
        for w in "${words[@]}"; do [[ $w =~ $re ]] || break; done   # skip leading VAR=value
        [[ $w =~ $re ]] && w=
        w=${w##*/}; w=${w//[^A-Za-z0-9._+-]/_}; w=${w:0:32}
        [ -n "$w" ] && [ "$w" != bash ] && layers=$layers,$w
    fi
    h=${HOSTNAME%%.*}; h=${h//[^A-Za-z0-9._-]/_}; h=${h:0:64}
    case $d in "$HOME"*) d="~${d#"$HOME"}" ;; esac
    printf '\033]0;⟦sanketa host=%s layers=%s⟧ %s\007' "$h" "$layers" "${1:-$d}"
}

__sanketa_prompt() { __sanketa_title; __sanketa_ready=1; }
__sanketa_preexec() { __sanketa_ready=; __sanketa_title "$1"; }
__sanketa_status() { return "$1"; }
__sanketa_trap_command() { eval "set -- $1"; printf '%s' "$3"; }   # from `trap -- 'command' DEBUG`

# DEBUG fires before every simple command; only the first one after a prompt is the user's.
# A DEBUG trap that was there before (shell integration, timers) still runs first, with the same $?.
__sanketa_debug() {
    local s=$? r=0
    if [ -n "${__sanketa_prev_debug-}" ]; then
        __sanketa_status "$s"
        eval "$__sanketa_prev_debug"
        r=$?
    fi
    if [ -n "${__sanketa_ready-}" ]; then
        case $BASH_COMMAND in
        *__sanketa_*) ;;
        *) __sanketa_ready=; __sanketa_title "$BASH_COMMAND" ;;
        esac
    fi
    return $r
}

# Evaluated by PROMPT_COMMAND at top level. `source` and functions hide the DEBUG trap from `trap -p`
# and may restore it on return, so the first prompt is where an existing trap can be seen and chained.
__sanketa_on_prompt='
if [ -z "${__sanketa_hooked-}" ]; then
    __sanketa_hooked=1
    __sanketa_t=$(trap -p DEBUG)
    case $__sanketa_t in
    *__sanketa_debug*) ;;
    *) __sanketa_prev_debug=${__sanketa_t:+$(__sanketa_trap_command "$__sanketa_t")}
       trap __sanketa_debug DEBUG ;;
    esac
    unset __sanketa_t
fi
__sanketa_prompt'

# hooks only in interactive shells: escape codes would corrupt scp/rsync sessions that read .bashrc
case $- in
*i*)
    if [ -n "${bash_preexec_imported-}${__bp_imported-}" ]; then
        # bash-preexec owns the DEBUG trap; join it instead of replacing it
        case " ${preexec_functions[*]-} " in *" __sanketa_preexec "*) ;; *) preexec_functions+=(__sanketa_preexec) ;; esac
        case " ${precmd_functions[*]-} " in *" __sanketa_prompt "*) ;; *) precmd_functions+=(__sanketa_prompt) ;; esac
    else
        case ";${PROMPT_COMMAND[*]-};" in
        *__sanketa_on_prompt*) ;;
        *) if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
               PROMPT_COMMAND+=('eval "$__sanketa_on_prompt"')
           else
               PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}"'eval "$__sanketa_on_prompt"'
           fi ;;
        esac
    fi ;;
esac
