#!/bin/bash
# omarchy-auto-theme installer — wallpaper-adaptive theming for Omarchy >= 4.0 (Quattro).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_DIR="$HOME/.config/omarchy/themes/matugen-auto"

say() { printf '\033[32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
command -v matugen >/dev/null || fail "matugen not found. Install it first: omarchy pkg aur add matugen-bin"
command -v omarchy-theme-refresh >/dev/null || fail "omarchy-theme-refresh not found. This tool needs Omarchy 4.0 (Quattro) or newer."
[[ -d /usr/share/omarchy/themes ]] || fail "Omarchy 4.x layout not found under /usr/share/omarchy. Upgrade to Quattro first."

# --- Files -----------------------------------------------------------------
say "Installing matugen template and config"
mkdir -p "$HOME/.config/matugen/templates" "$HOME/.config/matugen/generated"
cp "$REPO_DIR/templates/omarchy-quattro-colors.toml" "$HOME/.config/matugen/templates/"
if [[ -f $HOME/.config/matugen/quattro.toml ]]; then
  say "Keeping existing ~/.config/matugen/quattro.toml (new version at quattro.toml.new)"
  cp "$REPO_DIR/templates/quattro.toml" "$HOME/.config/matugen/quattro.toml.new"
else
  cp "$REPO_DIR/templates/quattro.toml" "$HOME/.config/matugen/quattro.toml"
fi

say "Installing sync script"
mkdir -p "$HOME/.local/bin"
cp "$REPO_DIR/bin/omarchy-matugen-sync" "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/omarchy-matugen-sync"

say "Installing theme skeleton"
mkdir -p "$THEME_DIR/backgrounds"

# Seed backgrounds so the theme is usable immediately. Point Omarchy's
# user-background dir at your own wallpaper folder to use that instead:
#   ln -sfn ~/Pictures/Wallpapers ~/.config/omarchy/backgrounds/matugen-auto
user_bgs="$HOME/.config/omarchy/backgrounds/matugen-auto"
if ! find "$THEME_DIR/backgrounds" "$(readlink -f "$user_bgs" 2>/dev/null || echo /nonexistent)" -type f 2>/dev/null | grep -q .; then
  say "Seeding starter backgrounds from the stock tokyo-night theme"
  cp /usr/share/omarchy/themes/tokyo-night/backgrounds/* "$THEME_DIR/backgrounds/" 2>/dev/null || true
fi

# Generate an initial colors.toml so `omarchy theme set` has something to load.
seed_bg=$(find "$THEME_DIR/backgrounds" "$(readlink -f "$HOME/.config/omarchy/backgrounds/matugen-auto" 2>/dev/null || true)" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.jpeg' -o -iname '*.webp' \) 2>/dev/null | head -1)
[[ -n $seed_bg ]] || fail "No background image found to seed colors from. Put a wallpaper in $THEME_DIR/backgrounds/ and rerun."
say "Generating initial colors from $(basename "$seed_bg")"
matugen image "$seed_bg" --config "$HOME/.config/matugen/quattro.toml" --mode dark --prefer saturation

# --- systemd watcher -------------------------------------------------------
say "Installing systemd user units"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/omarchy-matugen.path" "$REPO_DIR/systemd/omarchy-matugen.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-matugen.path

say "Done. Activate with: omarchy theme set matugen-auto"
say "Then change wallpapers with SUPER+CTRL+SPACE — colors follow automatically."
