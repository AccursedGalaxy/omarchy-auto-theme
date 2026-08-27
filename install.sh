#!/bin/bash
# omarchy-auto-theme installer: wallpaper-adaptive theming for Omarchy >= 4.0 (Quattro).
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
fail() {
  printf '\033[31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: ./install.sh [--wallpapers DIR]

  --wallpapers DIR  Use your own wallpaper folder for the matugen-auto theme.
                    Links DIR as the theme's background collection instead of
                    seeding starter images.
EOF
}

WALLPAPERS=""
while [[ $# -gt 0 ]]; do
  case $1 in
  --wallpapers)
    [[ -n ${2:-} ]] || fail "--wallpapers needs a directory argument"
    WALLPAPERS=$2
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "unknown option: $1"
    ;;
  esac
done

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
if [[ -f $MATUGEN_DIR/quattro.toml.new ]] &&
  [[ $(head -n1 "$MATUGEN_DIR/quattro.toml.new") == "$LEGACY_MARKER" ]]; then
  rm -f "$MATUGEN_DIR/quattro.toml.new"
fi
if [[ -f $MATUGEN_DIR/quattro.toml ]]; then
  if [[ $(head -n1 "$MATUGEN_DIR/quattro.toml") == "$LEGACY_MARKER" ]]; then
    backup="$MATUGEN_DIR/quattro.toml.bak"
    n=0
    while [[ -e $backup ]]; do
      n=$((n + 1))
      backup="$MATUGEN_DIR/quattro.toml.bak.$n"
    done
    mv "$MATUGEN_DIR/quattro.toml" "$backup"
    warn "This project now uses its own config: $CONFIG"
    warn "Your old quattro.toml was moved to $(basename "$backup"). If you added custom [templates.*] blocks, copy them into the new config."
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

user_bgs="$HOME/.config/omarchy/backgrounds/matugen-auto"

# --wallpapers: adopt the user's folder as the background collection. Images
# are hardlinked (copied across filesystems) into a real managed dir, never a
# dir symlink: omarchy-theme-bg-set stores the background through realpath
# while omarchy-theme-bg-next compares unresolved paths, so behind a symlink
# every "next" pins to the first image.
# The marker file is a manifest: line 1 is the source folder, the rest are
# the basenames we linked. Refreshes touch only listed names. This dir is
# also Omarchy's drop-zone for user backgrounds; hand-added files must never
# be deleted.
MANAGED_MARKER=".omarchy-auto-theme-source"
img_find() { # dir [find-action...]
  local dir=$1
  shift
  find "$dir" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) "$@" 2>/dev/null || true
}
adopted=""
if [[ -z $WALLPAPERS ]]; then
  if [[ -L $user_bgs ]]; then
    # v1.1.0 linked the whole dir; adopt the target so a plain rerun still
    # migrates it (the bg-next fix must reach flagless upgraders).
    WALLPAPERS=$(readlink -f "$user_bgs" 2>/dev/null || true)
    adopted=1
  elif [[ -f $user_bgs/$MANAGED_MARKER ]]; then
    # Refresh from the recorded source so newly added images are picked up.
    WALLPAPERS=$(head -n1 "$user_bgs/$MANAGED_MARKER")
    adopted=1
  fi
fi
if [[ -n $WALLPAPERS ]]; then
  src=$(readlink -f "$WALLPAPERS" 2>/dev/null || true)
  src_err=""
  if [[ -z $src || ! -d $src ]]; then
    src_err="not a directory: $WALLPAPERS"
  elif [[ ! -L $user_bgs && $src -ef $user_bgs ]]; then
    src_err="source is the managed collection itself: $src"
  elif [[ -z $(img_find "$src" -print -quit) ]]; then
    src_err="no images (jpg/jpeg/png/gif/bmp/webp) found in $src"
  fi
  if [[ -n $src_err ]]; then
    # Only an explicit flag is allowed to abort; a remembered source that
    # went bad must not break an otherwise-routine reinstall.
    [[ -z $adopted ]] && fail "--wallpapers: $src_err"
    warn "Wallpaper collection not refreshed ($src_err); keeping the current one."
    WALLPAPERS=""
  else
    WALLPAPERS=$src
  fi
fi
if [[ -n $WALLPAPERS ]]; then
  mkdir -p "$HOME/.config/omarchy/backgrounds"
  # Migrate the dir symlink an earlier version created.
  [[ -L $user_bgs ]] && rm "$user_bgs"
  # A real dir without our manifest is user data: back it up, never merge.
  if [[ -d $user_bgs && ! -f $user_bgs/$MANAGED_MARKER ]]; then
    backup="$user_bgs.bak"
    n=0
    while [[ -e $backup ]]; do
      n=$((n + 1))
      backup="$user_bgs.bak.$n"
    done
    mv "$user_bgs" "$backup"
    warn "Existing $(basename "$user_bgs") background dir moved to $(basename "$backup")"
  fi
  mkdir -p "$user_bgs"
  # Names we linked last time. A legacy marker holds only the source line;
  # treat every image as ours then (nothing else ever wrote that format).
  old_manifest=()
  if [[ -f $user_bgs/$MANAGED_MARKER ]]; then
    mapfile -t old_manifest < <(tail -n +2 "$user_bgs/$MANAGED_MARKER")
    if [[ ${#old_manifest[@]} -eq 0 ]]; then
      mapfile -t old_manifest < <(img_find "$user_bgs" -printf '%f\n')
    fi
  fi
  linked=()
  while IFS= read -r -d '' img; do
    base=$(basename "$img")
    ln -f "$img" "$user_bgs/$base" 2>/dev/null || cp -f "$img" "$user_bgs/$base"
    linked+=("$base")
  done < <(img_find "$WALLPAPERS" -print0)
  # Drop only OUR stale entries: listed in the old manifest, gone from the
  # source. Anything unlisted is the user's and stays.
  for name in "${old_manifest[@]}"; do
    keep=""
    for base in "${linked[@]}"; do [[ $base == "$name" ]] && keep=1 && break; done
    [[ -z $keep ]] && rm -f "$user_bgs/$name"
  done
  {
    printf '%s\n' "$WALLPAPERS"
    printf '%s\n' "${linked[@]}"
  } >"$user_bgs/$MANAGED_MARKER"
  say "Wallpaper collection synced from: $WALLPAPERS"
fi
# -print -quit: find stops at the first hit. No pipe, so none of the
# pipefail/SIGPIPE hazard a `| grep -q .` construction would carry.
existing_bg=$(
  img_find "$THEME_DIR/backgrounds" -print -quit
  img_find "$user_bgs" -print -quit
)
if [[ -z $existing_bg ]]; then
  say "Seeding starter backgrounds from the stock tokyo-night theme"
  cp "$OMARCHY_SHARE"/themes/tokyo-night/backgrounds/* "$THEME_DIR/backgrounds/" 2>/dev/null || true
fi

# Generate an initial colors.toml so `omarchy theme set` has something to load,
# and prove the config actually renders our template before enabling anything.
seed_bg=$(img_find "$THEME_DIR/backgrounds" -print -quit)
[[ -n $seed_bg ]] || seed_bg=$(img_find "$user_bgs" -print -quit)
# On a reinstall while matugen-auto is active, the first image in the folder
# is usually not the wallpaper on screen, and seeding from it would leave
# colors.toml describing the wrong image. Prefer the live wallpaper then.
current_theme=$(tr '[:upper:] ' '[:lower:]-' <"$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true)
current_bg=$(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true)
if [[ $current_theme == matugen-auto && -n $current_bg && -f $current_bg ]]; then
  seed_bg=$current_bg
fi
[[ -n $seed_bg ]] || fail "No background image found to seed colors from. Put a wallpaper in $THEME_DIR/backgrounds/ and rerun."
say "Generating initial colors from $(basename "$seed_bg")"
# Seed a commented settings file so the tuning knobs are discoverable. Only
# created when absent; an existing file is the user's, never touched.
SETTINGS_FILE="$HOME/.config/omarchy-auto-theme/settings"
if [[ ! -e $SETTINGS_FILE ]]; then
  mkdir -p "${SETTINGS_FILE%/*}"
  cat >"$SETTINGS_FILE" <<'EOF'
# omarchy-auto-theme settings. Sourced as bash (trusted code) by the installer
# and by omarchy-matugen-sync on every wallpaper change. Uncomment to override.
# Installs never overwrite this file; uninstall keeps it.

# Matugen source-color preference. One of: darkness, lightness, saturation,
# less-saturation, value, closest-to-fallback.
#PREFER=saturation

# Color scheme: dark or light.
#MODE=dark

# Wallpaper rotation. Unset = off. "daily" gives a new wallpaper every
# morning; an interval like 30m or 2h rotates continuously. Takes effect on
# the next wallpaper/theme change (or rerun install.sh).
#ROTATE=30m
EOF
  say "Created settings file: $SETTINGS_FILE"
elif ! grep -q '^#\?ROTATE=' "$SETTINGS_FILE"; then
  # Settings file from before the ROTATE knob existed. We never rewrite user
  # settings, but appending the commented doc block keeps the knob
  # discoverable.
  cat >>"$SETTINGS_FILE" <<'EOF'

# Wallpaper rotation. Unset = off. "daily" gives a new wallpaper every
# morning; an interval like 30m or 2h rotates continuously. Takes effect on
# the next wallpaper/theme change (or rerun install.sh).
#ROTATE=30m
EOF
  say "Added the new ROTATE knob (commented) to $SETTINGS_FILE"
fi

# Honor the same user settings the sync script reads (a trusted bash fragment).
PREFER=saturation MODE=dark ROTATE=
# shellcheck source=/dev/null
[[ -f $SETTINGS_FILE ]] && source "$SETTINGS_FILE"
case $MODE in dark | light) ;; *) fail "invalid MODE '$MODE' in ~/.config/omarchy-auto-theme/settings (dark|light)" ;; esac
[[ $PREFER =~ ^[a-zA-Z0-9_-]+$ ]] || fail "invalid PREFER '$PREFER' in ~/.config/omarchy-auto-theme/settings"
[[ $ROTATE =~ ^(daily|[1-9][0-9]*[mh])?$ ]] || fail "invalid ROTATE '$ROTATE' in ~/.config/omarchy-auto-theme/settings (unset, daily, or an interval like 30m or 2h)"
# A leftover colors.toml from an earlier install would make a broken config
# look like success: require the output to be new or freshly rewritten.
colors_before=$(stat -c '%.Y' "$THEME_DIR/colors.toml" 2>/dev/null || echo missing)
matugen image "$seed_bg" --config "$CONFIG" --mode "$MODE" --prefer "$PREFER"
colors_after=$(stat -c '%.Y' "$THEME_DIR/colors.toml" 2>/dev/null || echo missing)
[[ -s $THEME_DIR/colors.toml && $colors_after != "$colors_before" ]] ||
  fail "matugen ran but $THEME_DIR/colors.toml was not (re)generated. Check the [templates.omarchy_quattro] block in $CONFIG."

# --- systemd watcher -------------------------------------------------------
say "Installing systemd user units"
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/omarchy-matugen.path" "$REPO_DIR/systemd/omarchy-matugen.service" \
  "$REPO_DIR/systemd/omarchy-bg-rotate.timer" "$REPO_DIR/systemd/omarchy-bg-rotate.service" \
  "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable --now omarchy-matugen.path

# One-shot service run: proves the sync script starts in the systemd
# environment (PATH, unit file, script location) rather than just in this
# shell. While another theme is active the script exits before touching
# matugen; `omarchy-matugen-sync --diagnose` covers the full pipeline.
# Clearing the fingerprint first turns this run into a full regenerate +
# omarchy-theme-refresh when matugen-auto is active, so a reinstall leaves
# running apps on the palette of the wallpaper actually on screen.
rm -f "$HOME/.local/state/omarchy/matugen-auto.last"
systemctl --user start omarchy-matugen.service ||
  fail "omarchy-matugen.service failed its validation run. Inspect with: journalctl --user -u omarchy-matugen.service"
# The validation run also reconciles the rotation timer against ROTATE.
[[ -n $ROTATE ]] && say "Wallpaper rotation configured: $([[ $ROTATE == daily ]] && echo "a new wallpaper each day (midnight, or on wake)" || echo "every $ROTATE")"

say "Done. Activate with: omarchy theme set matugen-auto"
say "Then change wallpapers with SUPER+CTRL+SPACE. Colors follow automatically."
if [[ -z $WALLPAPERS ]]; then
  warn "To use your own wallpaper folder: ./install.sh --wallpapers ~/Pictures/Wallpapers"
fi
warn "Tuning lives in ~/.config/omarchy-auto-theme/settings; if colors ever stop following, run: omarchy-matugen-sync --diagnose"
