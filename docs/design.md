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

The skill's freshness check detected Quickshell 0.3.2 and changes to
`Ui/Panel.qml` and `Ui/KeyboardPanel.qml` relative to the 2026-10-16 notes.
The current files, shell README, and official development/publishing guides
were read before implementation. The panel still uses the same host/owner
injection and lifecycle contract. The external skill files were not modified;
this workspace permits writes only to the project and temporary directories.

## Live desktop acceptance

On 2026-10-26, the plugin files were copied into the user plugin directory,
validated there, and enabled by adding one entry to the watched `shell.json`
bar layout. A timestamped backup of the original layout was retained beside
that file. The running Quickshell instance loaded the plugin, and the helper
created its state directory. No omaSon QML loading errors appeared in the
shell log. The only omaSon warning was the shell's usual external plugin
module-path warning.

IPC calls to both Quickshell and Hyprland fail with `EPERM` inside this
development sandbox. `omarchy-shell` hides the underlying socket failure
behind its generic "not running" message; instance metadata confirms the
shell is running. Consequently popup opening, synthetic input, screenshots,
and the following interaction checks remain pending:

- Open via click and `shell summon`; close via click and Escape; switch via Tab.
- Create a profile using throwaway folders, scan, inspect diff/details, choose
  directions, edit a choice from the summary, and sync.
- Verify the profile picker, form field focus, keyboard shortcuts, scrolling,
  long paths, narrow screens, and the current theme.
- Start a session on one monitor and verify the second monitor reports the
  busy lock rather than starting another session.
- Close/reopen during scan/review/transfer; verify state persists. Disable the
  plugin during a disposable session and verify Unison stops gracefully.
- Exercise an SSH profile with an existing loaded key and known host, then
  test an unavailable host and confirm the error is visible.
- Check logs for QML errors. Restart the shell only after hot reload settles;
  panel files can remain cached across hot reloads.
- Verify actual output with a populated real profile before using it for
  important transfers. Scheduling, watchers, interactive merges, and full
  profile preference editing remain future work.
