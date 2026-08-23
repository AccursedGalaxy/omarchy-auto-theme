#!/bin/bash
# omarchy-auto-theme installer — wallpaper-adaptive theming for Omarchy >= 4.0 (Quattro).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_DIR="$HOME/.config/omarchy/themes/matugen-auto"
MATUGEN_DIR="$HOME/.config/matugen"
CONFIG="$MATUGEN_DIR/omarchy-auto-theme.toml"
TEMPLATE="$MATUGEN_DIR/templates/omarchy-quattro-colors.toml"
OMARCHY_SHARE="${OMARCHY_PATH:-/usr/share/omarchy}"
# First line of the quattro.toml this project distributed in v1.0.0.
LEGACY_MARKER='# Matugen config for the omarchy-matugen adaptive theme.'

say() { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mNote:\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# Install src to dst, but never clobber a user-modified dst: an existing dst
# that differs from src is kept, and the new version lands at dst.new instead.
install_config() {
  local src=$1 dst=$2
  if [[ -f $dst ]] && ! cmp -s "$src" "$dst"; then
    warn "Keeping your customized $(basename "$dst") (new version at $(basename "$dst").new)"
    cp "$src" "$dst.new"
  else
    cp "$src" "$dst"
  fi
}

# --- Preflight -------------------------------------------------------------
command -v matugen >/dev/null || fail "matugen not found. Install it first: omarchy pkg aur add matugen-bin"
command -v omarchy-theme-refresh >/dev/null || fail "omarchy-theme-refresh not found. This tool needs Omarchy 4.0 (Quattro) or newer."
[[ -d $OMARCHY_SHARE/themes ]] || fail "Omarchy 4.x layout not found under $OMARCHY_SHARE. Upgrade to Quattro first."

# --- Files -----------------------------------------------------------------
say "Installing matugen template and config"
mkdir -p "$MATUGEN_DIR/templates" "$MATUGEN_DIR/generated"
install_config "$REPO_DIR/templates/omarchy-quattro-colors.toml" "$TEMPLATE"
install_config "$REPO_DIR/templates/omarchy-auto-theme.toml" "$CONFIG"

# Migrate away from the shared quattro.toml that v1.0.0 used. Only files that
# carry our distributed header are touched; anything else is the user's.
if [[ -f $MATUGEN_DIR/quattro.toml.new ]] \
   && [[ $(head -n1 "$MATUGEN_DIR/quattro.toml.new") == "$LEGACY_MARKER" ]]; then
  rm -f "$MATUGEN_DIR/quattro.toml.new"
fi
if [[ -f $MATUGEN_DIR/quattro.toml ]]; then
  if [[ $(head -n1 "$MATUGEN_DIR/quattro.toml") == "$LEGACY_MARKER" ]]; then
    backup="$MATUGEN_DIR/quattro.toml.bak"
    n=0
    while [[ -e $backup ]]; do
      n=$((n + 1)); backup="$MATUGEN_DIR/quattro.toml.bak.$n"
    done
    mv "$MATUGEN_DIR/quattro.toml" "$backup"
    warn "This project now uses its own config: $CONFIG"
    warn "Your old quattro.toml was moved to $(basename "$backup") — if you added custom [templates.*] blocks, copy them into the new config."
  else
    warn "quattro.toml in ~/.config/matugen is no longer used by this project and was left untouched."
  fi
fi

# The sync script and systemd units are project-owned executables: installs
# overwrite them and uninstall removes them. User tuning belongs in the
# settings file the script sources, which we never touch.
say "Installing sync script"
install -Dm755 "$REPO_DIR/bin/omarchy-matugen-sync" "$HOME/.local/bin/omarchy-matugen-sync"

say "Installing theme skeleton"
mkdir -p "$THEME_DIR/backgrounds"

# Seed backgrounds so the theme is usable immediately. Point Omarchy's
# user-background dir at your own wallpaper folder to use that instead:
#   ln -sfn ~/Pictures/Wallpapers ~/.config/omarchy/backgrounds/matugen-auto
user_bgs="$HOME/.config/omarchy/backgrounds/matugen-auto"
# -print -quit: find stops itself at the first hit — no pipe, no pipefail/
# SIGPIPE hazard that a `| grep -q .` construction would carry.
existing_bg=$(find "$THEME_DIR/backgrounds" "$(readlink -f "$user_bgs" 2>/dev/null || echo /nonexistent)" -type f -print -quit 2>/dev/null || true)
if [[ -z $existing_bg ]]; then
  say "Seeding starter backgrounds from the stock tokyo-night theme"
  cp "$OMARCHY_SHARE"/themes/tokyo-night/backgrounds/* "$THEME_DIR/backgrounds/" 2>/dev/null || true
fi

# Generate an initial colors.toml so `omarchy theme set` has something to load,
# and prove the config actually renders our template before enabling anything.
seed_bg=$(find "$THEME_DIR/backgrounds" "$(readlink -f "$user_bgs" 2>/dev/null || echo /nonexistent)" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.webp' \) -print -quit 2>/dev/null || true)
[[ -n $seed_bg ]] || fail "No background image found to seed colors from. Put a wallpaper in $THEME_DIR/backgrounds/ and rerun."
say "Generating initial colors from $(basename "$seed_bg")"
# Honor the same user settings the sync script reads (a trusted bash fragment).
PREFER=saturation MODE=dark
# shellcheck source=/dev/null
[[ -f $HOME/.config/omarchy-auto-theme/settings ]] && source "$HOME/.config/omarchy-auto-theme/settings"
case $MODE in dark|light) ;; *) fail "invalid MODE '$MODE' in ~/.config/omarchy-auto-theme/settings (dark|light)" ;; esac
[[ $PREFER =~ ^[a-zA-Z0-9_-]+$ ]] || fail "invalid PREFER '$PREFER' in ~/.config/omarchy-auto-theme/settings"
# A leftover colors.toml from an earlier install would make a broken config
# look like success — require the output to be new or freshly rewritten.
colors_before=$(stat -c '%.Y' "$THEME_DIR/colors.toml" 2>/dev/null || echo missing)
matugen image "$seed_bg" --config "$CONFIG" --mode "$MODE" --prefer "$PREFER"
colors_after=$(stat -c '%.Y' "$THEME_DIR/colors.toml" 2>/dev/null || echo missing)
[[ -s $THEME_DIR/colors.toml && $colors_after != "$colors_before" ]] \
  || fail "matugen ran but $THEME_DIR/colors.toml was not (re)generated. Check the [templates.omarchy_quattro] block in $CONFIG."

# --- systemd watcher -------------------------------------------------------
say "Installing systemd user units"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/omarchy-matugen.path" "$REPO_DIR/systemd/omarchy-matugen.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-matugen.path

# One-shot service run: proves the sync script starts in the systemd
# environment (PATH, unit file, script location) rather than just in this
# shell. It is only a launch check — while another theme is active the script
# exits before touching matugen; `omarchy-matugen-sync --diagnose` covers the
# full pipeline.
systemctl --user start omarchy-matugen.service \
  || fail "omarchy-matugen.service failed its validation run. Inspect with: journalctl --user -u omarchy-matugen.service"

say "Done. Activate with: omarchy theme set matugen-auto"
say "Then change wallpapers with SUPER+CTRL+SPACE — colors follow automatically."
