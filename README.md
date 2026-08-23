# omarchy-auto-theme

Automatic wallpaper-based colors for [Omarchy](https://omarchy.org) 4.0 (Quattro).

![Switching wallpapers recolors the terminal and Neovim](assets/demo.gif)

Change your wallpaper and the rest of the desktop follows.
[matugen](https://githu.com/InioX/matugen) creates a Material You palette from the image.
The project passes that palette to Omarchy's theme engine, which updates the bar, notifications, lock screen, terminals, Neovim, btop, Claude Code, and other supported apps.

It works like pywal or wallust, but uses Omarchy's existing app integrations. It also leaves packaged Omarchy files untouched.

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
./install.sh
omarchy theme set matugen-auto
```

Press `SUPER + CTRL + SPACE` and choose a wallpaper. The colors will update automatically.

## Use your own wallpapers

The installer includes a few starter backgrounds. To use your own collection, link it to the theme's background directory:

```bash
ln -sfn ~/Pictures/Wallpapers ~/.config/omarchy/backgrounds/matugen-auto
omarchy theme set matugen-auto
```

The second command refreshes Omarchy's wallpaper list.

If the destination already exists as a regular directory, move it first. Otherwise, `ln` will place the symlink inside that directory instead of replacing it.

```bash
mv ~/.config/omarchy/backgrounds/matugen-auto ~/.config/omarchy/backgrounds/matugen-auto.bak
ln -s ~/Pictures/Wallpapers ~/.config/omarchy/backgrounds/matugen-auto
omarchy theme set matugen-auto
```

Omarchy takes a snapshot of available backgrounds when a theme is applied. If you add wallpapers later, run `omarchy theme set matugen-auto` again to show them in the switcher. Color generation always uses the current wallpaper.

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

## Configure palette generation

The generated color mapping is defined in:

```text
~/.config/matugen/templates/omarchy-quattro-colors.toml
```

To change the source-color preference or use light mode, create this file:

```text
~/.config/omarchy-auto-theme/settings
```

For example:

```sh
PREFER=darkness   # lightness, saturation, and other matugen preferences also work
MODE=light        # dark or light
```

Both the installer and the sync process read these settings. The file is sourced as Bash, so treat it as trusted code. `MODE` and `PREFER` are validated after loading.

For light mode, also change `mode = "dark"` to `mode = "light"` in the template. The `--diagnose` command reports when the two values disagree.

The installer never modifies the settings file, and the uninstaller keeps it.

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

## How does it compare?

### tema

[tema](https://github.com/bjarneo/tema) is an interactive theme generator. You choose a wallpaper and mode, then apply the result. It is a good fit for creating a theme once.

omarchy-auto-theme is a background pipeline. There is nothing to open after installation. A systemd path unit detects wallpaper changes and regenerates the active theme.

### pywal and wallust

[pywal](https://github.com/dylanaraps/pywal) and [wallust](https://codeberg.org/explosion-mental/wallust) provide general-purpose wallpaper colors. You usually need to connect each application yourself.

This project feeds Omarchy's own theme engine instead. Existing Omarchy integrations continue to work and remain maintained through Omarchy updates. It also uses matugen's Material You color generation rather than direct dominant-color extraction.

## Uninstall

```bash
./uninstall.sh
omarchy theme set tokyo-night   # or another theme
```

The uninstaller always removes project-owned executables and systemd units. It removes the matugen config and template only when they have not been modified. Any retained files are listed.

The settings file and `~/.config/omarchy/themes/matugen-auto` are kept, including your backgrounds. Delete them manually if you want a complete cleanup.

## License

MIT
