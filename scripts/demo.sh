#!/usr/bin/env bash
# Create or reset a disposable "omason-demo" profile with pending changes on
# both sides: a conflict, edits, a deletion, new files and a new folder.
#
#   scripts/demo.sh           reset the demo
#   scripts/demo.sh --big     also add a 1 GB file, to watch sync progress
#   scripts/demo.sh --remove  delete the demo folders, profile and archives
#
# Only touches $XDG_CACHE_HOME/omason-demo and the omason-demo profile.
set -euo pipefail

demo=${XDG_CACHE_HOME:-$HOME/.cache}/omason-demo
profiles=${UNISON:-$HOME/.unison}
profile=$profiles/omason-demo.prf
left=$demo/Documents
right=$demo/Backup

archives() {
  # Unison archives embed their roots; select only the demo's, plus the
  # fingerprint cache that shares each archive's hash.
  local archive
  for archive in $(grep -l --binary-files=text -F -- "$demo/" "$profiles"/ar* 2>/dev/null); do
    echo "$archive"
    [[ -e ${archive/\/ar/\/fp} ]] && echo "${archive/\/ar/\/fp}"
  done
  return 0
}

if [[ ${1:-} == --remove ]]; then
  mapfile -t files < <(archives)
  rm -rf -- "$demo"
  rm -f -- "$profile" "${files[@]}"
  echo "Removed $demo, $profile and ${#files[@]} archive file(s)."
  exit 0
fi

command -v unison >/dev/null || { echo "unison is not installed" >&2; exit 1; }
[[ -L $demo ]] && { echo "$demo is a symlink; refusing to reset it" >&2; exit 1; }

rm -rf -- "$demo"
mkdir -p -- "$left"/{notes,invoices,photos/2026} "$right" "$profiles"
echo "todo v1" > "$left/notes/todo.md"
echo "plan" > "$left/notes/plan.md"
echo "cv" > "$left/cv-2026.pdf"
echo "old" > "$left/old-draft.txt"
head -c 48000 /dev/urandom > "$left/invoices/october.pdf"
head -c 2100000 /dev/urandom > "$left/photos/2026/lisbon.jpg"
cp -a -- "$left/." "$right/"
printf '# omaSon demo profile (safe to delete: scripts/demo.sh --remove)\nroot = %s\nroot = %s\n' "$left" "$right" > "$profile"

# Baseline: both sides identical, so this only records Unison's archive.
unison omason-demo -batch -ui text -terse >/dev/null 2>&1 || { echo "baseline sync failed" >&2; exit 1; }

# Pending changes.
echo "todo v2 laptop" > "$left/notes/todo.md"
echo "todo v2 drive" > "$right/notes/todo.md"
echo "plan updated" > "$left/notes/plan.md"
echo "cv edited on drive" > "$right/cv-2026.pdf"
rm -- "$left/old-draft.txt"
mkdir -p -- "$left/recipes" && echo "pasta" > "$left/recipes/carbonara.md"
head -c 830000 /dev/urandom > "$left/photos/2026/porto.jpg"
head -c 52000 /dev/urandom > "$right/invoices/november.pdf"
if [[ ${1:-} == --big ]]; then
  mkdir -p -- "$left/videos"
  head -c 1G /dev/urandom > "$left/videos/trip.mp4"
fi
echo "Demo ready: $left <-> $right"
