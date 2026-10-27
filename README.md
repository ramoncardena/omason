# omaSon

A Unison front end for the Omarchy bar. Review pending changes, choose which
replica wins, synchronize, and inspect local session history without opening
Unison's GTK interface.

**Status:** initial implementation. The helper is integration-tested against
Unison 2.54.0. The QML passes static validation against Omarchy 4.0.0.alpha /
Quickshell 0.3.2. The plugin has been installed and enabled in the live shell;
the widget and helper loaded without omaSon errors. Opening the popup, visual
interaction, and SSH synchronization still need desktop validation because
the development sandbox denies access to desktop control sockets.

## Install

Requires Omarchy's Quickshell shell, Python 3, and `unison`. The shell's SSH
agent must have any required keys loaded. Remote hosts must already be present
in `known_hosts` and run a compatible Unison version.

From this checkout:

```bash
./scripts/install.sh
```

The installer copies the plugin into
`~/.config/omarchy/plugins/io.github.ramoncardena.omason/`, rescans the registry,
and enables it on the right of the bar. It refuses to overwrite a different
installation; rerunning with identical files retries activation. If IPC access
is denied, it reports that copying succeeded and prints the activation commands
to run in a desktop terminal. No sync starts during installation or when the
panel opens.

Open it with the bar icon or:

```bash
omarchy-shell shell summon io.github.ramoncardena.omason '{}'
```

## Use

1. The **profile picker** holds every `~/.unison/*.prf` (or the `UNISON`
   directory inherited by the shell). Press `P` to search it by name, replica
   or folder, or `←`/`→` to step through profiles. The panel opens on the
   profile you used last. The selected profile shows its two replicas, what
   it covers, its last run and its recent runs. A replica on an unplugged
   drive is flagged and scanning waits until it is connected. **New profile** (or `N`) pairs two existing local folders, or a
   local folder and an SSH root such as `ssh://user@host//absolute/path`, with
   a live preview of both sides. New profiles enable Unison backups and keep
   five versions. Existing profile preferences are preserved.
2. Scanning launches Unison's text interface. Its first-run and whole-replica
   deletion warnings appear as a card that needs a separate confirmation.
3. The review screen shows the two replicas facing each other, with counts of
   what flows each way (and the bytes, once Unison has totalled them).
   Changes are grouped as **Needs a decision** (conflicts, merges, errors),
   **left → right** and **right → left**. Each row shows what happened on each
   side and a direction pill between them. Press `←`/`→` (or `h`/`l`) to send
   a change that way, `X` to hold it, and `U` to restore Unison's suggestion.
   Clicking the pill cycles through the three. A direction can propagate a
   deletion as well as copy a file. Enter expands a row to show both sides'
   size and date and a direction picker. `D` (or **Diff**) shows and hides
   a short preview of Unison's diff: how many lines were added and removed,
   which replica is which, and the first lines. **View full diff** (`F`)
   opens the whole diff in an overlay with line numbers, one section per
   change, and `N`/`P` to jump between changes. Binary files show their size
   on each side. **Show Unison output** (`V`) opens the raw output in a
   scrollable overlay, with a button to open the full log file.
4. **Sync N changes** (or `G`) applies exactly the directions shown. Held
   changes and untouched conflicts are left alone on both sides. Recommended
   merges must be given a direction or held first, because interactive merge
   tools are not supported. Rows are ticked off as Unison finishes each one.
5. **Recent** shows the latest sessions. Open one to see its planned file
   actions, result, and log location. Actual transfer outcomes are in Unison's
   log; the file list is a record of the plan, not a claim that every item
   succeeded.

Closing the popup keeps its session alive. **Cancel** ends a review; nothing
has been copied at that point. **Stop sync** (shown only while files are being
transferred) asks Unison to stop gracefully and waits for its archives to be
released. Completed transfers remain applied if a sync is stopped. Disabling the plugin closes its helper input and
also requests a graceful stop. Another monitor's instance cannot start a second
omaSon session while a review or sync holds the global lock.

The left and right cards follow the profile's root order, which is also
Unison's left/right order. Profiles using includes may obtain their roots from
other files. Advanced profile preferences and include files are managed in the
`.prf` files; the plugin provides a basic profile creator, not a full
preference editor.

| Key | Action |
| --- | --- |
| P | Search profiles |
| ← → / H L (main screen) | Previous / next profile |
| ↑ ↓ / J K | Move between controls, changes, and the Sync button |
| Enter | Scan · expand a change · press the focused button |
| ← → / H L | Send the focused change to the left / right replica |
| X / U | Hold the change / restore Unison's suggestion |
| D / F | Show or hide the diff preview / open the full diff (N / P jump between changes) |
| G | Sync the shown directions |
| C / V | Cancel the review or stop the sync / show Unison's output |
| N / R | New profile / scan (again) |
| Backspace | Leave a finished session, record, or form |
| Escape / Tab | Close popup / switch Omarchy panel |

## Data and behavior

- Unison remains responsible for reconciliation, transfer, backups, archive
  locking, and detecting changes made during a review. The plugin never copies
  replica files itself or deletes archive locks.
- The helper holds the **same Unison process** from scan through confirmation.
  Direction changes on any row are queued and applied by navigating Unison's
  held list, so the order you edit rows in doesn't matter.
  It overrides `batch`, `auto`, `silent`, and `repeat` so profile settings cannot
  start transfers during review. No scheduled sync or background scanning is
  enabled in this version.
- SSH is noninteractive (`BatchMode`, existing host keys, 15-second connection
  timeout). Authentication failures appear in the output rather than opening
  an invisible password dialog. Other profile commands remain Unison's
  responsibility; only run profiles you trust.
- The adapter uses the English, uncolored, dumb-terminal text UI tested with
  Unison 2.54.0. Unknown prompts get no automatic response; an inactive scan
  times out after two minutes. Large scans that continue producing output can
  run longer. Text UI changes in future Unison releases may need adapter updates.
- Logs and JSON records are stored under `$XDG_STATE_HOME/omason/`, defaulting
  to `~/.local/state/omason/`, with user-only permissions. Each log is capped at
  approximately 8 MB; the UI shows its last 12,000 characters. History records
  contain paths and planned actions, not file contents; diffs can appear in logs.
  The newest 50 sessions are retained.
- No Omarchy inline settings are needed, so disabling and re-enabling the
  widget preserves Unison profiles and history.

To remove the widget:

```bash
omarchy plugin remove io.github.ramoncardena.omason --yes
```

Profiles, Unison archives/backups, and omaSon history are retained on removal.

## Development

```bash
./scripts/check.sh
```

`scripts/demo.sh` creates (or resets) a disposable `omason-demo` profile under
`~/.cache/omason-demo` with a conflict, edits (one with a long diff), a binary
change, a deletion, and new files on both sides. `--big` adds a 1 GB file to watch sync progress; `--remove`
deletes the demo folders, profile, and only the demo's Unison archives.

The integration suite runs real Unison against disposable directories. It never
reads or modifies the user's real profiles, replicas, or archives. The lint
script suppresses only the dynamic-property warnings also present in Omarchy's
built-in panels. Run without `--missing-property disable` to see those too.

The plugin follows the [Omarchy authoring contract](https://plugins.omarchy.org/develop.html).
The adapter behavior was checked against Unison's
[text UI source](https://github.com/bcpierce00/unison/blob/v2.54.0/src/uitext.ml).
See [the design notes](docs/design.md) for architecture and the remaining desktop
acceptance checks.
