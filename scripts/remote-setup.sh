#!/bin/sh
# Install Sanketa's remote title-tag scripts on HOST so the panel shows that host's layers.
#   scripts/remote-setup.sh HOST       copy scripts/remote/* to HOST:~/.config/sanketa/remote/ and hook them up
# Testing only: SANKETA_SETUP_LOCAL_HOME=<dir> performs the same steps against <dir> as $HOME on this Mac,
# with no ssh or scp at all.
set -eu
marker='# sanketa remote layers'

# --install-here: hook up the copied files in this machine's $HOME (runs on HOST via `ssh HOST sh -s`)
if [ "${1-}" = --install-here ]; then
    r=.config/sanketa/remote
    cd "$HOME"
    mkdir -p .config/fish/conf.d
    if cmp -s "$r/sanketa.fish" .config/fish/conf.d/sanketa.fish; then
        echo "unchanged  ~/.config/fish/conf.d/sanketa.fish"
    else
        cp "$r/sanketa.fish" .config/fish/conf.d/sanketa.fish
        echo "copied     ~/.config/fish/conf.d/sanketa.fish"
    fi
    append() {
        if [ -f "$1" ] && grep -qF "$marker" "$1"; then
            echo "unchanged  ~/$1"
        else
            printf '\n%s\n%s\n' "$marker" "$2" >> "$1"
            echo "appended   ~/$1"
        fi
    }
    append .bashrc "[ -f ~/$r/sanketa.bash ] && . ~/$r/sanketa.bash"
    append .tmux.conf "source-file -q ~/$r/tmux.conf"
    echo "open a new shell; in a running tmux: tmux source-file ~/.tmux.conf"
    exit 0
fi

if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "usage: $0 HOST   (any ssh destination, e.g. me@gpubox)" >&2
    exit 2
fi
host=$1
src=$(cd "$(dirname "$0")/remote" && pwd)

if [ -n "${SANKETA_SETUP_LOCAL_HOME-}" ]; then
    mkdir -p "$SANKETA_SETUP_LOCAL_HOME/.config/sanketa/remote"
    cp "$src/sanketa.fish" "$src/sanketa.bash" "$src/tmux.conf" "$SANKETA_SETUP_LOCAL_HOME/.config/sanketa/remote/"
    echo "copied     ~/.config/sanketa/remote/{sanketa.fish,sanketa.bash,tmux.conf} (local test home)"
    HOME=$SANKETA_SETUP_LOCAL_HOME sh "$0" --install-here
else
    ssh "$host" 'mkdir -p ~/.config/sanketa/remote'
    scp -q "$src/sanketa.fish" "$src/sanketa.bash" "$src/tmux.conf" "$host:.config/sanketa/remote/"
    echo "copied     $host:~/.config/sanketa/remote/{sanketa.fish,sanketa.bash,tmux.conf}"
    ssh "$host" sh -s -- --install-here < "$0"
fi
