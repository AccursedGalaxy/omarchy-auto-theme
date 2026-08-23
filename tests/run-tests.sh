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
mkdir -p "$HOME/.config/omarchy/themes/matugen-auto"
echo "# mock colors" >"$HOME/.config/omarchy/themes/matugen-auto/colors.toml"
EOF
cat >"$MOCKS/omarchy-theme-refresh" <<'EOF'
#!/bin/bash
echo "omarchy-theme-refresh" >>"$MOCK_LOG"
EOF
cat >"$MOCKS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"$MOCK_LOG"
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
  # bypass $MOCKS — so the mocks must also live inside the test HOME.
  ln -sf "$MOCKS"/* "$HOME/.local/bin/"
  export MOCK_LOG="$HOME/mock.log"
  : >"$MOCK_LOG"
  unset MOCK_MATUGEN_FAIL
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
fresh_home home-legacy
mkdir -p "$HOME/.config/matugen"
printf '# Matugen config for the omarchy-matugen adaptive theme.\n[config]\n' >"$HOME/.config/matugen/quattro.toml"
printf 'stale' >"$HOME/.config/matugen/quattro.toml.new"
check "installer exits 0" "$REPO_DIR/install.sh"
check "legacy config moved to .bak" test -f "$HOME/.config/matugen/quattro.toml.bak"
check "legacy config no longer active" test ! -f "$HOME/.config/matugen/quattro.toml"
check "stale quattro.toml.new removed" test ! -f "$HOME/.config/matugen/quattro.toml.new"

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
check "uninstaller exits 0" "$REPO_DIR/uninstall.sh"
check "modified project config kept" test -f "$HOME/$CONFIG_REL"
check "modified template kept" test -f "$HOME/$TEMPLATE_REL"
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

check "--diagnose exits 0 on healthy install" "$SYNC" --diagnose

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAILED"
[[ $FAILED -eq 0 ]]
