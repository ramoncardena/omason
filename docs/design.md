# Implementation and acceptance notes

`BarWidget.qml` owns one long-running Python helper and all session state. Its
panel can close and reopen without restarting a review. It implements the
shell's open/close/toggle/popout coordination contract and forwards `bar`,
`settings`, `anchorItem`, and `hostWidget` to the panel. `Panel.qml` uses the
installed `qs.Ui` components, theme typography, and keyboard panel.

`bin/omason` has no Python package dependencies. It launches Unison with an
argument vector and uses separate nonblocking stdout/stderr pipes. Its JSON
command protocol exposes only catalog, basic profile creation, scan, warning
acknowledgement, item selection/direction, details/diff, summary, sync, and stop.
There is no raw terminal-input API. A complete recognized final prompt is
required before the sync command can send `y`.

The panel uses three higher-level commands. `set` (path, direction) and
`inspect` (path) are queued and applied whenever Unison is back at a prompt:
the helper navigates the held list with `0`/`n` to the target item, then sends
`<`, `>`, `/`, `r` or `d`. The item's arrow is updated immediately so the panel
reflects the choice before Unison confirms it. `apply` drains the queue, sends
`s`, and confirms only once the recognized final prompt appears. Choices are
locked once `apply` is requested. Listing metadata (sizes, dates), byte totals
from stderr, and `[END]` propagation lines are parsed for display only.

On the first item, `l` obtains Unison's change list and returns to that item.
Direction choices use Unison's existing `<`, `>`, `/`, and `r` actions. Selecting
another path navigates the held reconciliation list rather than restarting
Unison. `s` opens the final summary. Purely skipped/conflicting sessions can end
without a final transfer prompt, which is reported as a partial session. Log
records intentionally separate planned file actions from run-level results.

A nonblocking `flock` serializes sessions across monitor instances. Unison's own
archive locks also protect against other Unison clients. The helper releases
its lock after the child exits and its output pipes drain. It sends SIGINT on
stop or helper shutdown so Unison can finish cleanup. It never force-kills an
active transfer or removes a lock file left by Unison.

## Desktop testing

The panel has been exercised in the live Omarchy shell (Omarchy 4.0.0.alpha,
Quickshell 0.3.2, Unison 2.54.0) with the demo profiles from
`scripts/demo.sh`, driven from the keyboard: opening and closing, scanning,
choosing directions, diffs, syncing (including a
1 GB file), failures from a read-only folder, a missing replica, the
notification, profile creation in both modes, editing, renaming and deleting.
Screenshots were taken with `grim` and cropped to the panel border.

Not yet tested on a desktop:

- SSH replicas against a real remote host.
- Choosing a folder in the portal folder chooser (the GTK dialog ignores
  synthetic input; opening and cancelling it were tested).
- Two monitors at once (the session lock is covered by the integration
  tests).
- Clicking the end-of-session notification to reopen the panel.
