# Spec: first-class Wallpaper Engine wallpapers in Omarchy

Status: designed, not implemented. Target: merge together with the existing
`feature/live-wallpaper-image` work as one release.

This document is self-contained: it records both what we intend to build and
the investigation findings it rests on, with file references into Omarchy
4.0.0.alpha (`/usr/share/omarchy`) and linux-wallpaperengine r627 as installed
on the dev machine (2026-08-28). Re-verify the referenced internals if either
has updated since.

## 1. Goal and principles

Make Wallpaper Engine wallpapers behave exactly like native Omarchy
backgrounds: pick them in the stock SUPER+CTRL+SPACE thumbnail grid, cycle
them with `omarchy theme bg next` and the ROTATE timer, and have the theme
palette follow — with zero new UI, zero new keybinds, and zero configuration
for the default case.

Principles (set by Robin):

- Stupid simple. Feels like Omarchy. Works out of the box IF wanted.
- Opt-in at every layer; installing omarchy-auto-theme activates nothing
  WE-related.
- Nothing locks you in. Users with their own WE setup (custom scripts, GUIs,
  autostart lines) keep it; every convenience layer has a bypass, and the
  lower layers (`--image`, `omarchy-auto-theme-we <target>`) remain public
  interfaces.
- Never patch Omarchy files. Use only surfaces graded stable/public below.

## 2. The core insight

Omarchy's background switcher is not a cycler — it is a thumbnail grid
(`omarchy-menu-images`, driven by `omarchy-theme-bg-switcher`) over two
directories, of which one is the documented user drop-zone:
`~/.config/omarchy/backgrounds/<theme-slug>/`. Both the switcher and
`omarchy-theme-bg-next` scan it with `find -L -maxdepth 1 -type f` for
`jpg|jpeg|png|gif|bmp|webp`.

So: **hardlink each WE project's preview image into
`~/.config/omarchy/backgrounds/matugen-auto/` as `we-<workshopid>.<ext>`** and
WE wallpapers appear in the native grid with real thumbnails, cycle with
bg-next, and highlight correctly as selected (`omarchy-menu-images:99` matches
by `-samefile`, which hardlinks satisfy).

When the user picks one, `omarchy-theme-bg-set` rewrites the
`~/.local/state/omarchy/current/background` symlink — which already triggers
our `omarchy-matugen.path` unit. The sync script then:

1. renders the palette from the preview image via the normal pipeline (the
   selected background IS the preview — no special theming path needed), and
2. notices the `we-<id>` basename and starts/replaces a linux-wallpaperengine
   instance for that id; or stops it when a non-WE background was picked.

linux-wallpaperengine draws on wlr-layer-shell layer `bottom` (level 1, its
default); Omarchy's background plugin draws on `background` (level 0).
Verified live via `hyprctl layers`: WE covers the static image unconditionally
and the two never fight. The static preview underneath is not waste — it is
the loading frame (preview flashes, live wallpaper fades in over it), the
lock-screen image (`shell/plugins/lock/Service.qml:17` reads the symlink), the
bar-contrast source (`omarchy-bar-text-color:78`), and the automatic fallback
if WE crashes.

This dissolves the previously-planned "menu + keybind" layer entirely.
Omarchy already does all of it.

## 3. Components to build

### 3.1 `omarchy-auto-theme-we import` (collection sync)

Scans `${WE_WORKSHOP_DIR:-~/.local/share/Steam/steamapps/workshop/content/431960}`
and materializes one still per project into the backgrounds collection:

- Name: `we-<workshopid>.jpg` (id = directory name; `project.json`'s
  `workshopid` field is often absent). The filename is the detection contract
  — never rely on inode reverse-lookup.
- Still derivation: `preview.jpg/png` → hardlink (fall back to copy across
  filesystems, same as install.sh's wallpaper linking); `preview.gif` or
  video-type project → `ffmpeg -vf thumbnail -frames:v 1` to a jpg (reuse the
  frame-extraction path from `bin/omarchy-auto-theme-we`).
- Ownership: extend the existing `.omarchy-auto-theme-source` manifest
  pattern (or a parallel `.omarchy-auto-theme-we` manifest) so refreshes
  remove only entries we created and uninstall leaves user files alone —
  exactly the semantics install.sh already implements for `--wallpapers`.
- Optional filter: `import <id>...` imports selected projects;
  bare `import` imports all. `import --remove` clears our entries.
- Re-run refreshes (new subscriptions appear, unsubscribed ones go away).
  Consider wiring a plain `./install.sh` rerun to also refresh the WE
  collection when it exists, mirroring the wallpaper-folder refresh.

### 3.2 Detection + launch in `omarchy-matugen-sync`

After the existing guards resolve `bg` (normal flow, not `--image`):

- If `basename` matches `we-<id>.<ext>` and the id exists under the workshop
  dir: render palette as usual from the file, then ensure WE is running with
  that id (3.3). If the workshop project vanished, just render the palette
  (the still keeps working as a normal wallpaper) and log a note.
- If the new background is NOT a WE entry: stop the WE unit if active.
- The `--image` path is unaffected.

Frictions from the pipeline investigation to honor:

- The path unit coalesces events (theme switches touch `theme.name`,
  `theme/`, and `background` in quick succession, in a different order than
  plain bg-set) — the script must re-read current state and stay idempotent.
  The existing fingerprint guard already provides this shape.
- Theme switches auto-advance the background
  (`omarchy-theme-set:59-87 choose_theme_background` picks NEXT, not first),
  so "theme changed" and "background changed" must share one code path — they
  already do (the path unit).
- Do NOT rely on setting the symlink without IPC: `omarchy-theme-bg-set` does
  both, and the shell does not poll the symlink in this build (the comment in
  `bg-set:23-24` claiming it does is stale).

### 3.3 WE process ownership: a systemd user unit

`omarchy-we.service` (shipped, installed to `~/.config/systemd/user/`, which
survives `omarchy update`):

- `ExecStart=%h/.local/bin/omarchy-auto-theme-we --exec-current` — a mode
  that reads the current background symlink, extracts the `we-<id>`, builds
  the launch command, and execs it. Unit start = launch; unit stop = clean
  kill of the whole CEF process tree (WE spawns chrome helpers; systemd's
  cgroup handles what pkill cannot). This replaces the pkill/pgrep dance for
  the managed path; the standalone `-- command` exec mode keeps it.
- The sync script "ensures WE running" via `systemctl --user restart
  omarchy-we.service` (restart covers both start and replace).
- `Restart=on-failure`, `StartLimitIntervalSec`/`StartLimitBurst` so a
  crashing scene degrades to the static preview instead of crash-looping
  (linux-wallpaperengine has known per-wallpaper crashes: CEF init deadlocks
  #628/#637/#657, PulseAudio detector hang #649, black renders #629/#523).
  A hung start cannot be detected via readiness (WE has no sd_notify);
  accept that and document `systemctl --user status omarchy-we` in
  troubleshooting + `--diagnose`.
- Autostart falls out for free: `WantedBy=graphical-session.target` with the
  same `--exec-current` logic — if the current background at login is a WE
  entry, the wallpaper comes back; if not, the unit exits 0 immediately.
  No separate autostart config, no autostart.lua edits. State IS the
  current-background symlink. (If a session-scoped alternative is ever
  wanted: the blessed mechanism is `o.launch_on_start()` in
  `~/.config/hypr/autostart.lua`, but that file is refreshable by
  `omarchy refresh hyprland` — the systemd unit is strictly safer.)
- Install enables the unit only when the user runs `import` the first time
  (opt-in), or via an explicit flag; plain install.sh keeps activating
  nothing WE-related. Uninstall disables and removes it.

### 3.4 Launch construction (multi-monitor + knobs)

One WE process drives all monitors: `--screen-root <name>` is repeatable with
a per-screen `--bg` (verified against the binary's own usage strings).

Settings (same sourced-bash settings file, all optional, validated like
PREFER/MODE/ROTATE):

- `WE_FLAGS` — extra flags, default `--silent --fps 30 --disable-mouse`.
  Rationale: `--silent` also sidesteps the PulseAudio-detector hang class;
  fps cap is standard advice for GPU-heavy scenes; `--disable-mouse` because
  Omarchy's desktop double-click menu lives on the occluded background
  surface and WE would swallow it otherwise (verify input behavior during
  implementation — if WE passes input through anyway, drop the default).
- `WE_SCREENS` — space-separated output names; default: all outputs from
  `hyprctl monitors -j`, same wallpaper on each (matches Omarchy's own
  one-image-for-all model). Per-monitor different wallpapers: out of scope
  v1 (Omarchy itself has no per-monitor backgrounds; revisit on demand).
  Monitor hotplug does not re-fire anything of ours — v1 accepts that a
  hotplugged output shows the static layer until the next wallpaper change
  (document it); a `--exec-current` restart fixes it manually.
- `WE_LAUNCH` — full override template for users driving WE their own way
  (GUIs, custom scripts). If set, the unit execs it (with `%id` substituted)
  instead of building a command; everything else (palette, detection,
  collection) still works. This is the no-lock-in escape hatch.
- `--layer` stays at WE's default `bottom`. Never pass `--layer background`
  (same-layer stacking against Omarchy is map-order-dependent and fragile).
  Do not disable `omarchy.background` via `shell.json disabledPlugins[]` in
  v1 — the occluded layer is load-bearing (lock screen, fallback, contrast)
  and `shell.json` is Omarchy-managed (migrations rewrite it). Reserve as a
  documented power-user note only.

### 3.5 Layer 1/2 surfaces (already shipped) stay public

`omarchy-matugen-sync --image` and `omarchy-auto-theme-we
<id|dir|image|video> [-- command]` remain documented, unchanged. `--menu` is
dropped from the plan (native grid replaces it). An optional
`extensions/omarchy-menu.jsonc` entry is NOT added by the installer: the file
is a single user-owned JSONC file and naive JSON rewriting destroys user
comments; at most, README shows a copy-paste snippet the user can add.

## 4. What Omarchy provides that we must NOT rebuild

| Need | Omarchy surface (grade) |
|---|---|
| Thumbnail picker | `omarchy-menu-images`, driven via native bg switcher (stable) |
| Keybind | existing SUPER+CTRL+SPACE → `omarchy-menu toggle background` |
| Cycling/rotation | `omarchy-theme-bg-next` + our existing ROTATE timer |
| Wallpaper drop-zone | `~/.config/omarchy/backgrounds/<theme-slug>/` (stable, documented) |
| Change event | `~/.local/state/omarchy/current` + our existing path unit |
| Re-theme without touching background | `OMARCHY_THEME_SKIP_BACKGROUND=1` (semi-public, already load-bearing for us) |
| Theme-change hook (ordered, if ever needed) | `omarchy hook install theme-set ...` (stable; note: NO background-set hook exists — the path unit remains the only bg trigger) |
| Text picker / input, if ever needed | `omarchy-menu-select`, `omarchy-menu-input` (stable) |
| User keybind docs | `~/.config/hypr/bindings.lua` + `o.bind(keys, desc, cmd)` — a bind without a description is invisible in the keybindings menu |

Explicitly rejected: shipping as an Omarchy plugin (`omarchy plugin add` loads
QML into the shell process only — no binaries, no units, no hooks, no install
scripts; symlinks are forbidden in plugin dirs and updates are git ff-only).
A `bar-widget` or a `"type":"command"` bar module in `shell.json` could later
show WE status, but v1 has no bar presence.

## 5. Failure and edge behavior

- WE crashes or a scene is incompatible → unit hits its restart limit and
  stays down; desktop shows the static preview (already on screen
  underneath). `--diagnose` gains checks: workshop dir present, WE binary
  present, unit state, current bg ↔ WE id consistency.
- Workshop project deleted after import → import refresh removes our still;
  if selected meanwhile, palette still renders from the still; WE launch is
  skipped with a journal note.
- Steam not running: fine — WE reads project files off disk; it only needs
  the WE assets dir from a one-time install (or `--assets-dir`).
- `project.json` `type` is case-inconsistent (`"Web"` observed) — compare
  case-insensitively. `file` names the video for video-type projects.
- Uninstall: stop+remove unit, remove manifest-listed `we-*` stills, keep
  everything user-added; existing uninstall semantics.
- The `--image` clobber guard (commit-before-refresh) is unaffected; WE
  selection goes through the NORMAL flow (bg symlink changed), so the
  standard fingerprint logic applies untouched.

## 6. Test plan (extend tests/run-tests.sh; mocks exist for matugen, refresh,
systemctl, ffmpeg, pkill/pgrep)

- import: fake workshop tree (scene w/ preview.jpg, video w/ preview.gif,
  spaces in titles) → stills hardlinked with `we-<id>` names, manifest
  written; refresh adds/removes; user files untouched; uninstall cleans.
- detection: bg symlink → `we-<id>.jpg` → `systemctl --user restart
  omarchy-we.service` logged, palette rendered from the still; non-WE bg →
  `stop` logged only when unit was active; missing workshop dir → render
  only, no restart, exit 0.
- `--exec-current`: current bg is WE entry → exec of constructed command
  (mock hyprctl for monitor list; assert one `--screen-root X --bg <id>`
  pair per monitor and WE_FLAGS inclusion); non-WE bg → exit 0, no exec;
  WE_LAUNCH set → override execed with id substituted.
- settings validation for the three new knobs (reject shell metacharacters
  as with PREFER).
- unit file: `systemd-analyze verify` alongside the existing unit checks.
- Live verification checklist (manual, on this machine): pick WE entry in
  native grid → preview flashes → live wallpaper appears → colors follow;
  pick static wallpaper → WE stops; `ROTATE=…` cycles across mixed
  collection; reboot restores; `omarchy update` survives; double-click
  desktop behavior with/without `--disable-mouse`.

## 7. Out of scope (v1)

- Per-monitor different wallpapers; monitor-hotplug reactions.
- WE playlist support (`--playlist` exists in git builds but reads Wallpaper
  Engine's Windows-style config.json; our ROTATE + bg-next covers rotation).
- Workshop browsing/downloading (Steam client's job; document steamcmd as a
  power-user note).
- Bar widget / shell.json edits / disabling `omarchy.background`.
- Wine/proprietary WE; only linux-wallpaperengine.

## 8. Open questions for the implementation session

1. Does WE's `bottom`-layer surface swallow the desktop double-click?
   Test first; it decides the `--disable-mouse` default.
2. Exact restart-limit numbers (suggest `StartLimitBurst=3` in `60s`).
3. Does `systemctl --user restart` from inside the sync script (itself a
   systemd service) need `--no-block` to avoid ordering deadlocks? Test.
4. Import UX: auto-import-all on first `import`, or interactive selection via
   `omarchy-menu-images --filterable` over workshop previews? (The picker is
   public; a selection step would still be zero new UI.) Default proposal:
   import all, `import --remove <id>` to prune.
