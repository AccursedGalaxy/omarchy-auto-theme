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
[[ ${MOCK_REFRESH_FAIL:-} == 1 ]] && exit 1
exit 0
EOF
cat >"$MOCKS/omarchy-theme-bg-next" <<'EOF'
#!/bin/bash
echo "omarchy-theme-bg-next" >>"$MOCK_LOG"
EOF
cat >"$MOCKS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MOCK_LOG"
[[ ${MOCK_SYSTEMCTL_FAIL:-} == 1 ]] && exit 1
case " $* " in
  *" is-enabled "*) exit "${MOCK_TIMER_ENABLED:-1}" ;;   # default: not enabled
  *" is-active "*)  exit "${MOCK_TIMER_ACTIVE:-0}" ;;    # default: active
esac
exit 0
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
        MOCK_TIMER_ENABLED MOCK_TIMER_ACTIVE
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
fi

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAILED"
[[ $FAILED -eq 0 ]]
