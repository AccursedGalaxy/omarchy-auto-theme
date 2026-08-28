#!/bin/bash
# Remove omarchy-auto-theme. Leaves ~/.config/omarchy/themes/matugen-auto in place
# (delete it yourself if you also want the theme and its backgrounds gone).
# Only files this project installed are removed; anything you modified is kept.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATUGEN_DIR="$HOME/.config/matugen"
# First line of the quattro.toml this project distributed in v1.0.0.
LEGACY_MARKER='# Matugen config for the omarchy-matugen adaptive theme.'

# Remove dst only if it is byte-identical to the version this repo distributes;
# a modified file is user data and stays put. Same rule for the .new copy a
# reinstall may have left beside it.
remove_owned() {
  local dst=$1 src=$2
  if [[ -f $dst ]]; then
    if cmp -s "$src" "$dst"; then
      rm -f "$dst"
    else
      echo "Kept $dst (you modified it; delete manually if unwanted)"
    fi
  fi
  if [[ -f $dst.new ]]; then
    if cmp -s "$src" "$dst.new"; then
      rm -f "$dst.new"
    else
      echo "Kept $dst.new (not identical to the distributed version; delete manually if unwanted)"
    fi
  fi
}

systemctl --user disable --now omarchy-matugen.path 2>/dev/null
systemctl --user disable --now omarchy-bg-rotate.timer 2>/dev/null
systemctl --user disable --now omarchy-we.service 2>/dev/null
systemctl --user disable --now omarchy-we-import.path 2>/dev/null
rm -f "$HOME/.config/systemd/user/omarchy-matugen.path" \
      "$HOME/.config/systemd/user/omarchy-matugen.service" \
      "$HOME/.config/systemd/user/omarchy-bg-rotate.timer" \
      "$HOME/.config/systemd/user/omarchy-bg-rotate.service" \
      "$HOME/.config/systemd/user/omarchy-we.service" \
      "$HOME/.config/systemd/user/omarchy-we-import.path" \
      "$HOME/.config/systemd/user/omarchy-we-import.service"
# The timer drop-in is generated state (from the ROTATE setting), ours to remove.
rm -rf "$HOME/.config/systemd/user/omarchy-bg-rotate.timer.d"
systemctl --user daemon-reload

rm -f "$HOME/.local/bin/omarchy-matugen-sync" \
      "$HOME/.local/bin/omarchy-auto-theme-we" \
      "$HOME/.local/state/omarchy/matugen-auto.last" \
      "$HOME/.local/state/omarchy/matugen-auto.we"
# Extracted video frames are generated state, ours to remove.
rm -rf "$HOME/.cache/omarchy-auto-theme"

# quattro.toml.new is only ours if it still carries the v1.0.0 header.
if [[ -f $MATUGEN_DIR/quattro.toml.new ]] \
   && [[ $(head -n1 "$MATUGEN_DIR/quattro.toml.new") == "$LEGACY_MARKER" ]]; then
  rm -f "$MATUGEN_DIR/quattro.toml.new"
fi

remove_owned "$MATUGEN_DIR/omarchy-auto-theme.toml" "$REPO_DIR/templates/omarchy-auto-theme.toml"
remove_owned "$MATUGEN_DIR/templates/omarchy-quattro-colors.toml" "$REPO_DIR/templates/omarchy-quattro-colors.toml"

# quattro.toml is only ours if it still carries the v1.0.0 header, and even
# then it may hold user-added template blocks, so never delete it silently.
if [[ -f $MATUGEN_DIR/quattro.toml ]] \
   && [[ $(head -n1 "$MATUGEN_DIR/quattro.toml") == "$LEGACY_MARKER" ]]; then
  echo "Kept $MATUGEN_DIR/quattro.toml (installed by v1.0.0; delete manually if you never customized it)"
fi

# Managed wallpaper collection: remove only the entries our manifest lists;
# files the user dropped into the dir by hand stay.
user_bgs="$HOME/.config/omarchy/backgrounds/matugen-auto"
# Imported Wallpaper Engine stills first (their own manifest, same rules).
if [[ -f $user_bgs/.omarchy-auto-theme-we ]]; then
  while IFS= read -r name; do
    [[ -n $name && $name != */* ]] && rm -f "$user_bgs/$name"
  done < <(tail -n +2 "$user_bgs/.omarchy-auto-theme-we")
  rm -f "$user_bgs/.omarchy-auto-theme-we"
  rmdir "$user_bgs" 2>/dev/null || true
fi
if [[ -f $user_bgs/.omarchy-auto-theme-source ]]; then
  while IFS= read -r name; do
    [[ -n $name && $name != */* ]] && rm -f "$user_bgs/$name"
  done < <(tail -n +2 "$user_bgs/.omarchy-auto-theme-source")
  rm -f "$user_bgs/.omarchy-auto-theme-source"
  rmdir "$user_bgs" 2>/dev/null \
    || echo "Kept $user_bgs (files you added; delete manually if unwanted)"
fi

# The settings file is user-created tuning, never installed by us.
[[ -f $HOME/.config/omarchy-auto-theme/settings ]] \
  && echo "Kept ~/.config/omarchy-auto-theme/settings (your tuning; delete manually if unwanted)"

echo "omarchy-auto-theme removed. Switch themes with: omarchy theme set <name>"
