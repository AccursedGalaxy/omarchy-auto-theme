#!/bin/bash
# Install/uninstall lifecycle tests. Everything runs against a throwaway HOME
# with matugen, omarchy-theme-refresh, and systemctl mocked, so the suite is
# safe on any machine (CI included) and never touches the real user config.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAILED=0

note() { printf '  %s\n' "$*"; }
check() { # description, condition-command...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$desc"
  fi
}

# --- Mocks -----------------------------------------------------------------
MOCKS="$WORK/mocks"
mkdir -p "$MOCKS"

cat >"$MOCKS/matugen" <<'EOF'
#!/bin/bash
echo "matugen $*" >>"$MOCK_LOG"
[[ ${MOCK_MATUGEN_FAIL:-} == 1 ]] && exit 1
if [[ $* == *--version* ]]; then echo "matugen mock"; exit 0; fi
[[ ${MOCK_MATUGEN_NOOP:-} == 1 ]] && exit 0   # exits 0 without writing output
mkdir -p "$HOME/.config/omarchy/themes/matugen-auto"
echo "# mock colors" >"$HOME/.config/omarchy/themes/matugen-auto/colors.toml"
EOF
cat >"$MOCKS/omarchy-theme-refresh" <<'EOF'
#!/bin/bash
echo "omarchy-theme-refresh" >>"$MOCK_LOG"
# Snapshot the fingerprint file as it stands when the refresh fires, so tests
# can assert commit-before-refresh ordering (the real refresh re-triggers the
# path unit mid-run).
cp "$HOME/.local/state/omarchy/matugen-auto.last" "$HOME/.last-at-refresh" 2>/dev/null || true
[[ ${MOCK_REFRESH_FAIL:-} == 1 ]] && exit 1
exit 0
EOF
cat >"$MOCKS/omarchy-theme-bg-next" <<'EOF'
#!/bin/bash
echo "omarchy-theme-bg-next" >>"$MOCK_LOG"
EOF
cat >"$MOCKS/ffmpeg" <<'EOF'
#!/bin/bash
echo "ffmpeg $*" >>"$MOCK_LOG"
[[ ${MOCK_FFMPEG_FAIL:-} == 1 ]] && exit 1
out="${@: -1}"
mkdir -p "$(dirname "$out")"
printf 'frame' >"$out"
EOF
cat >"$MOCKS/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >>"$MOCK_LOG"
exit 0
EOF
cat >"$MOCKS/pgrep" <<'EOF'
#!/bin/bash
echo "pgrep $*" >>"$MOCK_LOG"
exit 1   # process already gone: the wait loop must exit immediately
EOF
cat >"$MOCKS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MOCK_LOG"
[[ ${MOCK_SYSTEMCTL_FAIL:-} == 1 ]] && exit 1
case " $* " in
  *" is-enabled "*) exit "${MOCK_TIMER_ENABLED:-1}" ;;   # default: not enabled
  *" is-active "*)
    # The WE launcher unit defaults to inactive; the timer to active.
    [[ $* == *omarchy-we.service* ]] && exit "${MOCK_WE_ACTIVE:-1}"
    exit "${MOCK_TIMER_ACTIVE:-0}" ;;
  *" is-failed "*) exit "${MOCK_WE_FAILED:-1}" ;;   # default: not failed
esac
exit 0
EOF
cat >"$MOCKS/hyprctl" <<'EOF'
#!/bin/bash
echo "hyprctl $*" >>"$MOCK_LOG"
# Two monitors; nested "name" keys mimic the real payload so only proper
# top-level parsing passes.
echo '[{"name":"DP-1","activeWorkspace":{"name":"1"}},{"name":"HDMI-A-1","activeWorkspace":{"name":"2"}}]'
EOF
cat >"$MOCKS/linux-wallpaperengine" <<'EOF'
#!/bin/bash
echo "linux-wallpaperengine $*" >>"$MOCK_LOG"
EOF
cat >"$MOCKS/omarchy-menu-images" <<'EOF'
#!/bin/bash
echo "omarchy-menu-images $*" >>"$MOCK_LOG"
EOF
cat >"$MOCKS/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >>"$MOCK_LOG"
EOF
chmod +x "$MOCKS"/*
export PATH="$MOCKS:$PATH"

# Fake Omarchy share dir so the installer's layout check and background
# seeding work without a real Omarchy install.
export OMARCHY_PATH="$WORK/omarchy-share"
mkdir -p "$OMARCHY_PATH/themes/tokyo-night/backgrounds"
printf 'not-really-a-png' >"$OMARCHY_PATH/themes/tokyo-night/backgrounds/starter.png"

fresh_home() { # name -> sets HOME and MOCK_LOG
  export HOME="$WORK/$1"
  mkdir -p "$HOME/.local/bin"
  # The sync script pins its own PATH with ~/.local/bin first, which would
  # bypass $MOCKS, so the mocks must also live inside the test HOME.
  ln -sf "$MOCKS"/* "$HOME/.local/bin/"
  export MOCK_LOG="$HOME/mock.log"
  : >"$MOCK_LOG"
  unset MOCK_MATUGEN_FAIL MOCK_MATUGEN_NOOP MOCK_SYSTEMCTL_FAIL MOCK_REFRESH_FAIL \
        MOCK_TIMER_ENABLED MOCK_TIMER_ACTIVE MOCK_FFMPEG_FAIL MOCK_WE_ACTIVE \
        MOCK_WE_FAILED WE_WORKSHOP_DIR WE_ACF
}

CONFIG_REL=".config/matugen/omarchy-auto-theme.toml"
TEMPLATE_REL=".config/matugen/templates/omarchy-quattro-colors.toml"

# --- 1. Clean install ------------------------------------------------------
echo "test: clean install"
fresh_home home-clean
check "installer exits 0" "$REPO_DIR/install.sh"
check "project config installed" cmp -s "$REPO_DIR/templates/omarchy-auto-theme.toml" "$HOME/$CONFIG_REL"
check "template installed" test -f "$HOME/$TEMPLATE_REL"
check "sync script installed" test -x "$HOME/.local/bin/omarchy-matugen-sync"
check "systemd units installed" test -f "$HOME/.config/systemd/user/omarchy-matugen.path"
check "initial colors.toml generated" test -s "$HOME/.config/omarchy/themes/matugen-auto/colors.toml"
check "matugen invoked with project config" grep -q -- "--config $HOME/$CONFIG_REL" "$MOCK_LOG"
check "watcher enabled" grep -q "enable --now omarchy-matugen.path" "$MOCK_LOG"
check "service validated with a one-shot start" grep -q "start omarchy-matugen.service" "$MOCK_LOG"

# --- 2. Reinstall is idempotent --------------------------------------------
echo "test: reinstall over clean install"
check "second install exits 0" "$REPO_DIR/install.sh"
check "config still pristine (no .new litter)" test ! -f "$HOME/$CONFIG_REL.new"

# --- 3. Pre-existing user quattro.toml -------------------------------------
echo "test: install with a pre-existing user quattro.toml"
fresh_home home-usercfg
mkdir -p "$HOME/.config/matugen"
printf '# my personal matugen setup\n[config]\n' >"$HOME/.config/matugen/quattro.toml"
check "installer exits 0" "$REPO_DIR/install.sh"
check "user quattro.toml untouched" grep -q "my personal matugen setup" "$HOME/.config/matugen/quattro.toml"
check "install still functional: matugen uses project config" grep -q -- "--config $HOME/$CONFIG_REL" "$MOCK_LOG"
check "colors.toml generated despite foreign quattro.toml" test -s "$HOME/.config/omarchy/themes/matugen-auto/colors.toml"

# --- 4. Legacy v1.0.0 quattro.toml migration --------------------------------
echo "test: migration of the v1.0.0 quattro.toml"
LEGACY='# Matugen config for the omarchy-matugen adaptive theme.'
fresh_home home-legacy
mkdir -p "$HOME/.config/matugen"
printf '%s\n[config]\n' "$LEGACY" >"$HOME/.config/matugen/quattro.toml"
printf '%s\nnewer\n' "$LEGACY" >"$HOME/.config/matugen/quattro.toml.new"
check "installer exits 0" "$REPO_DIR/install.sh"
check "legacy config moved to .bak" test -f "$HOME/.config/matugen/quattro.toml.bak"
check "legacy config no longer active" test ! -f "$HOME/.config/matugen/quattro.toml"
check "our stale quattro.toml.new removed" test ! -f "$HOME/.config/matugen/quattro.toml.new"

echo "test: migration never clobbers an existing backup or a foreign .new"
fresh_home home-bakcollision
mkdir -p "$HOME/.config/matugen"
printf '%s\n[config]\n' "$LEGACY" >"$HOME/.config/matugen/quattro.toml"
printf '# precious earlier backup\n' >"$HOME/.config/matugen/quattro.toml.bak"
printf '# repurposed by the user\n' >"$HOME/.config/matugen/quattro.toml.new"
check "installer exits 0" "$REPO_DIR/install.sh"
check "existing .bak untouched" grep -q "precious earlier backup" "$HOME/.config/matugen/quattro.toml.bak"
check "legacy config backed up under a fresh name" grep -q "$LEGACY" "$HOME/.config/matugen/quattro.toml.bak.1"
check "foreign quattro.toml.new kept" grep -q "repurposed by the user" "$HOME/.config/matugen/quattro.toml.new"
check "foreign quattro.toml.new survives uninstall" bash -c "'$REPO_DIR/uninstall.sh' >/dev/null && grep -q 'repurposed by the user' '$HOME/.config/matugen/quattro.toml.new'"

# --- 5. Failed matugen generation ------------------------------------------
echo "test: matugen failure aborts before enabling the watcher"
fresh_home home-matugenfail
export MOCK_MATUGEN_FAIL=1
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
  FAILED=$((FAILED + 1)); note "FAIL installer should exit nonzero"
else
  PASS=$((PASS + 1))
fi
check "watcher never enabled" bash -c "! grep -q 'enable --now' '$MOCK_LOG'"
unset MOCK_MATUGEN_FAIL

# --- 5b. Stale output must not pass validation ------------------------------
echo "test: matugen exiting 0 without output fails even with a stale colors.toml"
fresh_home home-staleout
mkdir -p "$HOME/.config/omarchy/themes/matugen-auto"
echo "# colors from a previous install" >"$HOME/.config/omarchy/themes/matugen-auto/colors.toml"
export MOCK_MATUGEN_NOOP=1
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
  FAILED=$((FAILED + 1)); note "FAIL installer should reject a stale colors.toml"
else
  PASS=$((PASS + 1))
fi
check "watcher never enabled" bash -c "! grep -q 'enable --now' '$MOCK_LOG'"
unset MOCK_MATUGEN_NOOP

# --- 5c. systemd failures ---------------------------------------------------
echo "test: systemctl failure aborts install; uninstall still cleans up"
fresh_home home-systemdfail
export MOCK_SYSTEMCTL_FAIL=1
if "$REPO_DIR/install.sh" >/dev/null 2>&1; then
  FAILED=$((FAILED + 1)); note "FAIL installer should exit nonzero when systemctl fails"
else
  PASS=$((PASS + 1))
fi
check "uninstall exits 0 without a working user manager" "$REPO_DIR/uninstall.sh"
check "units removed anyway" test ! -f "$HOME/.config/systemd/user/omarchy-matugen.service"
check "sync script removed anyway" test ! -f "$HOME/.local/bin/omarchy-matugen-sync"
unset MOCK_SYSTEMCTL_FAIL

# --- 6. Uninstall after clean install --------------------------------------
echo "test: uninstall after clean install"
fresh_home home-uninstall
"$REPO_DIR/install.sh" >/dev/null 2>&1
check "uninstaller exits 0" "$REPO_DIR/uninstall.sh"
check "project config removed" test ! -f "$HOME/$CONFIG_REL"
check "template removed" test ! -f "$HOME/$TEMPLATE_REL"
check "sync script removed" test ! -f "$HOME/.local/bin/omarchy-matugen-sync"
check "units removed" test ! -f "$HOME/.config/systemd/user/omarchy-matugen.service"
check "watcher disabled" grep -q "disable --now omarchy-matugen.path" "$MOCK_LOG"

# --- 7. Uninstall preserves user-modified and pre-existing files ------------
echo "test: uninstall preserves modified config and foreign quattro.toml"
fresh_home home-preserve
mkdir -p "$HOME/.config/matugen"
printf '# my personal matugen setup\n[config]\n' >"$HOME/.config/matugen/quattro.toml"
"$REPO_DIR/install.sh" >/dev/null 2>&1
echo "# user tweak" >>"$HOME/$CONFIG_REL"
echo "# user tweak" >>"$HOME/$TEMPLATE_REL"
# Reinstall over the modified files: pristine .new copies land beside them.
"$REPO_DIR/install.sh" >/dev/null 2>&1
echo "# repurposed" >>"$HOME/$TEMPLATE_REL.new"
check "uninstaller exits 0" "$REPO_DIR/uninstall.sh"
check "modified project config kept" test -f "$HOME/$CONFIG_REL"
check "modified template kept" test -f "$HOME/$TEMPLATE_REL"
check "pristine .new removed" test ! -f "$HOME/$CONFIG_REL.new"
check "modified .new kept" grep -q "repurposed" "$HOME/$TEMPLATE_REL.new"
check "foreign quattro.toml kept" grep -q "my personal matugen setup" "$HOME/.config/matugen/quattro.toml"

# --- 8. HOME containing spaces ---------------------------------------------
echo "test: install/uninstall with spaces in HOME"
fresh_home "home with spaces"
check "installer exits 0" "$REPO_DIR/install.sh"
check "colors.toml generated" test -s "$HOME/.config/omarchy/themes/matugen-auto/colors.toml"
check "uninstaller exits 0" "$REPO_DIR/uninstall.sh"
check "project config removed" test ! -f "$HOME/$CONFIG_REL"

# --- 9. Sync script behavior ------------------------------------------------
echo "test: sync script guards and fingerprinting"
fresh_home home-sync
"$REPO_DIR/install.sh" >/dev/null 2>&1
SYNC="$HOME/.local/bin/omarchy-matugen-sync"
STATE="$HOME/.local/state/omarchy"
mkdir -p "$STATE/current"
printf 'wall' >"$STATE/wall.png"
ln -sf "$STATE/wall.png" "$STATE/current/background"

echo "Other Theme" >"$STATE/current/theme.name"
: >"$MOCK_LOG"
check "inactive theme: exits 0" "$SYNC"
check "inactive theme: no regeneration" bash -c "! grep -q matugen '$MOCK_LOG'"

echo "Matugen Auto" >"$STATE/current/theme.name"
: >"$MOCK_LOG"
check "active theme: exits 0" "$SYNC"
check "active theme: regenerates" grep -q "matugen image" "$MOCK_LOG"
check "active theme: refreshes omarchy" grep -q "omarchy-theme-refresh" "$MOCK_LOG"

: >"$MOCK_LOG"
check "unchanged wallpaper: exits 0" "$SYNC"
check "unchanged wallpaper: skipped (idempotency guard)" bash -c "! grep -q matugen '$MOCK_LOG'"

touch -d '2001-01-01' "$STATE/wall.png"   # same path, new mtime = edited in place
: >"$MOCK_LOG"
check "in-place edit: exits 0" "$SYNC"
check "in-place edit: regenerates (mtime fingerprint)" grep -q "matugen image" "$MOCK_LOG"

# Same path, same size, same second; only the nanoseconds differ.
touch -d '2001-01-02 00:00:00.100000000' "$STATE/wall.png"
"$SYNC" >/dev/null 2>&1
touch -d '2001-01-02 00:00:00.200000000' "$STATE/wall.png"
: >"$MOCK_LOG"
check "same-second replacement: regenerates (ns fingerprint)" bash -c "'$SYNC' && grep -q 'matugen image' '$MOCK_LOG'"

echo "test: failed refresh is retried, not recorded as done"
touch -d '2003-03-03' "$STATE/wall.png"
export MOCK_REFRESH_FAIL=1
: >"$MOCK_LOG"
if "$SYNC" >/dev/null 2>&1; then
  FAILED=$((FAILED + 1)); note "FAIL sync should exit nonzero when refresh fails"
else
  PASS=$((PASS + 1))
fi
unset MOCK_REFRESH_FAIL
: >"$MOCK_LOG"
check "next run retries the full pipeline" bash -c "'$SYNC' && grep -q 'matugen image' '$MOCK_LOG' && grep -q omarchy-theme-refresh '$MOCK_LOG'"
: >"$MOCK_LOG"
check "successful retry commits the fingerprint" bash -c "'$SYNC' && ! grep -q matugen '$MOCK_LOG'"

check "--diagnose exits 0 on healthy install" "$SYNC" --diagnose

echo "test: settings file overrides mode and prefer"
mkdir -p "$HOME/.config/omarchy-auto-theme"
printf 'MODE=light\nPREFER=darkness\n' >"$HOME/.config/omarchy-auto-theme/settings"
touch -d '2002-02-02' "$STATE/wall.png"   # force a regeneration
: >"$MOCK_LOG"
check "sync exits 0 with settings file" "$SYNC"
check "sync honors settings" grep -q -- "--mode light --prefer darkness" "$MOCK_LOG"
: >"$MOCK_LOG"
check "reinstall exits 0 with settings file" "$REPO_DIR/install.sh"
check "install seed honors settings" grep -q -- "--mode light --prefer darkness" "$MOCK_LOG"

echo "test: half-configured light mode and invalid settings are caught"
# The distributed template emits mode = "{{mode}}": MODE=light alone is a
# complete configuration and must diagnose clean.
check "--diagnose passes with MODE=light and the dynamic template" "$SYNC" --diagnose
# A customized template hardcoding a literal mode that disagrees with
# settings is the half-configured state.
sed 's/^mode = .*/mode = "dark"/' "$HOME/$TEMPLATE_REL" >"$HOME/$TEMPLATE_REL.tmp"
mv "$HOME/$TEMPLATE_REL.tmp" "$HOME/$TEMPLATE_REL"
check "--diagnose flags settings/template mode mismatch" bash -c "! '$SYNC' --diagnose"
cp "$REPO_DIR/templates/omarchy-quattro-colors.toml" "$HOME/$TEMPLATE_REL"
printf 'MODE=purple\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "invalid MODE: sync exits 2" bash -c "'$SYNC'; [[ \$? -eq 2 ]]"
check "invalid MODE: installer refuses" bash -c "! '$REPO_DIR/install.sh' >/dev/null 2>&1"
printf 'PREFER="darkness; rm -rf /"\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "invalid PREFER: sync exits 2" bash -c "'$SYNC'; [[ \$? -eq 2 ]]"
printf 'MODE=light\nPREFER=darkness\n' >"$HOME/.config/omarchy-auto-theme/settings"

check "uninstall keeps the settings file" bash -c "'$REPO_DIR/uninstall.sh' >/dev/null && test -f '$HOME/.config/omarchy-auto-theme/settings'"

# --- 10. Settings file seeding ----------------------------------------------
echo "test: installer seeds a commented settings file, never overwrites one"
fresh_home home-settings-seed
check "installer exits 0" "$REPO_DIR/install.sh"
check "settings file created" test -f "$HOME/.config/omarchy-auto-theme/settings"
check "seeded settings are all comments (defaults unchanged)" \
  bash -c "! grep -qv '^#\|^$' '$HOME/.config/omarchy-auto-theme/settings'"
check "matugen still uses built-in defaults" grep -q -- "--mode dark --prefer saturation" "$MOCK_LOG"
printf 'MODE=light\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "reinstall exits 0" "$REPO_DIR/install.sh"
check "existing settings values untouched" bash -c "head -n1 '$HOME/.config/omarchy-auto-theme/settings' | grep -qx 'MODE=light'"
check "pre-ROTATE file gets the commented ROTATE doc appended" grep -q '^#ROTATE=30m' "$HOME/.config/omarchy-auto-theme/settings"
check "appended block sets no values" bash -c "! grep -qv '^#\|^$\|^MODE=light\$' '$HOME/.config/omarchy-auto-theme/settings'"
size_before=$(wc -c <"$HOME/.config/omarchy-auto-theme/settings")
check "third install exits 0" "$REPO_DIR/install.sh"
check "ROTATE block appended only once" bash -c "[[ \$(wc -c <'$HOME/.config/omarchy-auto-theme/settings') -eq $size_before ]]"

# --- 11. --wallpapers flag ---------------------------------------------------
echo "test: install --wallpapers hardlinks the folder into a managed dir"
fresh_home home-wallpapers
mkdir -p "$HOME/Pictures/Walls"
printf 'img' >"$HOME/Pictures/Walls/mine.png"
check "installer exits 0" "$REPO_DIR/install.sh" --wallpapers "$HOME/Pictures/Walls"
USER_BGS="$HOME/.config/omarchy/backgrounds/matugen-auto"
check "background dir is a real dir (not a symlink)" \
  bash -c "[[ -d '$USER_BGS' && ! -L '$USER_BGS' ]]"
check "image hardlinked in" bash -c "[[ '$USER_BGS/mine.png' -ef '$HOME/Pictures/Walls/mine.png' ]]"
check "manifest records the source folder" \
  bash -c "[[ \$(head -n1 '$USER_BGS/.omarchy-auto-theme-source') == '$HOME/Pictures/Walls' ]]"
check "manifest lists the linked image" grep -qx "mine.png" "$USER_BGS/.omarchy-auto-theme-source"
check "no starter backgrounds seeded" \
  bash -c "! find '$HOME/.config/omarchy/themes/matugen-auto/backgrounds' -type f 2>/dev/null | grep -q ."
check "initial colors generated from the managed collection" \
  grep -q "matugen image $USER_BGS/mine.png" "$MOCK_LOG"

echo "test: plain rerun refreshes the managed dir from the recorded source"
printf 'img2' >"$HOME/Pictures/Walls/added-later.png"
rm "$HOME/Pictures/Walls/mine.png"
check "rerun without the flag exits 0" "$REPO_DIR/install.sh"
check "new source image appears" test -f "$USER_BGS/added-later.png"
check "removed source image disappears" test ! -e "$USER_BGS/mine.png"
check "no backup litter from refreshing our own dir" test ! -e "$USER_BGS.bak"

echo "test: --wallpapers migrates the v1.1 dir symlink and backs up user dirs"
fresh_home home-wallpapers-bak
mkdir -p "$HOME/Pictures/Walls" "$HOME/.config/omarchy/backgrounds/matugen-auto"
printf 'img' >"$HOME/Pictures/Walls/mine.jpg"
printf 'old' >"$HOME/.config/omarchy/backgrounds/matugen-auto/old.png"
check "installer exits 0" "$REPO_DIR/install.sh" --wallpapers "$HOME/Pictures/Walls"
check "old dir backed up" test -f "$HOME/.config/omarchy/backgrounds/matugen-auto.bak/old.png"
check "managed dir in place with the image" \
  bash -c "[[ '$HOME/.config/omarchy/backgrounds/matugen-auto/mine.jpg' -ef '$HOME/Pictures/Walls/mine.jpg' ]]"
rm -rf "$HOME/.config/omarchy/backgrounds/matugen-auto"
ln -s "$HOME/Pictures/Walls" "$HOME/.config/omarchy/backgrounds/matugen-auto"
check "reinstall over v1.1 symlink exits 0" "$REPO_DIR/install.sh" --wallpapers "$HOME/Pictures/Walls"
check "symlink replaced by a real dir" \
  bash -c "[[ -d '$HOME/.config/omarchy/backgrounds/matugen-auto' && ! -L '$HOME/.config/omarchy/backgrounds/matugen-auto' ]]"
check "source folder itself untouched" test -f "$HOME/Pictures/Walls/mine.jpg"

echo "test: --wallpapers rejects bad input"
fresh_home home-wallpapers-bad
check "missing dir fails" bash -c "! '$REPO_DIR/install.sh' --wallpapers '$HOME/nope' >/dev/null 2>&1"
mkdir -p "$HOME/empty"
check "dir without images fails" bash -c "! '$REPO_DIR/install.sh' --wallpapers '$HOME/empty' >/dev/null 2>&1"
check "unknown option fails" bash -c "! '$REPO_DIR/install.sh' --bogus >/dev/null 2>&1"

# --- 11b. Reinstall while the theme is live ----------------------------------
echo "test: reinstall seeds from the wallpaper on screen, not the first file"
fresh_home home-live-reinstall
mkdir -p "$HOME/Pictures/Walls" "$HOME/.local/state/omarchy/current"
printf 'a' >"$HOME/Pictures/Walls/aaa-first.png"
printf 'b' >"$HOME/Pictures/Walls/zzz-current.png"
"$REPO_DIR/install.sh" --wallpapers "$HOME/Pictures/Walls" >/dev/null 2>&1
echo "Matugen Auto" >"$HOME/.local/state/omarchy/current/theme.name"
ln -sf "$HOME/Pictures/Walls/zzz-current.png" "$HOME/.local/state/omarchy/current/background"
printf 'stale\n' >"$HOME/.local/state/omarchy/matugen-auto.last"
: >"$MOCK_LOG"
check "reinstall exits 0" "$REPO_DIR/install.sh"
check "seed uses the current wallpaper" grep -q "matugen image $HOME/Pictures/Walls/zzz-current.png" "$MOCK_LOG"
check "fingerprint cleared so the validation run refreshes" test ! -e "$HOME/.local/state/omarchy/matugen-auto.last"
echo "Other Theme" >"$HOME/.local/state/omarchy/current/theme.name"
printf 'x' >"$HOME/other-theme-bg.png"
ln -sf "$HOME/other-theme-bg.png" "$HOME/.local/state/omarchy/current/background"
: >"$MOCK_LOG"
check "reinstall exits 0 under another theme" "$REPO_DIR/install.sh"
check "inactive theme: another theme's wallpaper is not used as seed" \
  bash -c "! grep -q 'matugen image $HOME/other-theme-bg.png' '$MOCK_LOG'"
check "inactive theme: seed comes from the managed collection" \
  grep -q "matugen image $HOME/.config/omarchy/backgrounds/matugen-auto/" "$MOCK_LOG"

# --- 12. Wallpaper rotation (ROTATE) ----------------------------------------
echo "test: rotation units installed but timer stays off without ROTATE"
fresh_home home-rotate
"$REPO_DIR/install.sh" >/dev/null 2>&1
SYNC="$HOME/.local/bin/omarchy-matugen-sync"
DROPIN="$HOME/.config/systemd/user/omarchy-bg-rotate.timer.d/interval.conf"
check "rotate timer unit installed" test -f "$HOME/.config/systemd/user/omarchy-bg-rotate.timer"
check "rotate service unit installed" test -f "$HOME/.config/systemd/user/omarchy-bg-rotate.service"
check "timer not enabled without ROTATE" bash -c "! grep -q 'enable --now omarchy-bg-rotate.timer' '$MOCK_LOG'"
check "no interval drop-in without ROTATE" test ! -e "$DROPIN"

echo "test: setting ROTATE reconciles the timer on the next sync"
mkdir -p "$HOME/.config/omarchy-auto-theme"
printf 'ROTATE=45m\n' >"$HOME/.config/omarchy-auto-theme/settings"
: >"$MOCK_LOG"
check "sync exits 0" "$SYNC"
check "drop-in carries the interval" grep -q "OnUnitActiveSec=45m" "$DROPIN"
check "interval rotation is not Persistent" grep -q "Persistent=false" "$DROPIN"
check "timer enabled" grep -q "enable --now omarchy-bg-rotate.timer" "$MOCK_LOG"
: >"$MOCK_LOG"
check "second sync exits 0" "$SYNC"
check "unchanged ROTATE: no re-enable (idempotent)" bash -c "! grep -q 'enable --now omarchy-bg-rotate.timer' '$MOCK_LOG'"

echo "test: daily preset and interval changes rewrite the drop-in"
printf 'ROTATE=daily\n' >"$HOME/.config/omarchy-auto-theme/settings"
: >"$MOCK_LOG"
check "sync exits 0" "$SYNC"
check "drop-in switched to OnCalendar=daily" grep -q "OnCalendar=daily" "$DROPIN"
check "daily rotation is Persistent" grep -q "Persistent=true" "$DROPIN"
check "timer re-enabled after change" grep -q "enable --now omarchy-bg-rotate.timer" "$MOCK_LOG"

echo "test: clearing ROTATE tears the timer down"
: >"$HOME/.config/omarchy-auto-theme/settings"
: >"$MOCK_LOG"
check "sync exits 0" "$SYNC"
check "timer disabled" grep -q "disable --now omarchy-bg-rotate.timer" "$MOCK_LOG"
check "drop-in removed" test ! -e "$DROPIN"
: >"$MOCK_LOG"
check "already-off: sync exits 0" "$SYNC"
check "already-off: no enable/disable churn" \
  bash -c "! grep -qE '(enable|disable) --now omarchy-bg-rotate' '$MOCK_LOG'"

echo "test: --rotate calls omarchy-theme-bg-next"
: >"$MOCK_LOG"
check "--rotate exits 0" "$SYNC" --rotate
check "bg-next invoked" grep -q "omarchy-theme-bg-next" "$MOCK_LOG"

echo "test: invalid ROTATE is rejected"
printf 'ROTATE=5x\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "invalid unit: sync exits 2" bash -c "'$SYNC'; [[ \$? -eq 2 ]]"
check "invalid unit: installer refuses" bash -c "! '$REPO_DIR/install.sh' >/dev/null 2>&1"
printf 'ROTATE=0m\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "zero interval: sync exits 2" bash -c "'$SYNC'; [[ \$? -eq 2 ]]"
printf 'ROTATE=daily\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "daily preset: installer accepts" "$REPO_DIR/install.sh"

echo "test: uninstall removes rotation units and generated drop-in"
"$SYNC" >/dev/null 2>&1   # materialize the drop-in
check "uninstaller exits 0" "$REPO_DIR/uninstall.sh"
check "rotate timer disabled" grep -q "disable --now omarchy-bg-rotate.timer" "$MOCK_LOG"
check "rotate units removed" bash -c "! ls '$HOME/.config/systemd/user/'omarchy-bg-rotate.* >/dev/null 2>&1"
check "drop-in dir removed" test ! -e "$HOME/.config/systemd/user/omarchy-bg-rotate.timer.d"

# --- 13. Review-driven hardening ---------------------------------------------
echo "test: flagless rerun migrates the v1.1 dir symlink"
fresh_home home-flagless-migrate
mkdir -p "$HOME/Pictures/Walls" "$HOME/.config/omarchy/backgrounds"
printf 'img' >"$HOME/Pictures/Walls/mine.png"
ln -s "$HOME/Pictures/Walls" "$HOME/.config/omarchy/backgrounds/matugen-auto"
check "plain install exits 0" "$REPO_DIR/install.sh"
UB="$HOME/.config/omarchy/backgrounds/matugen-auto"
check "symlink replaced by managed dir" bash -c "[[ -d '$UB' && ! -L '$UB' ]]"
check "image adopted" bash -c "[[ '$UB/mine.png' -ef '$HOME/Pictures/Walls/mine.png' ]]"
check "manifest lists the linked file" grep -qx "mine.png" "$UB/.omarchy-auto-theme-source"

echo "test: user-dropped files in the managed dir survive refresh and uninstall"
printf 'precious' >"$UB/handadded.png"
printf 'img2' >"$HOME/Pictures/Walls/second.png"
rm "$HOME/Pictures/Walls/mine.png"
check "flagless refresh exits 0" "$REPO_DIR/install.sh"
check "user file untouched" grep -q "precious" "$UB/handadded.png"
check "our stale link removed" test ! -e "$UB/mine.png"
check "new source image linked" test -f "$UB/second.png"
check "user file not in manifest" bash -c "! grep -qx 'handadded.png' '$UB/.omarchy-auto-theme-source'"
check "uninstall exits 0" "$REPO_DIR/uninstall.sh"
check "uninstall keeps the user file" grep -q "precious" "$UB/handadded.png"
check "uninstall removes our links and manifest" \
  bash -c "[[ ! -e '$UB/second.png' && ! -e '$UB/.omarchy-auto-theme-source' ]]"

echo "test: a remembered source gone bad never aborts a plain reinstall"
fresh_home home-bad-source
mkdir -p "$HOME/Pictures/Walls"
printf 'img' >"$HOME/Pictures/Walls/mine.png"
"$REPO_DIR/install.sh" --wallpapers "$HOME/Pictures/Walls" >/dev/null 2>&1
rm "$HOME/Pictures/Walls/mine.png"    # emptied source
check "plain rerun exits 0 despite empty source" "$REPO_DIR/install.sh"
check "collection kept" test -f "$HOME/.config/omarchy/backgrounds/matugen-auto/mine.png"
rm -rf "$HOME/Pictures/Walls"         # vanished source
check "plain rerun exits 0 despite missing source" "$REPO_DIR/install.sh"
check "explicit flag on empty dir still fails" \
  bash -c "mkdir -p '$HOME/empty' && ! '$REPO_DIR/install.sh' --wallpapers '$HOME/empty' >/dev/null 2>&1"

echo "test: --wallpapers pointing at the managed dir itself is rejected"
check "self-referential source fails" bash -c \
  "! '$REPO_DIR/install.sh' --wallpapers '$HOME/.config/omarchy/backgrounds/matugen-auto' >/dev/null 2>&1"
check "collection survives the rejected run" \
  test -f "$HOME/.config/omarchy/backgrounds/matugen-auto/mine.png"

echo "test: rotation reconcile failures never stop the color sync"
fresh_home home-reconcile-fail
"$REPO_DIR/install.sh" >/dev/null 2>&1
SYNC="$HOME/.local/bin/omarchy-matugen-sync"
STATE="$HOME/.local/state/omarchy"
mkdir -p "$STATE/current" "$HOME/.config/omarchy-auto-theme"
printf 'wall' >"$STATE/wall.png"
ln -sf "$STATE/wall.png" "$STATE/current/background"
echo "Matugen Auto" >"$STATE/current/theme.name"
printf 'ROTATE=30m\n' >"$HOME/.config/omarchy-auto-theme/settings"
export MOCK_SYSTEMCTL_FAIL=1
: >"$MOCK_LOG"
check "sync exits 0 with failing systemctl" "$SYNC"
check "colors still regenerate" grep -q "matugen image" "$MOCK_LOG"
unset MOCK_SYSTEMCTL_FAIL

echo "test: orphan enabled timer without a drop-in is disabled"
: >"$HOME/.config/omarchy-auto-theme/settings"   # ROTATE off
rm -rf "$HOME/.config/systemd/user/omarchy-bg-rotate.timer.d"
export MOCK_TIMER_ENABLED=0
touch -d '2004-04-04' "$STATE/wall.png"
: >"$MOCK_LOG"
check "sync exits 0" "$SYNC"
check "orphan timer disabled" grep -q "disable --now omarchy-bg-rotate.timer" "$MOCK_LOG"
unset MOCK_TIMER_ENABLED

# --- 14. --image override and the wallpaper-engine wrapper -------------------
echo "test: --image renders an arbitrary image regardless of the active theme"
fresh_home home-image
"$REPO_DIR/install.sh" >/dev/null 2>&1
SYNC="$HOME/.local/bin/omarchy-matugen-sync"
STATE="$HOME/.local/state/omarchy"
mkdir -p "$STATE/current"
printf 'wall' >"$STATE/wall.png"
ln -sf "$STATE/wall.png" "$STATE/current/background"
echo "Other Theme" >"$STATE/current/theme.name"
printf 'live' >"$HOME/frame.png"
: >"$MOCK_LOG"
check "--image exits 0 under another theme" "$SYNC" --image "$HOME/frame.png"
check "--image renders the given image" grep -q "matugen image $HOME/frame.png" "$MOCK_LOG"
check "--image under another theme skips the refresh" \
  bash -c "! grep -q omarchy-theme-refresh '$MOCK_LOG'"

echo "test: --image survives the refresh-triggered path unit (no clobber)"
echo "Matugen Auto" >"$STATE/current/theme.name"
"$SYNC" >/dev/null 2>&1          # normal sync records wall.png
: >"$MOCK_LOG"
check "--image exits 0 with matugen-auto active" "$SYNC" --image "$HOME/frame.png"
check "--image rendered" grep -q "matugen image $HOME/frame.png" "$MOCK_LOG"
check "--image with matugen-auto active refreshes omarchy" \
  grep -q omarchy-theme-refresh "$MOCK_LOG"
# The real refresh re-triggers the path unit while it is still running, so
# the guard must already be on disk when the refresh starts. The refresh mock
# snapshots the fingerprint file into ~/.last-at-refresh at that moment.
rm -f "$STATE/matugen-auto.last" "$HOME/.last-at-refresh"   # post-install state
check "fresh install state: --image exits 0" "$SYNC" --image "$HOME/frame.png"
check "wallpaper fingerprint committed before the refresh fires" \
  grep -q "$STATE/wall.png" "$HOME/.last-at-refresh"
: >"$MOCK_LOG"
check "loopback trigger: exits 0" "$SYNC"
check "loopback trigger: does not clobber the --image palette" \
  bash -c "! grep -q matugen '$MOCK_LOG'"
touch -d '2005-05-05' "$STATE/wall.png"
: >"$MOCK_LOG"
check "real wallpaper change still regenerates" \
  bash -c "'$SYNC' && grep -q 'matugen image' '$MOCK_LOG'"

echo "test: --image input validation"
check "missing path: exit 2" bash -c "'$SYNC' --image; [[ \$? -eq 2 ]]"
check "nonexistent file: exit 1" bash -c "'$SYNC' --image '$HOME/nope.png'; [[ \$? -eq 1 ]]"
check "stray args after --image: exit 2" \
  bash -c "'$SYNC' --image '$HOME/frame.png' --mode light; [[ \$? -eq 2 ]]"

echo "test: wallpaper-engine wrapper resolves projects and calls --image"
WE="$HOME/.local/bin/omarchy-auto-theme-we"
check "repo wrapper is executable" test -x "$REPO_DIR/bin/omarchy-auto-theme-we"
check "wrapper installed" test -x "$WE"
mkdir -p "$HOME/we-project"
printf 'preview' >"$HOME/we-project/preview.jpg"
: >"$MOCK_LOG"
check "project dir: exits 0" "$WE" "$HOME/we-project"
check "project dir: preview rendered" \
  grep -q "matugen image $HOME/we-project/preview.jpg" "$MOCK_LOG"

mkdir -p "$HOME/we project (copy)"
printf 'preview' >"$HOME/we project (copy)/preview.jpg"
: >"$MOCK_LOG"
check "project dir with spaces: exits 0" "$WE" "$HOME/we project (copy)"
check "project dir with spaces: preview rendered" \
  grep -q "matugen image $HOME/we project (copy)/preview.jpg" "$MOCK_LOG"

export WE_WORKSHOP_DIR="$HOME/workshop"
mkdir -p "$WE_WORKSHOP_DIR/123456"
printf 'preview' >"$WE_WORKSHOP_DIR/123456/preview.png"
: >"$MOCK_LOG"
check "workshop id: exits 0" "$WE" 123456
check "workshop id: preview rendered" \
  grep -q "matugen image $WE_WORKSHOP_DIR/123456/preview.png" "$MOCK_LOG"
unset WE_WORKSHOP_DIR

echo "test: wrapper extracts a frame from animated previews"
mkdir -p "$HOME/we-gif"
printf 'gifdata' >"$HOME/we-gif/preview.gif"
: >"$MOCK_LOG"
check "animated preview: exits 0" "$WE" "$HOME/we-gif"
check "animated preview: ffmpeg invoked" grep -q "ffmpeg" "$MOCK_LOG"
check "animated preview: extracted frame rendered" \
  grep -q "matugen image $HOME/.cache/omarchy-auto-theme/we-frame.png" "$MOCK_LOG"
printf 'video' >"$HOME/clip.mp4"
: >"$MOCK_LOG"
check "direct video arg: exits 0" "$WE" "$HOME/clip.mp4"
check "direct video arg: frame rendered" \
  grep -q "matugen image $HOME/.cache/omarchy-auto-theme/we-frame.png" "$MOCK_LOG"
export MOCK_FFMPEG_FAIL=1
check "ffmpeg failure: wrapper exits nonzero" \
  bash -c "! '$WE' '$HOME/clip.mp4' >/dev/null 2>&1"
unset MOCK_FFMPEG_FAIL

printf 'img' >"$HOME/direct.png"
: >"$MOCK_LOG"
check "direct image arg: exits 0" "$WE" "$HOME/direct.png"
check "direct image arg rendered" grep -q "matugen image $HOME/direct.png" "$MOCK_LOG"

echo "test: wrapper exec mode stops wallpaperengine and runs the command"
cat >"$HOME/.local/bin/we-launch" <<'EOF'
#!/bin/bash
echo "we-launch $*" >>"$MOCK_LOG"
EOF
chmod +x "$HOME/.local/bin/we-launch"
: >"$MOCK_LOG"
check "exec mode: exits 0" "$WE" "$HOME/direct.png" -- we-launch --screen-root DP-1
check "exec mode: theme rendered first" grep -q "matugen image $HOME/direct.png" "$MOCK_LOG"
check "exec mode: previous instance stopped (cmdline match, not -x)" \
  grep -q -- "pkill -f (^|/)linux-wallpaperengine( |\$)" "$MOCK_LOG"
check "exec mode: command ran with its args" \
  grep -q -- "we-launch --screen-root DP-1" "$MOCK_LOG"
: >"$MOCK_LOG"
check "no exec mode: wallpaperengine left alone" \
  bash -c "'$WE' '$HOME/direct.png' && ! grep -q pkill '$MOCK_LOG'"

echo "test: wrapper input validation"
check "no args: exit 2" bash -c "'$WE'; [[ \$? -eq 2 ]]"
check "stray args without --: exit 2" \
  bash -c "'$WE' '$HOME/direct.png' extra; [[ \$? -eq 2 ]]"
check "-- with no command: exit 2" \
  bash -c "'$WE' '$HOME/direct.png' --; [[ \$? -eq 2 ]]"
check "--help: exit 0" bash -c "'$WE' --help >/dev/null; [[ \$? -eq 0 ]]"
check "unresolvable target: exit 1" bash -c "'$WE' '$HOME/nope'; [[ \$? -eq 1 ]]"
mkdir -p "$HOME/we-empty"
check "dir without preview: exit 1" bash -c "'$WE' '$HOME/we-empty'; [[ \$? -eq 1 ]]"

echo "test: uninstall removes the wrapper"
check "uninstall exits 0" "$REPO_DIR/uninstall.sh"
check "wrapper removed" test ! -e "$WE"

# --- 15. Wallpaper Engine first-class integration ----------------------------
echo "test: import materializes workshop previews as we-<id> stills"
fresh_home home-we
"$REPO_DIR/install.sh" >/dev/null 2>&1
WE="$HOME/.local/bin/omarchy-auto-theme-we"
SYNC="$HOME/.local/bin/omarchy-matugen-sync"
UB="$HOME/.config/omarchy/backgrounds/matugen-auto"
export WE_WORKSHOP_DIR="$HOME/workshop"
mkdir -p "$WE_WORKSHOP_DIR/111" "$WE_WORKSHOP_DIR/222" "$WE_WORKSHOP_DIR/333" \
         "$WE_WORKSHOP_DIR/not a project"
printf 'jpg' >"$WE_WORKSHOP_DIR/111/preview.jpg"
printf 'gif' >"$WE_WORKSHOP_DIR/222/preview.gif"
printf 'png' >"$WE_WORKSHOP_DIR/333/preview.png"
printf 'stray' >"$WE_WORKSHOP_DIR/not a project/preview.jpg"
mkdir -p "$WE_WORKSHOP_DIR/555"
printf 'jpg' >"$WE_WORKSHOP_DIR/555/preview.jpg"
mkdir -p "$WE_WORKSHOP_DIR/666"
printf 'vid' >"$WE_WORKSHOP_DIR/666/movie.mp4"
printf '{"type":"Video","file":"movie.mp4"}' >"$WE_WORKSHOP_DIR/666/project.json"
printf 'jpg' >"$WE_WORKSHOP_DIR/666/preview.jpg"
mkdir -p "$UB"
printf 'precious' >"$UB/handadded.png"
printf 'mine' >"$UB/we-555.jpg"   # user file already sitting at a we- name
check "we unit shipped by install" test -f "$HOME/.config/systemd/user/omarchy-we.service"
check "plain install never enables the we unit" \
  bash -c "! grep -q 'enable omarchy-we' '$MOCK_LOG'"
: >"$MOCK_LOG"
check "import exits 0" "$WE" import
check "still preview hardlinked" bash -c "[[ '$UB/we-111.jpg' -ef '$WE_WORKSHOP_DIR/111/preview.jpg' ]]"
check "animated preview extracted via ffmpeg" \
  bash -c "grep -q ffmpeg '$MOCK_LOG' && test -f '$UB/we-222.jpg'"
check "png preview keeps its extension" test -f "$UB/we-333.png"
check "non-numeric dirs skipped" bash -c "! ls '$UB'/we-not* >/dev/null 2>&1"
check "manifest records mode all" bash -c "head -n1 '$UB/.omarchy-auto-theme-we' | grep -qx all"
check "manifest lists the stills" grep -qx "we-222.jpg" "$UB/.omarchy-auto-theme-we"
check "import enables the we unit (opt-in)" grep -q "enable omarchy-we.service" "$MOCK_LOG"
check "import enables the subscription watcher" \
  grep -q "enable --now omarchy-we-import.path" "$MOCK_LOG"
check "user file untouched" grep -q "precious" "$UB/handadded.png"
check "video project: frame extracted from the video source" grep -q "movie.mp4" "$MOCK_LOG"
check "video still cached full-res, not the preview" \
  bash -c "[[ \$(cat '$UB/we-666.jpg') == frame ]]"
check "picker thumbnails warmed after import" grep -q "omarchy-menu-images --cache-only" "$MOCK_LOG"
check "picker rows preloaded after import" grep -q "omarchy-menu-images --preload" "$MOCK_LOG"
check "pre-existing file at a we- name kept" grep -q "mine" "$UB/we-555.jpg"
check "kept user file not manifested" bash -c "! grep -qx 'we-555.jpg' '$UB/.omarchy-auto-theme-we'"
rm -f "$UB/we-555.jpg"; rm -rf "$WE_WORKSHOP_DIR/555"
check "known id refuses nothing in all mode" "$WE" import 111
check "unknown id refuses even in all mode" bash -c "! '$WE' import 999 >/dev/null 2>&1"

echo "test: install.sh rerun refreshes the imported collection"
rm -rf "$WE_WORKSHOP_DIR/333"                       # unsubscribed
mkdir -p "$WE_WORKSHOP_DIR/444"                     # newly subscribed
printf 'jpg' >"$WE_WORKSHOP_DIR/444/preview.jpg"
: >"$MOCK_LOG"
check "rerun exits 0" "$REPO_DIR/install.sh"
check "unsubscribed still removed" test ! -e "$UB/we-333.png"
check "new subscription imported" test -f "$UB/we-444.jpg"
check "refresh does not re-enable the unit" bash -c "! grep -q 'enable omarchy-we' '$MOCK_LOG'"
check "cached frames not re-extracted on refresh" bash -c "! grep -q ffmpeg '$MOCK_LOG'"

echo "test: a still that cannot be written is skipped, not falsely manifested"
rm -f "$UB/we-444.jpg"
mkdir "$UB/we-444.jpg"   # a directory blocks both ln -f and cp -f
check "blocked write: import exits 0" "$WE" import
check "blocked entry dropped from manifest" \
  bash -c "! grep -qx 'we-444.jpg' '$UB/.omarchy-auto-theme-we'"
rmdir "$UB/we-444.jpg"
check "unblocked rerun re-imports it" \
  bash -c "'$WE' import >/dev/null 2>&1 && test -f '$UB/we-444.jpg'"

echo "test: selective import and removal"
: >"$MOCK_LOG"
check "import --remove exits 0" "$WE" import --remove
check "all our stills removed" bash -c "! ls '$UB'/we-* >/dev/null 2>&1"
check "manifest removed" test ! -e "$UB/.omarchy-auto-theme-we"
check "full removal disables the launcher unit" \
  grep -q "disable --now omarchy-we.service" "$MOCK_LOG"
check "full removal disables the subscription watcher" \
  grep -q "disable --now omarchy-we-import.path" "$MOCK_LOG"
check "user file survives removal" grep -q "precious" "$UB/handadded.png"
check "rerun install with no manifest imports nothing" \
  bash -c "'$REPO_DIR/install.sh' >/dev/null 2>&1 && ! ls '$UB'/we-* >/dev/null 2>&1"
check "selective import exits 0" "$WE" import 111
check "selected still imported" test -f "$UB/we-111.jpg"
check "unselected project not imported" test ! -e "$UB/we-222.jpg"
check "manifest records mode selected" bash -c "head -n1 '$UB/.omarchy-auto-theme-we' | grep -qx selected"
check "install rerun keeps the selection narrow" \
  bash -c "'$REPO_DIR/install.sh' >/dev/null 2>&1 && ! ls '$UB'/we-222* >/dev/null 2>&1"
check "second selective import extends the selection" \
  bash -c "'$WE' import 222 && test -f '$UB/we-111.jpg' && test -f '$UB/we-222.jpg'"
check "selective removal prunes one entry" \
  bash -c "'$WE' import --remove 111 && test ! -e '$UB/we-111.jpg' && test -f '$UB/we-222.jpg'"
check "uninstalled id refuses" bash -c "! '$WE' import 999 >/dev/null 2>&1"
"$WE" import >/dev/null 2>&1   # back to a full collection for the tests below

echo "test: sync detects we- backgrounds and drives the launcher unit"
STATE="$HOME/.local/state/omarchy"
mkdir -p "$STATE/current"
echo "Matugen Auto" >"$STATE/current/theme.name"
ln -sf "$UB/we-111.jpg" "$STATE/current/background"
: >"$MOCK_LOG"
check "we bg: sync exits 0" "$SYNC"
check "we bg: palette rendered from the still" grep -q "matugen image $UB/we-111.jpg" "$MOCK_LOG"
check "we bg: launcher restarted without blocking" \
  grep -q -- "--no-block restart omarchy-we.service" "$MOCK_LOG"
check "we bg: failed-state reset before restart" grep -q "reset-failed omarchy-we.service" "$MOCK_LOG"
check "first launch schedules a capture follow-up" \
  grep -q "systemd-run .*omarchy-we-followup" "$MOCK_LOG"
printf 'wall' >"$STATE/wall.png"
ln -sf "$STATE/wall.png" "$STATE/current/background"
export MOCK_WE_ACTIVE=0
: >"$MOCK_LOG"
check "static bg: sync exits 0" "$SYNC"
check "static bg: running launcher stopped" grep -q "stop omarchy-we.service" "$MOCK_LOG"
check "static bg: no restart issued" bash -c "! grep -q 'restart omarchy-we' '$MOCK_LOG'"
unset MOCK_WE_ACTIVE
ln -sf "$UB/we-222.jpg" "$STATE/current/background"
"$SYNC" >/dev/null 2>&1
printf 'wall2' >"$STATE/wall2.png"
ln -sf "$STATE/wall2.png" "$STATE/current/background"
: >"$MOCK_LOG"
check "static bg with launcher already off: sync exits 0" "$SYNC"
check "already off: no stop churn" bash -c "! grep -q 'stop omarchy-we' '$MOCK_LOG'"
printf 'orphan' >"$UB/we-999.jpg"
ln -sf "$UB/we-999.jpg" "$STATE/current/background"
: >"$MOCK_LOG"
check "vanished project: sync exits 0" "$SYNC"
check "vanished project: palette still rendered" grep -q "matugen image $UB/we-999.jpg" "$MOCK_LOG"
check "vanished project: no launcher restart" bash -c "! grep -q 'restart omarchy-we' '$MOCK_LOG'"
rm -f "$UB/we-999.jpg"
ln -sf "$UB/we-111.jpg" "$STATE/current/background"
"$SYNC" >/dev/null 2>&1
echo "Other Theme" >"$STATE/current/theme.name"
export MOCK_WE_ACTIVE=0
: >"$MOCK_LOG"
check "theme switched away: sync exits 0" "$SYNC"
check "theme switched away: launcher stopped" grep -q "stop omarchy-we.service" "$MOCK_LOG"
check "theme switched away: no regeneration" bash -c "! grep -q matugen '$MOCK_LOG'"
unset MOCK_WE_ACTIVE
echo "Matugen Auto" >"$STATE/current/theme.name"

echo "test: launcher reconciles independently of the palette fingerprint"
# Theme is back on matugen-auto with the same we-111 background: the palette
# is up to date (fingerprint match) but the launcher was stopped above.
: >"$MOCK_LOG"
check "same bg, launcher down: sync exits 0" "$SYNC"
check "launcher restarted despite unchanged wallpaper" \
  grep -q -- "--no-block restart omarchy-we.service" "$MOCK_LOG"
check "palette not re-rendered" bash -c "! grep -q 'matugen image' '$MOCK_LOG'"
export MOCK_WE_ACTIVE=0   # launcher now running with the recorded id
: >"$MOCK_LOG"
check "same bg, launcher up: sync exits 0" "$SYNC"
check "no restart churn while running" bash -c "! grep -qE '(restart|stop) omarchy-we' '$MOCK_LOG'"
ln -sf "$UB/gone-forever.jpg" "$STATE/current/background"
: >"$MOCK_LOG"
check "dangling bg symlink: sync exits 0" "$SYNC"
check "dangling bg symlink: launcher stopped" grep -q "stop omarchy-we.service" "$MOCK_LOG"
unset MOCK_WE_ACTIVE
ln -sf "$UB/we-111.jpg" "$STATE/current/background"

echo "test: a landed capture upgrades the still and re-renders the palette"
SHOTS_DIR="$HOME/.cache/omarchy-auto-theme/we-shots"
mkdir -p "$SHOTS_DIR"
printf 'fullres' >"$SHOTS_DIR/111.jpg"   # newer than the imported still
: >"$MOCK_LOG"
check "capture landed: sync exits 0" "$SYNC"
check "still upgraded in place" bash -c "[[ \$(cat '$UB/we-111.jpg') == fullres ]]"
check "palette re-rendered from the upgraded still" \
  grep -q "matugen image $UB/we-111.jpg" "$MOCK_LOG"
export MOCK_WE_ACTIVE=0
: >"$MOCK_LOG"
check "second sync: upgrade is one-shot" \
  bash -c "'$SYNC' && ! grep -q matugen '$MOCK_LOG'"
unset MOCK_WE_ACTIVE
check "import refresh keeps the upgraded still" \
  bash -c "'$WE' import >/dev/null 2>&1 && [[ \$(cat '$UB/we-111.jpg') == fullres ]]"
rm -f "$STATE/matugen-auto.we"   # force a relaunch with the capture cached
: >"$MOCK_LOG"
check "restart with cached capture: no follow-up scheduled" \
  bash -c "'$SYNC' && grep -q -- '--no-block restart' '$MOCK_LOG' && ! grep -q systemd-run '$MOCK_LOG'"

echo "test: --exec-current builds the launch from the current background"
ln -sf "$UB/we-111.jpg" "$STATE/current/background"
: >"$MOCK_LOG"
check "we bg: exec-current exits 0" "$WE" --exec-current
check "one --screen-root/--bg pair per monitor" \
  grep -q -- "--screen-root DP-1 --bg 111 --screen-root HDMI-A-1 --bg 111" "$MOCK_LOG"
check "default WE_FLAGS included" grep -q -- "--silent --fps 30 --disable-mouse" "$MOCK_LOG"
check "cached capture: no --screenshot flag" bash -c "! grep -q -- '--screenshot' '$MOCK_LOG'"
ln -sf "$UB/we-444.jpg" "$STATE/current/background"
: >"$MOCK_LOG"
check "uncaptured wallpaper: exec-current exits 0" "$WE" --exec-current
check "first launch requests a full-res capture" \
  grep -q -- "--screenshot $SHOTS_DIR/444.jpg --screenshot-delay 90" "$MOCK_LOG"
ln -sf "$STATE/wall.png" "$STATE/current/background"
: >"$MOCK_LOG"
check "static bg: exec-current exits 0 without launching" \
  bash -c "'$WE' --exec-current && ! grep -q linux-wallpaperengine '$MOCK_LOG'"
ln -sf "$UB/we-111.jpg" "$STATE/current/background"
mkdir -p "$HOME/.config/omarchy-auto-theme"
printf 'WE_SCREENS="DP-9"\nWE_FLAGS="--fps 24"\n' >"$HOME/.config/omarchy-auto-theme/settings"
: >"$MOCK_LOG"
check "WE_SCREENS override: exits 0" "$WE" --exec-current
check "override screen used, no monitor probe" \
  bash -c "grep -q -- '--fps 24 --screen-root DP-9 --bg 111' '$MOCK_LOG' && ! grep -q hyprctl '$MOCK_LOG'"
cat >"$HOME/.local/bin/we-launch" <<'EOF'
#!/bin/bash
echo "we-launch $*" >>"$MOCK_LOG"
EOF
chmod +x "$HOME/.local/bin/we-launch"
printf 'WE_LAUNCH="we-launch --custom %%id"\n' >"$HOME/.config/omarchy-auto-theme/settings"
: >"$MOCK_LOG"
check "WE_LAUNCH override: exits 0" "$WE" --exec-current
check "override ran with the id substituted" grep -q -- "we-launch --custom 111" "$MOCK_LOG"
check "override replaces the built launch" bash -c "! grep -q linux-wallpaperengine '$MOCK_LOG'"
printf 'WE_FLAGS="--fps 30; rm -rf /"\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "invalid WE_FLAGS: exit 2" bash -c "'$WE' --exec-current; [[ \$? -eq 2 ]]"
printf 'WE_SCREENS="DP-1;x"\n' >"$HOME/.config/omarchy-auto-theme/settings"
check "invalid WE_SCREENS: exit 2" bash -c "'$WE' --exec-current; [[ \$? -eq 2 ]]"
rm -f "$HOME/.config/omarchy-auto-theme/settings"

echo "test: Steam's manifest filters lingering unsubscribed content"
export WE_ACF="$HOME/appworkshop.acf"
printf '"AppWorkshop"\n{\n\t"WorkshopItemsInstalled"\n\t{\n\t\t"111"\n\t\t{\n\t\t}\n\t}\n\t"WorkshopItemDetails"\n\t{\n\t\t"111"\n\t\t{\n\t\t}\n\t\t"666"\n\t\t{\n\t\t}\n\t}\n}\n' >"$WE_ACF"
: >"$MOCK_LOG"
check "import with manifest exits 0" "$WE" import
check "subscribed stills kept" bash -c "test -f '$UB/we-111.jpg' && test -f '$UB/we-666.jpg'"
check "unsubscribed-but-on-disk stills removed" \
  bash -c "[[ ! -e '$UB/we-222.jpg' && ! -e '$UB/we-444.jpg' ]]"
printf 'junk not a manifest\n' >"$WE_ACF"
check "unparseable manifest: falls back to the dirs" \
  bash -c "'$WE' import >/dev/null 2>&1 && test -f '$UB/we-222.jpg'"
unset WE_ACF
check "no manifest: dirs stay authoritative" \
  bash -c "'$WE' import >/dev/null 2>&1 && test -f '$UB/we-444.jpg'"

echo "test: import applies a cache frame that landed while sync was not looking"
printf 'fullres444' >"$SHOTS_DIR/444.jpg"
check "import upgrades the still from the newer cached frame" \
  bash -c "'$WE' import >/dev/null 2>&1 && [[ \$(cat '$UB/we-444.jpg') == fullres444 ]]"

echo "test: --diagnose covers the WE pipeline"
export MOCK_WE_ACTIVE=0
check "--diagnose passes with we bg and running launcher" "$SYNC" --diagnose
unset MOCK_WE_ACTIVE
check "--diagnose flags a we bg without the launcher running" \
  bash -c "! '$SYNC' --diagnose >/dev/null 2>&1"
ln -sf "$STATE/wall.png" "$STATE/current/background"
check "--diagnose passes again on a static bg" "$SYNC" --diagnose

echo "test: uninstall removes the we unit and imported stills"
: >"$MOCK_LOG"
check "uninstall exits 0" "$REPO_DIR/uninstall.sh"
check "we unit disabled" grep -q "disable --now omarchy-we.service" "$MOCK_LOG"
check "we unit file removed" test ! -e "$HOME/.config/systemd/user/omarchy-we.service"
check "subscription watcher units removed" \
  bash -c "! ls '$HOME/.config/systemd/user/'omarchy-we-import.* >/dev/null 2>&1"
check "imported stills removed" bash -c "! ls '$UB'/we-* >/dev/null 2>&1"
check "we manifest removed" test ! -e "$UB/.omarchy-auto-theme-we"
check "capture cache removed" test ! -e "$HOME/.cache/omarchy-auto-theme"
check "user file survives uninstall" grep -q "precious" "$UB/handadded.png"
unset WE_WORKSHOP_DIR

if command -v systemd-analyze >/dev/null 2>&1; then
  echo "test: shipped units verify (base alone, and with each drop-in shape)"
  UNITS="$WORK/unit-verify"
  mkdir -p "$UNITS/omarchy-bg-rotate.timer.d"
  cp "$REPO_DIR"/systemd/omarchy-bg-rotate.timer "$REPO_DIR"/systemd/omarchy-bg-rotate.service "$UNITS/"
  check "base timer loads without drop-in" \
    bash -c "SYSTEMD_UNIT_PATH='$UNITS' systemd-analyze verify --user omarchy-bg-rotate.timer 2>&1 | { ! grep -q 'bad unit file'; }"
  printf '[Timer]\nOnActiveSec=\nOnUnitActiveSec=\nOnActiveSec=45m\nOnUnitActiveSec=45m\nPersistent=false\n' >"$UNITS/omarchy-bg-rotate.timer.d/interval.conf"
  check "interval drop-in verifies" \
    bash -c "SYSTEMD_UNIT_PATH='$UNITS' systemd-analyze verify --user omarchy-bg-rotate.timer 2>&1 | { ! grep -q 'bad unit file'; }"
  printf '[Timer]\nOnActiveSec=\nOnUnitActiveSec=\nOnCalendar=daily\nPersistent=true\n' >"$UNITS/omarchy-bg-rotate.timer.d/interval.conf"
  check "daily drop-in verifies" \
    bash -c "SYSTEMD_UNIT_PATH='$UNITS' systemd-analyze verify --user omarchy-bg-rotate.timer 2>&1 | { ! grep -q 'bad unit file'; }"
  cp "$REPO_DIR/systemd/omarchy-we.service" \
     "$REPO_DIR/systemd/omarchy-we-import.path" "$REPO_DIR/systemd/omarchy-we-import.service" "$UNITS/"
  check "we launcher unit verifies" \
    bash -c "SYSTEMD_UNIT_PATH='$UNITS' systemd-analyze verify --user omarchy-we.service 2>&1 | { ! grep -q 'bad unit file'; }"
  check "we subscription watcher verifies" \
    bash -c "SYSTEMD_UNIT_PATH='$UNITS' systemd-analyze verify --user omarchy-we-import.path 2>&1 | { ! grep -q 'bad unit file'; }"
fi

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAILED"
[[ $FAILED -eq 0 ]]
