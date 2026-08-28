# omarchy-auto-theme

Automatic wallpaper-based dynamic theming for [Omarchy](https://omarchy.org) 4.0 (Quattro) on Hyprland.

![Switching wallpapers recolors the terminal and Neovim](assets/demo.gif)

Change your wallpaper and the rest of the desktop follows.
[matugen](https://github.com/InioX/matugen) creates a Material You palette from the image.
The project passes that palette to Omarchy's theme engine, which updates the whole Hyprland desktop: bar, notifications, lock screen, terminals, Neovim, btop, Claude Code, and other supported apps.

It works like pywal or wallust, but nothing here is a standalone colorscheme. The palette renders straight into Omarchy's own theme files, so existing app integrations keep working and packaged Omarchy files stay untouched.

## Quick start

### Requirements

- Omarchy 4.0 or newer (Quattro)
- matugen, installed with:

  ```bash
  omarchy pkg aur add matugen-bin
  ```

### Install

```bash
git clone https://github.com/AccursedGalaxy/omarchy-auto-theme.git
cd omarchy-auto-theme
./install.sh --wallpapers ~/Pictures/Wallpapers   # or plain ./install.sh for starter backgrounds
omarchy theme set matugen-auto
```

Press `SUPER + CTRL + SPACE` and choose a wallpaper. The colors will update automatically.

## Use your own wallpapers

Pass your wallpaper folder to the installer:

```bash
./install.sh --wallpapers ~/Pictures/Wallpapers
```

This hardlinks the folder's images into the theme's background collection (a plain copy across filesystems) and remembers the folder. Without the flag, the installer seeds a few starter backgrounds instead. Any existing background directory is backed up first.

The installer links individual images rather than symlinking the directory: Omarchy's background cycling breaks behind a directory symlink and gets stuck on the first image.

If you add or remove wallpapers later, rerun `./install.sh` to refresh the collection from the remembered folder. The refresh only touches images it linked itself; files you drop into `~/.config/omarchy/backgrounds/matugen-auto/` by hand are kept, on refresh and on uninstall. Omarchy snapshots backgrounds when a theme is applied, so run `omarchy theme set matugen-auto` again to show new ones in the switcher. Color generation always uses the current wallpaper.

## How it works

```text
wallpaper changes (keybind, background switcher, or CLI)
        │
        │  systemd watches ~/.local/state/omarchy/current
        ▼
omarchy-matugen-sync
        │
        │  matugen turns the image into colors.toml
        ▼
~/.config/omarchy/themes/matugen-auto/colors.toml
        │
        │  Omarchy refreshes the active theme
        ▼
supported apps reload with the new palette
```

Everything is installed under your home directory, so `omarchy update` will not overwrite it.

## How does it compare?

### tema

[tema](https://github.com/bjarneo/tema) is an interactive theme generator. You choose a wallpaper and mode, then apply the result. It is a good fit for creating a theme once.

omarchy-auto-theme is a background pipeline. There is nothing to open after installation. A systemd path unit detects wallpaper changes and regenerates the active theme.

### omagen

[omagen](https://github.com/prettyletto/omagen) is an image-to-theme studio that ships as an Omarchy plugin. You pick an image, browse six palette directions, preview them, and save the result as a permanent named theme. Like tema, it is built for making a theme once, by hand.

omarchy-auto-theme has no interface at all. It regenerates the theme in the background on every wallpaper change.

### omarchy-matugen

[omarchy-matugen](https://github.com/jaidev7823/omarchy-matugen) also runs matugen automatically. It shims the `swaybg` binary so wallpaper changes route through swww and matugen.

This project replaces no Omarchy binaries. A systemd path unit watches Omarchy's wallpaper state file and renders into a normal Omarchy theme, so the stock wallpaper flow keeps working unchanged.

### pywal and wallust

[pywal](https://github.com/dylanaraps/pywal) and [wallust](https://codeberg.org/explosion-mental/wallust) provide general-purpose wallpaper colors. You usually need to connect each application yourself.

This project feeds Omarchy's own theme engine instead. Existing Omarchy integrations continue to work and remain maintained through Omarchy updates. It also uses matugen's Material You color generation rather than direct dominant-color extraction.

## Configure palette generation

The generated color mapping is defined in:

```text
~/.config/matugen/templates/omarchy-quattro-colors.toml
```

The installer creates a commented settings file at:

```text
~/.config/omarchy-auto-theme/settings
```

Uncomment a line to override a default:

```sh
PREFER=darkness   # darkness, lightness, saturation, less-saturation, value, closest-to-fallback
MODE=light        # dark or light
ROTATE=30m        # wallpaper rotation: daily, or an interval like 30m / 2h
```

The change takes effect on the next wallpaper switch. Both the installer and the sync process read these settings. The file is sourced as Bash, so treat it as trusted code. All settings are validated after loading.

The installer never overwrites an existing settings file, and the uninstaller keeps it.

### Wallpaper rotation

Set `ROTATE` and the wallpaper advances by itself. A systemd user timer calls Omarchy's own `omarchy-theme-bg-next`, so you get the usual crossfade and the colors follow.

- `ROTATE=daily`: a new wallpaper every morning (fires at midnight; a missed fire runs when the machine wakes up).
- `ROTATE=30m`, `ROTATE=2h`: rotate continuously at that interval.
- Unset (the default): no rotation; the timer is disabled and its config removed.

The setting is applied on every sync run. After editing it, change the wallpaper once (SUPER+CTRL+SPACE) or rerun `./install.sh`; from then on the rotation itself picks up changes. Rotation cycles the backgrounds of whatever theme is active, not just matugen-auto.

Light mode used to require editing `mode = "dark"` in the template as well. The current template emits `mode = "{{mode}}"`, so `MODE` in the settings file is the only knob. `--diagnose` reports when a customized template disagrees with the settings.

### Template details

- In matugen 4.x, `set_lightness` sets an absolute HSL lightness percentage while preserving hue and saturation. Negative values clamp to black. The template uses this behavior for its background ramp and bright colors.
- Non-interactive matugen 4.x can fail with `Multiple source colors found` unless `--prefer` is set. This project defaults to `--prefer saturation`.

## Optional integrations

### Adaptive tmux status bar

The file `extras/tmux-colors.conf.template` provides a tmux theme based on the same palette.

1. Copy the template:

   ```bash
   cp extras/tmux-colors.conf.template ~/.config/matugen/templates/tmux-colors.conf
   ```

2. Uncomment the `[templates.tmux]` block in `~/.config/matugen/omarchy-auto-theme.toml`.
3. Add this line to your tmux configuration:

   ```tmux
   source-file -q ~/.config/matugen/generated/tmux-colors.conf
   ```

### Transparent tmux panes

Omarchy 4 sets a solid background on tmux panes after each theme change. This overrides terminal transparency and can cause a dark flash.

The included shim keeps palette syncing but skips the background override:

```bash
cp extras/omarchy-theme-set-tmux-transparent ~/.local/bin/omarchy-theme-set-tmux
chmod +x ~/.local/bin/omarchy-theme-set-tmux
```

This file shadows an Omarchy script. After major Omarchy updates, compare it with the packaged version:

```bash
diff ~/.local/bin/omarchy-theme-set-tmux /usr/share/omarchy/bin/omarchy-theme-set-tmux
```

Omarchy places its own bin directory first in the session `PATH`. As a result, theme changes started from the shell menu may still use the packaged script. To make the shim take priority across the session, add this to `~/.config/hypr/hyprland.lua`:

```lua
do
  local local_bin = (os.getenv("HOME") or "") .. "/.local/bin"
  local omarchy_bin = (os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/bin"
  local kept = {}
  for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
    if entry ~= local_bin and entry ~= omarchy_bin then table.insert(kept, entry) end
  end
  table.insert(kept, 1, omarchy_bin)
  table.insert(kept, 1, local_bin)
  hl.env("PATH", table.concat(kept, ":"))
end
```

### Claude Code

Claude Code needs no extra template. Omarchy generates its theme from `colors.toml` and reloads running sessions. Activate the integration once:

```bash
omarchy-theme-set-claude --activate
```

### Other matugen templates

You can extend `~/.config/matugen/omarchy-auto-theme.toml` with templates for tools such as Starship, Zsh, Yazi, or Neovim. Add a `[templates.<name>]` block with a template path and output path. Every wallpaper change renders all configured templates in one matugen run.

Once you customize this config, installation and removal will leave it untouched. Future distributed versions are written to `omarchy-auto-theme.toml.new` instead.

Keep these rules in mind:

- **Prefer indexed ANSI colors for shell output.** Values such as `38;5;N` and `fg=4` follow the terminal palette. Unlike fixed hex colors, they can recolor existing scrollback after a theme change, including inside tmux.
- **Do not broadcast reload signals to shells.** Commands such as `pkill -USR2 zsh` can kill processes without a signal handler, including shells waiting on `tmux attach`. When possible, make an app watch its generated file instead.

## FAQ

### How do I get wallpaper-based themes on Omarchy?

Install this project and activate the `matugen-auto` theme (see Quick start). After that, every wallpaper change regenerates the palette and restyles the desktop, whether the change comes from the SUPER + CTRL + SPACE switcher, the rotation timer, or the CLI.

### Does `omarchy update` break it?

No. Everything lives under your home directory, and packaged Omarchy files are never modified.

### How is this different from pywal or wallust?

pywal and wallust generate standalone colors that you wire into each application yourself. This project renders into Omarchy's theme format, so the integrations Omarchy already maintains (bar, lock screen, terminals, Neovim, btop) pick up the colors with no extra wiring. The palette comes from matugen's Material You generation rather than dominant-color extraction.

### Does it support light mode?

Yes. Set `MODE=light` in `~/.config/omarchy-auto-theme/settings`.

### Can it rotate wallpapers on a schedule?

Yes. Set `ROTATE=daily` or an interval such as `ROTATE=30m`. A systemd timer advances the wallpaper and the colors follow.

## Troubleshooting

Start with the built-in diagnostic:

```bash
~/.local/bin/omarchy-matugen-sync --diagnose
```

It checks commands, config files, the template, output directory, wallpaper state, watcher unit, and light/dark mode consistency. It confirms that the pipeline is configured, but it does not perform a render.

To test a render, change the wallpaper and inspect the service:

```bash
systemctl --user status omarchy-matugen.path
journalctl --user -u omarchy-matugen.service
~/.local/bin/omarchy-matugen-sync
```

The sync command exits quietly when:

- `matugen-auto` is not the active theme;
- no wallpaper is set; or
- the wallpaper has not changed since the previous run.

Wallpaper changes are detected from the file path, size, and nanosecond modification time. If colors do not update, `--diagnose` reports which guard stopped the sync.

## Uninstall

```bash
./uninstall.sh
omarchy theme set tokyo-night   # or another theme
```

The uninstaller always removes project-owned executables and systemd units. It removes the matugen config and template only when they have not been modified. Any retained files are listed.

The settings file and `~/.config/omarchy/themes/matugen-auto` are kept, including your backgrounds. Delete them manually if you want a complete cleanup.

## License

MIT
