#!/usr/bin/env bash
# Copy the working tree into the Omarchy plugins dir (the shell rejects
# symlinks) and enable the widget. Prefer `omarchy plugin add` for normal use.

set -euo pipefail

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id=io.github.ramoncardena.omason
plugin_root="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
destination="$plugin_root/$plugin_id"

for tool in python3 unison omarchy-plugin-validate omarchy-shell omarchy-plugin-enable; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done

omarchy-plugin-validate "$source_dir"
mkdir -p -- "$plugin_root"

if [[ $source_dir == "$destination" ]]; then
  echo "Already running from the installed plugin directory."
else
  if [[ -e $destination || -L $destination ]]; then
    identical=true
    [[ ! -L $destination ]] || identical=false
    for file in manifest.json BarWidget.qml Panel.qml Model.js README.md LICENSE bin/omason; do
      if ! cmp -s -- "$source_dir/$file" "$destination/$file"; then
        identical=false
        break
      fi
    done
    if [[ $identical != true ]]; then
      echo "A different omaSon installation already exists at $destination." >&2
      echo "Stop any active sync and remove or move that folder before reinstalling." >&2
      exit 1
    fi
    echo "The same plugin files are already installed; retrying activation."
  else
    staging=$(mktemp -d "$plugin_root/.omason-dev.XXXXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    mkdir -p -- "$staging/bin"
    cp -- "$source_dir/manifest.json" "$source_dir/BarWidget.qml" "$source_dir/Panel.qml" "$source_dir/Model.js" "$source_dir/README.md" "$source_dir/LICENSE" "$staging/"
    cp -- "$source_dir/bin/omason" "$staging/bin/omason"
    chmod +x "$staging/bin/omason"
    omarchy-plugin-validate "$staging"
    mv -- "$staging" "$destination"
    trap - EXIT
  fi
fi

activation_failed() {
  echo "Plugin files are installed and validated at $destination." >&2
  echo "Could not activate through Omarchy IPC. The shell may be unavailable, or this process may be denied access to its socket." >&2
  echo "From a desktop terminal, run:" >&2
  echo "omarchy-shell shell rescanPlugins" >&2
  echo "omarchy-plugin-enable $plugin_id --section right" >&2
  exit 1
}

omarchy-shell shell rescanPlugins || activation_failed
omarchy-plugin-enable "$plugin_id" --section right || activation_failed
echo "Installed omaSon. Open it from the bar, or run:"
echo "omarchy-shell shell summon $plugin_id '{}'"
