#!/usr/bin/env bash
# Create or reset a disposable "omason-demo" profile with pending changes on
# both sides: a conflict, edits (one with a long diff), a binary change, a
# deletion, new files and a new folder.
#
#   scripts/demo.sh           reset the demo
#   scripts/demo.sh --big     also add a 1 GB file, to watch sync progress
#   scripts/demo.sh --remove  delete the demo folders, profile and archives
#
# Also creates a second demo pair, Laptop <-> Drive, with one profile per
# folder (omason-demo-photos, omason-demo-music), like a setup that uses
# `path =` and `mountpoint =`, for the "Add a folder" form.
#
# Only touches $XDG_CACHE_HOME/omason-demo and the omason-demo* profiles.
set -euo pipefail

demo=${XDG_CACHE_HOME:-$HOME/.cache}/omason-demo
profiles=${UNISON:-$HOME/.unison}
profile=$profiles/omason-demo.prf
pair_profiles=("$profiles/omason-demo-photos.prf" "$profiles/omason-demo-music.prf")
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
  [[ -d $demo ]] && chmod -R u+rwX -- "$demo"
  rm -rf -- "$demo"
  rm -f -- "$profile" "${pair_profiles[@]}" "${files[@]}"
  echo "Removed $demo, the omason-demo profiles and ${#files[@]} archive file(s)."
  exit 0
fi

command -v unison >/dev/null || { echo "unison is not installed" >&2; exit 1; }
[[ -L $demo ]] && { echo "$demo is a symlink; refusing to reset it" >&2; exit 1; }

# Make leftovers writable first (a test may have synced read-only folders).
[[ -d $demo ]] && chmod -R u+rwX -- "$demo"
rm -rf -- "$demo"
mkdir -p -- "$left"/{notes,invoices,photos/2026} "$right" "$profiles"
echo "todo v1" > "$left/notes/todo.md"
echo "plan" > "$left/notes/plan.md"
echo "cv" > "$left/cv-2026.pdf"
echo "old" > "$left/old-draft.txt"
head -c 48000 /dev/urandom > "$left/invoices/october.pdf"
head -c 2100000 /dev/urandom > "$left/photos/2026/lisbon.jpg"
for day in $(seq 1 320); do echo "Day $day: walked by the river, read a chapter, wrote notes about topic $((day % 37))."; done > "$left/notes/journal.md"
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
# A long diff (edits, insertions and deletions spread through the file) and a binary change.
awk '{ if (NR % 23 == 0) print "Day " NR ": rewritten on the laptop, with a much longer entry than before."
       else if (NR % 41 == 0) next
       else print
       if (NR % 64 == 0) { print "  - extra note added after day " NR; print "  - and another one" } }' \
  "$left/notes/journal.md" > "$left/notes/journal.md.new" && mv -- "$left/notes/journal.md.new" "$left/notes/journal.md"
head -c 120000 /dev/urandom >> "$right/photos/2026/lisbon.jpg"
# More rows, to check spacing and scrolling (including a very long name).
printf '# Meeting 28 Oct\n- agenda\n- decisions\n' > "$left/notes/meeting-2026-10-28.md"
head -c 9000 /dev/urandom >> "$left/invoices/october.pdf"
head -c 61000 /dev/urandom > "$right/invoices/december.pdf"
head -c 640000 /dev/urandom > "$right/photos/2026/camera roll export from the drive - weekend in the mountains (edited).jpg"
printf 'milk\nbread\ncoffee\n' > "$right/notes/shopping-list.md"
if [[ ${1:-} == --big ]]; then
  mkdir -p -- "$left/videos"
  head -c 1G /dev/urandom > "$left/videos/trip.mp4"
fi
# The per-folder pair: same two roots, one profile per folder, guarded by mountpoint.
laptop=$demo/Laptop drive=$demo/Drive
mkdir -p -- "$laptop"/{Photos/2026,Music/Albums,Videos} "$drive"
for n in 1 2 3; do head -c 300000 /dev/urandom > "$laptop/Photos/2026/beach-$n.jpg"; done
head -c 900000 /dev/urandom > "$laptop/Music/Albums/track-01.flac"
cp -a -- "$laptop/Photos" "$laptop/Music" "$drive/"
for folder in Photos Music; do
  name=omason-demo-$(echo "$folder" | tr 'A-Z' 'a-z')
  printf '# omaSon demo profile (safe to delete: scripts/demo.sh --remove)\nroot = %s\nroot = %s\npath = %s\nmountpoint = %s\ntimes = true\nperms = 0\nlabel = %s from the laptop to the backup drive\n' \
    "$laptop" "$drive" "$folder" "$folder" "$folder" > "$profiles/$name.prf"
  unison "$name" -batch -ui text -terse >/dev/null 2>&1 || { echo "baseline sync of $name failed" >&2; exit 1; }
done
head -c 280000 /dev/urandom > "$laptop/Photos/2026/sunset.jpg"

echo "Demo ready: $left <-> $right, and $laptop <-> $drive"
