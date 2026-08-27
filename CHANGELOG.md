# Changelog

## Unreleased

### Fixed
- **`--wallpapers` no longer breaks background cycling.** v1.1.0 symlinked the
  whole folder, but `omarchy-theme-bg-set` stores the current background
  through `realpath` while `omarchy-theme-bg-next` compares unresolved paths —
  behind a dir symlink they never match, so every "next" (SUPER+CTRL+SPACE and
  the new rotation timer alike) pinned to the alphabetically first image. The
  installer now hardlinks the images into a real managed directory (marker
  file records the source folder), migrates the old symlink automatically, and
  a plain `./install.sh` rerun refreshes the collection from the remembered
  folder.

### Added
- **Wallpaper rotation** via a single `ROTATE` knob in
  `~/.config/omarchy-auto-theme/settings`: `daily` for a new wallpaper every
  morning (persistent across suspend), or an interval like `30m`/`2h` for
  continuous rotation. A systemd user timer (`omarchy-bg-rotate.timer`) calls
  Omarchy's own `omarchy-theme-bg-next`, so transitions and the color pipeline
  come for free. The sync script reconciles the timer against the setting on
  every run — edit the knob and it applies on the next wallpaper/theme change
  (or an install rerun), with no separate command. Unsetting `ROTATE` tears
  the timer back down. `--diagnose` reports rotation state; uninstall removes
  the units and the generated schedule.

## v1.1.0 — 2026-08-23

Ease-of-use pass: the second-day tasks (own wallpapers, light mode, tuning)
no longer require reading the README.

### Added
- **`./install.sh --wallpapers <dir>`** links your own wallpaper folder as the
  theme's background collection in one step: validates the folder contains
  images, backs up any existing regular background directory under a
  non-conflicting `.bak` name, skips seeding starter backgrounds, and
  generates the initial palette from your folder.
- **The installer seeds a commented settings file** at
  `~/.config/omarchy-auto-theme/settings` when none exists, so `PREFER` and
  `MODE` are discoverable without the README. An existing file is never
  touched.
- The installer's closing message now points at `--wallpapers`, the settings
  file, and `omarchy-matugen-sync --diagnose`.

### Changed
- **Light mode is now one knob.** The palette template emits
  `mode = "{{mode}}"` (a matugen template keyword that follows the `--mode`
  flag), so `MODE=light` in the settings file is sufficient — previously the
  template's hardcoded `mode = "dark"` had to be edited to match.
  `--diagnose` still flags a customized template whose literal mode disagrees
  with the settings.

### Fixed
- README linked matugen via a `githu.com` typo.

## v1.0.2 — 2026-08-23

Second-pass lifecycle hardening from two follow-up reviews.

### Fixed
- **A failed `omarchy-theme-refresh` was recorded as success**: the sync
  script committed the wallpaper fingerprint before running the refresh, so a
  refresh failure was never retried until the wallpaper changed again. The
  fingerprint is now written (atomically) only after the whole pipeline
  succeeds.
- **Uninstall deleted `.new` files unconditionally**: `remove_owned` now
  applies the same byte-identical ownership rule to the `.new` copy a
  reinstall leaves beside a modified config, keeping one the user edited or
  repurposed.
- **Wallpaper fingerprint missed same-size edits within one second**: mtime
  is now compared at nanosecond resolution.
- The installer's background-existence probe used `find | grep -q` under
  `pipefail`, which a SIGPIPE could turn into a wrong answer; both lookups now
  use `find -print -quit`.
- **Legacy migration could overwrite an existing `quattro.toml.bak`**: the
  backup now takes a non-conflicting name (`quattro.toml.bak.1`, `.2`, ...)
  when one already exists.
- **Stale output no longer passes install validation**: the installer now
  requires `colors.toml` to be newly written by its matugen run, so a leftover
  file from an earlier install can't mask a config that stopped rendering.
- `quattro.toml.new` is now only deleted when it still carries the v1.0.0
  header; a repurposed file is left alone (install and uninstall).

### Changed
- **User tuning moved out of the sync script** into
  `~/.config/omarchy-auto-theme/settings` (`PREFER=`, `MODE=`), read by both
  the installer's initial generation and every sync. The sync script and
  systemd units are project-owned executables: installs overwrite them,
  uninstall removes them, and the settings file — never touched by either —
  is where customization survives. Previously the README told you to edit the
  installed script, which a reinstall would have clobbered.
- The installer's one-shot service start is documented as a launch check only
  (unit, PATH, script location); `omarchy-matugen-sync --diagnose` covers the
  full pipeline.
- `MODE` and `PREFER` from the settings file are validated after loading
  (`dark|light`, identifier-shaped preference); the file is documented as a
  trusted bash fragment. `--diagnose` additionally flags a half-configured
  light mode where the settings `MODE` and the palette template's `mode`
  line disagree.
- The sync script is installed with `install -Dm755`; CI enumerates every
  bash file dynamically for `bash -n` + ShellCheck (a new script can't be
  silently skipped), prints the ShellCheck version, and pins
  `actions/checkout` by commit.

### Added
- Tests for the new behavior and previously unexercised failure paths:
  `.bak` collision, foreign `quattro.toml.new` preservation, stale
  `colors.toml` rejection, matugen exiting 0 without output, `systemctl`
  failures during install and uninstall, settings-file overrides and
  validation, refresh-failure retry, same-second wallpaper replacement, and
  modified-`.new` preservation (71 assertions, up from 45).
- CI now ShellChecks the tmux shim too.

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
