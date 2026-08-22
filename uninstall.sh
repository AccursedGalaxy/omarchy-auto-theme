#!/bin/bash
# Remove omarchy-matugen. Leaves ~/.config/omarchy/themes/matugen-auto in place
# (delete it yourself if you also want the theme and its backgrounds gone).
set -uo pipefail

systemctl --user disable --now omarchy-matugen.path 2>/dev/null
rm -f "$HOME/.config/systemd/user/omarchy-matugen.path" \
      "$HOME/.config/systemd/user/omarchy-matugen.service"
systemctl --user daemon-reload

rm -f "$HOME/.local/bin/omarchy-matugen-sync" \
      "$HOME/.config/matugen/templates/omarchy-quattro-colors.toml" \
      "$HOME/.config/matugen/quattro.toml" \
      "$HOME/.local/state/omarchy/matugen-auto.last"

echo "omarchy-matugen removed. Switch themes with: omarchy theme set <name>"
