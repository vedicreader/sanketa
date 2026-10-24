# Sanketa remote layers: prefixes the terminal title with ⟦sanketa host=… layers=…⟧ so the Mac panel
# can show what runs on this host. Installed by sanketa's scripts/remote-setup.sh.
functions -q __sanketa_default_title; or functions -c fish_title __sanketa_default_title

function fish_title
    set -l layers fish
    set -q TMUX; and set -a layers tmux
    # fish passes an override for the running command as $argv[1] (e.g. from `fg`)
    set -l cmd (status current-command)
    if set -q argv[1]
        # first word that isn't a leading VAR=value assignment (fish 3.0-compatible)
        set -l words (string match -rv '^[A-Za-z_][A-Za-z0-9_]*=' -- (string split ' ' -- (string trim -- $argv[1])))
        set cmd $words[1]
    end
    set cmd (string replace -r '.*/' '' -- $cmd)
    if test -n "$cmd"; and test "$cmd" != fish
        set -a layers (string replace -ra '[^A-Za-z0-9._+-]' _ -- $cmd | string sub -l 32)
    end
    set -l host (string replace -r '\..*' '' -- $hostname | string replace -ra '[^A-Za-z0-9._-]' _ | string sub -l 64)
    printf '⟦sanketa host=%s layers=%s⟧ ' $host (string join , -- $layers)
    __sanketa_default_title $argv
end
