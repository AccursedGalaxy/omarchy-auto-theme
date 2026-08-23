# Changelog

## v1.0.1 — 2026-08-23

Configuration-lifecycle fixes from a pre-launch review. Upgrade by rerunning
`./install.sh`; it migrates the old shared config safely.

### Fixed
- **Uninstall could delete a pre-existing user file**: `uninstall.sh` removed
  `~/.config/matugen/quattro.toml` unconditionally, even when it predated this
  project. The uninstaller now only removes files that are byte-identical to
  what this repo distributes and tells you about anything it kept.
- **Install was nonfunctional with an existing `quattro.toml`**: the installer
  preserved the user's file but then invoked matugen against it, so the theme's
  `colors.toml` was never generated. The project now owns its own config,
  `~/.config/matugen/omarchy-auto-theme.toml`, and always invokes that.
- The installer now verifies that matugen actually produced `colors.toml` and
  that the systemd service starts, instead of reporting success blindly. The
  watcher is only enabled after generation is proven to work.
- The wallpaper idempotency guard now fingerprints path + size + mtime, so an
  image edited or replaced in place regenerates the palette (previously only a
  path change did).
- The sync script pins its own `PATH` (including `$OMARCHY_PATH/bin` and
  `/usr/bin`) instead of trusting the systemd user manager's inherited one.
- A latent `set -e`/pipefail bug in the installer's seed-background lookup that
  could abort a clean install when no user background directory existed.

### Changed
- The matugen config moved from the shared `~/.config/matugen/quattro.toml` to
  the project-owned `~/.config/matugen/omarchy-auto-theme.toml`. A v1.0.0
  `quattro.toml` is moved to `quattro.toml.bak` on upgrade; a foreign one is
  left untouched. User modifications to the project config or palette template
  survive reinstall (the new version lands next to them as `.new`) and
  uninstall.

### Added
- `omarchy-matugen-sync --diagnose`: checks every link in the pipeline —
  commands, config, template, output permissions, wallpaper state, watcher
  unit.
- README troubleshooting section (`systemctl`/`journalctl` recipes, silent-exit
  guards explained) and safe instructions for pointing the wallpaper directory
  at your own collection when a real directory already exists there.
- Test suite (`tests/run-tests.sh`, 45 assertions): clean install, reinstall,
  pre-existing user config, legacy migration, failed generation, uninstall
  ownership rules, spaces in `$HOME`, and sync-script guard behavior — all
  against a throwaway `$HOME` with mocked commands.
- GitHub Actions CI: `bash -n`, ShellCheck, `systemd-analyze verify`, and the
  test suite.

## v1.0.0 — 2026-08-22

Initial release: wallpaper-adaptive Material You theming for Omarchy 4.0
(Quattro) via matugen, a systemd path unit, and Omarchy's native theme engine.
