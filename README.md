# omarchy-matugen

Wallpaper-adaptive theming for [Omarchy](https://omarchy.org) 4.0 (Quattro).

Change your wallpaper and the desktop follows: [matugen](https://github.com/InioX/matugen) extracts a Material You palette from the image and renders it into a real Omarchy theme. Omarchy then propagates that palette to everything it themes, which on 4.0 means the Quickshell bar, notifications, the lock screen, terminals, neovim, btop, Claude Code, and about fifteen other apps, all from one generated `colors.toml`.

Omarchy 4.0 shipped without dynamic colors (it's an open wish in [basecamp/omarchy#1153](https://github.com/basecamp/omarchy/discussions/1153)). This adds them without touching any packaged file.

## How it works

```
wallpaper change (keybind, bg-switcher, CLI)
        │  systemd path unit watches ~/.local/state/omarchy/current
        ▼
omarchy-matugen-sync
        │  matugen: image → Material You palette → colors.toml
        ▼
~/.config/omarchy/themes/matugen-auto/colors.toml
        │  omarchy theme refresh
        ▼
every app Omarchy themes, live-reloaded
```

Everything is installed under your home directory, so `omarchy update` won't overwrite it.

## Requirements

- Omarchy 4.0+ (Quattro)
- matugen: `omarchy pkg aur add matugen-bin`

## Install

```bash
git clone https://github.com/AccursedGalaxy/omarchy-matugen.git
cd omarchy-matugen
./install.sh
omarchy theme set matugen-auto
```

Then hit `SUPER + CTRL + SPACE` and pick a wallpaper.

## Using your own wallpapers

The installer seeds a few starter backgrounds. To use your own collection, point Omarchy's user-background directory at it:

```bash
ln -sfn ~/Pictures/Wallpapers ~/.config/omarchy/backgrounds/matugen-auto
omarchy theme set matugen-auto   # re-apply so Omarchy picks up the new list
```

One quirk: Omarchy snapshots the background list when a theme is applied, so wallpapers you add later only show up in the switcher after the next `omarchy theme set matugen-auto`. Color generation itself always uses whatever wallpaper is currently set.

## Extras

Adaptive tmux status bar (`extras/tmux-colors.conf.template`): a tmux theme driven by the same palette. Copy it to `~/.config/matugen/templates/tmux-colors.conf`, uncomment the `[templates.tmux]` block in `~/.config/matugen/quattro.toml`, and add this line to your tmux.conf:

```
source-file -q ~/.config/matugen/generated/tmux-colors.conf
```

Terminal transparency fix (`extras/clear-tmux-window-style`): Omarchy 4 paints a solid theme background onto tmux panes on every theme change (via tmux's `window-style`), which defeats transparent terminals. If you run a transparent terminal with tmux, install this hook:

```bash
omarchy hook install theme-set extras/clear-tmux-window-style
```

Claude Code needs nothing extra. Omarchy renders a Claude theme from `colors.toml` and hot-reloads running sessions; activate it once with `omarchy-theme-set-claude --activate`.

The same pattern extends to anything matugen can template (neovim, starship, zsh, yazi, and so on): add a `[templates.<name>]` block to `~/.config/matugen/quattro.toml` with your template, an output path, and a post_hook that reloads the app. Every wallpaper change renders all of them from the same palette in one matugen run.

## Tuning

After install, the palette mapping lives in `~/.config/matugen/templates/omarchy-quattro-colors.toml`. Two things to know before editing it:

- matugen 4.x's `set_lightness` filter is absolute: it sets the HSL lightness percentage while keeping hue and saturation, and negative values clamp to black. The template relies on this for the background ramp and the bright colors.
- Non-interactive matugen 4.x errors out with "Multiple source colors found" unless you pass `--prefer`. The sync script uses `--prefer saturation`; swap it for `darkness`, `lightness`, or another preference in `~/.local/bin/omarchy-matugen-sync` if you want a different vibe.

For light mode, change `--mode dark` to `--mode light` in the sync script and `mode = "dark"` to `mode = "light"` in the template.

## Uninstall

```bash
./uninstall.sh
omarchy theme set tokyo-night   # or any theme you like
```

The theme directory (`~/.config/omarchy/themes/matugen-auto`) is left in place so you keep your backgrounds. Delete it if you want a full cleanup.

## License

MIT
