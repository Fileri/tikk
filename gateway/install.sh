#!/bin/sh
# tikk gateway installer — run ON THE MAC from a checkout of this repo.
#
#   sh gateway/install.sh [path/to/tikk_ed25519.pub] [linux-box-ip]
#
# Copies tikk-dispatch and tikk-reminders to ~/.tikk/bin with sane modes,
# checks for reminders-cli, and prints the authorized_keys line to add. It
# never edits authorized_keys itself and never asks for sudo.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.tikk/bin"
pub=${1:-}
from=${2:-<linux-box-ip>}

umask 077
mkdir -p "$HOME/.tikk"
chmod 700 "$HOME/.tikk"
mkdir -p "$dest"
chmod 755 "$dest"
for f in tikk-dispatch tikk-reminders; do
  cp "$here/$f" "$dest/$f.tmp" && chmod 755 "$dest/$f.tmp" && mv "$dest/$f.tmp" "$dest/$f"
done
echo "installed: $dest/tikk-dispatch, $dest/tikk-reminders ($("$dest/tikk-reminders" --version))"

if ! command -v reminders >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/reminders ] && [ ! -x /usr/local/bin/reminders ]; then
  echo "missing: reminders-cli — brew install keith/formulae/reminders-cli" >&2
fi

if [ -n "$pub" ] && [ -r "$pub" ]; then
  key=$(cat "$pub")
else
  key="ssh-ed25519 AAAA... tikk@linux-box"
fi
cat <<EOF

Add this line to ~/.ssh/authorized_keys on this Mac (one line):

restrict,command="\$HOME/.tikk/bin/tikk-dispatch",from="$from" $key

Then, from the Linux box:  ssh -i ~/.ssh/tikk_ed25519 $(id -un)@<this-mac> check
If check reports no Reminders access, run this on the Mac over ssh and click Allow on its screen:
  osascript -e 'tell application "Reminders" to get name of lists'
EOF
