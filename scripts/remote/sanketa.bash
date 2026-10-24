# Sanketa remote layers: sets the terminal title to ⟦sanketa host=… layers=…⟧ … so the Mac panel
# can show what runs on this host. Installed by sanketa's scripts/remote-setup.sh.

# __sanketa_title [command line]: emit the title for the prompt, or for the command about to run
__sanketa_title() {
    local layers=bash w h d=$PWD
    [ -n "${TMUX-}" ] && layers=$layers,tmux
    if [ -n "${1-}" ]; then
        w=${1%% *}; w=${w##*/}; w=${w//[^A-Za-z0-9._+-]/_}; w=${w:0:32}
        [ -n "$w" ] && [ "$w" != bash ] && layers=$layers,$w
    fi
    h=$(hostname -s 2>/dev/null || uname -n); h=${h//[^A-Za-z0-9._-]/_}; h=${h:0:64}
    case $d in "$HOME"*) d="~${d#"$HOME"}" ;; esac
    printf '\033]0;⟦sanketa host=%s layers=%s⟧ %s\007' "$h" "$layers" "${1:-$d}"
}

__sanketa_prompt() { __sanketa_title; __sanketa_ready=1; }

# DEBUG fires before every simple command; only the first one after a prompt is the user's.
__sanketa_debug() {
    [ -n "${__sanketa_ready-}" ] || return 0
    case $BASH_COMMAND in __sanketa_*) return 0 ;; esac
    __sanketa_ready=
    __sanketa_title "$BASH_COMMAND"
}

# hooks only in interactive shells: escape codes would corrupt scp/rsync sessions that read .bashrc
case $- in
*i*)
    case ";${PROMPT_COMMAND[*]-};" in
    *__sanketa_prompt*) ;;
    *) if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
           PROMPT_COMMAND+=(__sanketa_prompt)
       else
           PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;}__sanketa_prompt"
       fi ;;
    esac
    trap __sanketa_debug DEBUG ;;
esac
