#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
python3 -m unittest discover -s tests -v
omarchy-plugin-validate .

lint_root=$(mktemp -d /tmp/omason-lint.XXXXXXXX)
trap 'rm -rf -- "$lint_root"' EXIT
ln -s -- "${OMARCHY_PATH:-/usr/share/omarchy}/shell" "$lint_root/qs"
# Dynamic shell types (bar, Style.font, Loader.item) generate the same
# missing-property diagnostics as built-in plugins. Keep all other checks on.
/usr/lib/qt6/bin/qmllint --missing-property disable -I "$lint_root" BarWidget.qml Panel.qml
