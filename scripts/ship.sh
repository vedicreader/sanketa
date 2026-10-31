#!/bin/sh
# usage: V=<version> TAP=<tap folder> MAKE=<make> scripts/ship.sh, from the repo folder (make ship does this). One release
# of Sanketa.app. Adapted from Abhyasa's mac/scripts/ship.sh.
# The local steps are all or nothing: when a step fails before the commit, Info.plist goes back as it was.
# The remote steps can run again: the version is set only when Info.plist has another version, a commit is made only when
# a file changed, a push with nothing new does nothing, and publish is skipped when v<V> is on GitHub already. So after a
# failure, run make ship V=<version> again.
set -eu
: "${V:?Give the version: make ship V=<version>}"
: "${TAP:?TAP is the folder of the Homebrew tap}"
MAKE=${MAKE:-make}
unset GITHUB_TOKEN   # the keyring of gh signs in; a stale token in the environment would win over it
PLIST=Resources/Info.plist
push() { git -C "$1" -c credential.helper= -c "credential.helper=!gh auth git-credential" push; }

# publish makes the release with --target main, so ship runs on main only
test "$(git branch --show-current)" = main || { echo "make ship runs on main only" >&2; exit 1; }
test -z "$(git status --porcelain)" || { echo "sanketa has changes that are not committed" >&2; exit 1; }
test -z "$(git -C "$TAP" status --porcelain)" || { echo "$TAP has changes that are not committed" >&2; exit 1; }

# the tests run first, before a file changes
"$MAKE" test

committed=0 shipped=0
undo() {
  test $shipped = 1 && return
  if test $committed = 1; then echo "make ship stopped after the commit. Run make ship V=$V again to finish." >&2; return; fi
  git checkout -- "$PLIST"
  echo "make ship stopped. The files are as they were before. Run make ship V=$V again." >&2
}
trap 'undo' EXIT

# a new version also adds 1 to the build number; on a second run Info.plist has V already and stays as it is
if test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" != "$V"; then
  build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" -c "Set :CFBundleVersion $((build + 1))" "$PLIST"
fi
grep -A1 -E 'CFBundle(ShortVersionString|Version)<' "$PLIST"
git add "$PLIST"
git diff --cached --quiet || git commit -m "Version $V"
committed=1

# gh release create --target main makes the tag on the main of GitHub, so main goes there first
push .
# ZIP is exported with the name of the old version; with it unset, publish and cask make the name from the new Info.plist
if gh release view "v$V" >/dev/null 2>&1; then echo "v$V is on GitHub already, so ship does not build or publish it again"
else env -u ZIP "$MAKE" publish; fi
env -u ZIP "$MAKE" cask

git -C "$TAP" add Casks/sanketa.rb
git -C "$TAP" diff --cached --quiet || git -C "$TAP" commit -m "Sanketa $V"
push "$TAP"
shipped=1
echo "Sanketa $V is shipped."
