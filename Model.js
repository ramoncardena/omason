.pragma library

// Pure helpers for the panel: glyphs, direction classification, grouping and
// formatting. Nothing here talks to the helper process.

function g(codePoint) { return String.fromCodePoint(codePoint) }

var glyph = {
  sync: g(0xF04E6),
  right: g(0xF0054),
  left: g(0xF004D),
  conflict: g(0xF0026),
  held: g(0xF03E4),
  merge: g(0xF062D),
  error: g(0xF015A),
  check: g(0xF012C),
  added: g(0xF0415),
  changed: g(0xF03EB),
  deleted: g(0xF01B4),
  props: g(0xF0493),
  folder: g(0xF024B),
  file: g(0xF0214),
  link: g(0xF0337),
  local: g(0xF0322),
  removable: g(0xF02CA),
  ssh: g(0xF048B),
  socket: g(0xF06F3),
  stop: g(0xF04DB),
  rescan: g(0xF0450),
  close: g(0xF0156),
  back: g(0xF004D),
  swap: g(0xF04E1)
}

// Unison arrows: "---->" recommended, "====>" chosen by the user, "?" held
// (conflicts recommend "<-?->"; a user skip is "<=?=>"), "M" merge.
function direction(arrow) {
  arrow = String(arrow || "")
  if (arrow === "error") return "error"
  if (arrow.indexOf("M") >= 0) return "merge"
  if (arrow.indexOf("?") >= 0) return "held"
  if (arrow.charAt(arrow.length - 1) === ">") return "right"
  if (arrow.charAt(0) === "<") return "left"
  return "held"
}

function directionGlyph(arrow) {
  var d = direction(arrow)
  if (d === "held") return unresolved({ arrow: arrow }) ? glyph.conflict : glyph.held
  return glyph[d]
}

// Still waiting for a decision: an untouched conflict or any merge.
function unresolved(item) {
  var arrow = String(item.arrow || "")
  return arrow.indexOf("-?-") >= 0 || arrow.indexOf("M") >= 0
}

function overridden(item) {
  return !!item.recommended && item.recommended !== item.arrow
}

function category(item) {
  var d = direction(item.recommended || item.arrow)
  return d === "right" || d === "left" ? d : "attention"
}

function counts(items) {
  var result = { toRight: 0, toLeft: 0, held: 0, unresolved: 0, merges: 0, errors: 0, done: 0, total: 0 }
  for (var i = 0; i < (items || []).length; i++) {
    var item = items[i]
    var d = direction(item.arrow)
    result.total++
    if (item.done) result.done++
    if (d === "right") result.toRight++
    else if (d === "left") result.toLeft++
    else if (d === "error") result.errors++
    else result.held++
    if (d === "merge") result.merges++
    if (unresolved(item)) result.unresolved++
  }
  return result
}

// Flat entries for one Repeater: section headers interleaved with rows. Rows
// keep Unison's order and stay in the section of their *recommendation*, so a
// row never jumps away from the cursor when its direction changes.
function sections(items, leftName, rightName) {
  var groups = [
    { key: "attention", title: "NEEDS A DECISION", rows: [] },
    { key: "right", title: (leftName + "  " + glyph.right + "  " + rightName).toUpperCase(), rows: [] },
    { key: "left", title: (rightName + "  " + glyph.right + "  " + leftName).toUpperCase(), rows: [] }
  ]
  var byKey = { attention: groups[0], right: groups[1], left: groups[2] }
  for (var i = 0; i < (items || []).length; i++) byKey[category(items[i])].rows.push(items[i])
  var entries = [], rows = [], rowEntry = []
  for (var s = 0; s < groups.length; s++) {
    var group = groups[s]
    if (!group.rows.length) continue
    var pending = group.key === "attention" ? group.rows.filter(unresolved).length : 0
    entries.push({ header: true, title: group.title, count: group.rows.length, pending: pending, key: group.key })
    for (var r = 0; r < group.rows.length; r++) {
      rowEntry.push(entries.length)
      entries.push({ header: false, item: group.rows[r], index: rows.length })
      rows.push(group.rows[r])
    }
  }
  return { entries: entries, rows: rows, rowEntry: rowEntry }
}

function sideGlyph(state) {
  state = String(state || "")
  if (state.indexOf("new") === 0) return glyph.added
  if (state.indexOf("deleted") === 0) return glyph.deleted
  if (state.indexOf("changed") === 0) return glyph.changed
  if (state.indexOf("props") === 0) return glyph.props
  if (state === "error") return glyph.error
  return ""
}

function kindGlyph(item) {
  var states = String(item.left || "") + " " + String(item.right || "")
  if (states.indexOf("dir") >= 0) return glyph.folder
  if (states.indexOf("link") >= 0) return glyph.link
  return glyph.file
}

function splitPath(path) {
  path = String(path || "")
  var cut = path.lastIndexOf("/")
  return cut < 0 ? { dir: "", name: path } : { dir: path.slice(0, cut + 1), name: path.slice(cut + 1) }
}

function formatSize(bytes) {
  if (bytes === null || bytes === undefined) return ""
  var units = ["B", "KB", "MB", "GB", "TB"]
  var value = bytes, unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
  return (unit === 0 ? value : value.toFixed(value < 10 ? 1 : 0)) + " " + units[unit]
}

function sideText(info, fallback) {
  if (!info) return fallback || ""
  var parts = [info.state]
  if (info.size !== null && info.size !== undefined && info.state !== "deleted") parts.push(formatSize(info.size))
  if (info.modified) parts.push(info.modified.slice(0, 16))
  return parts.join(" · ")
}

function relativeTime(epochSeconds, nowMs) {
  if (!epochSeconds) return "never"
  var seconds = Math.max(0, Math.round(nowMs / 1000 - epochSeconds))
  if (seconds < 60) return "just now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m ago"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h ago"
  if (seconds < 172800) return "yesterday"
  if (seconds < 604800) return Math.floor(seconds / 86400) + "d ago"
  return Qt.formatDate(new Date(epochSeconds * 1000), "dd MMM")
}

function replicaOf(profile, index) {
  var replicas = profile && profile.replicas ? profile.replicas : []
  return replicas[index] || { kind: "local", name: index ? "Right" : "Left", path: "", online: null, missing: true }
}

function replicaGlyph(replica) { return glyph[replica && replica.kind] || glyph.local }

function replicaWhere(replica) {
  if (!replica || replica.missing) return "Set in include files"
  if (replica.online === false) return "Not connected"
  if (replica.kind === "ssh") return "SSH host"
  if (replica.kind === "socket") return "Socket server"
  if (replica.kind === "removable") return "Drive"
  return replica.host ? "On " + replica.host : "This computer"
}

function routeText(profile) {
  if (!profile || !profile.replicas || profile.replicas.length < 2) return "Roots are set in include files"
  var left = profile.replicas[0], right = profile.replicas[1]
  function place(r) { return r.kind === "local" ? r.path : r.name + ":" + r.path }
  return place(left) + "  " + glyph.swap + "  " + place(right)
}

// Profiles that share the same two roots (e.g. one per folder via `path =`)
// are listed together under one replica-pair header.
function profileGroups(profiles) {
  var groups = [], byKey = {}
  for (var i = 0; i < (profiles || []).length; i++) {
    var p = profiles[i]
    var key = (p.roots || []).join("\n")
    if (!byKey[key]) {
      byKey[key] = { left: replicaOf(p, 0), right: replicaOf(p, 1), offline: offlineReplica(p), profiles: [] }
      groups.push(byKey[key])
    }
    byKey[key].profiles.push(p)
  }
  var entries = [], rows = []
  for (var g = 0; g < groups.length; g++) {
    var members = groups[g].profiles
    var prefix = sharedPrefix(members.map(function(p) { return p.label }))
    entries.push({ header: true, group: groups[g] })
    for (var r = 0; r < members.length; r++) {
      entries.push({ header: false, profile: members[r], index: rows.length, name: members[r].label.slice(prefix.length) })
      rows.push(members[r])
    }
  }
  return { entries: entries, rows: rows }
}

// "gator-" in gator-backups, gator-desktop…: only cut at a separator, and only
// when at least two profiles share it and something is left of every name.
function sharedPrefix(labels) {
  if (labels.length < 2) return ""
  var prefix = labels[0]
  for (var i = 1; i < labels.length; i++)
    while (labels[i].indexOf(prefix) !== 0) prefix = prefix.slice(0, -1)
  var cut = Math.max(prefix.lastIndexOf("-"), prefix.lastIndexOf("_"), prefix.lastIndexOf(" "), prefix.lastIndexOf("."))
  prefix = cut >= 0 ? prefix.slice(0, cut + 1) : ""
  return labels.every(function(l) { return l.length > prefix.length }) ? prefix : ""
}

// Runs worth remembering: anything that synced or failed. Scans that found
// nothing and reviews that were cancelled are left out, and repeats merge.
function recentRuns(history, limit) {
  var result = []
  for (var i = 0; i < (history || []).length && result.length < limit; i++) {
    var run = history[i]
    if (!run.committed && run.phase !== "error" && run.phase !== "partial") continue
    var previous = result[result.length - 1]
    if (previous && previous.profile === run.profile && runSummary(previous) === runSummary(run)) continue
    result.push(run)
  }
  return result
}

// What the profile covers, minus anything its (shortened) name already says.
function profileScope(profile, name) {
  if (!profile) return ""
  var paths = (profile.paths || []).filter(function(p) { return p.toLowerCase() !== String(name || "").toLowerCase() })
  var parts = paths.length ? [paths.join(" · ")] : (profile.paths && profile.paths.length ? [] : ["Entire replica"])
  if (profile.ignores) parts.push(profile.ignores + (profile.ignores === 1 ? " ignore rule" : " ignore rules"))
  return parts.join("  ·  ")
}

function profileCoverage(profile) {
  if (!profile) return ""
  return profile.paths && profile.paths.length ? profile.paths.join(", ") : "Entire replica"
}

// Second line of a picker option; the search matches it too ("ssd", "desktop").
function profileDescription(profile, nowMs) {
  var left = replicaOf(profile, 0), right = replicaOf(profile, 1)
  var parts = [left.name + " " + glyph.swap + " " + right.name]
  if (profile.paths && profile.paths.length) parts.push(profile.paths.join(", "))
  var offline = offlineReplica(profile)
  if (offline) parts.push(offline.name + " not connected")
  else parts.push(profile.last ? "last run " + relativeTime(profile.last.finished, nowMs) : "never synced")
  return parts.join(" · ")
}

function offlineReplica(profile) {
  var replicas = profile && profile.replicas ? profile.replicas : []
  for (var i = 0; i < replicas.length; i++) if (replicas[i].online === false) return replicas[i]
  return null
}

function statusGlyph(phase) {
  if (phase === "complete") return glyph.check
  if (phase === "partial") return glyph.conflict
  if (phase === "error") return glyph.error
  if (phase === "cancelled") return glyph.stop
  return ""
}

function runSummary(record) {
  if (!record) return ""
  var result = record.result
  if (record.phase === "complete" && !record.committed) return "Already in sync"
  if (result && record.committed) {
    var text = "Synced " + result.transferred
    if (result.skipped) text += " · held " + result.skipped
    if (result.failed) text += " · failed " + result.failed
    return text
  }
  if (record.phase === "cancelled") return record.committed ? "Stopped during sync" : "Review cancelled"
  if (record.phase === "error") return "Failed"
  if (record.phase === "partial") return "Partly synced"
  return record.message || ""
}

// Unison's `d` output: the echoed key, a `diff -u` command and headers with
// long paths, the hunks, then "Exited with status N". Parse the hunks with
// line numbers; anything else (e.g. "Binary files … differ") stays as text.
var DIFF_LINE_LIMIT = 3000

function parseDiff(text) {
  var all = String(text || "").split("\n")
  // Which file is "-" and which is "+" varies with the change, so read the headers.
  var oldPath = "", newPath = "", start = -1
  for (var h = 0; h < all.length; h++) {
    if (all[h].indexOf("--- ") === 0 && !oldPath) oldPath = all[h].slice(4).split("\t")[0]
    else if (all[h].indexOf("+++ ") === 0 && !newPath) newPath = all[h].slice(4).split("\t")[0]
    else if (all[h].indexOf("@@") === 0) { start = h; break }
  }
  var result = { unified: start >= 0, binary: false, oldPath: oldPath, newPath: newPath,
                 added: 0, removed: 0, hunks: [], lineCount: 0, truncated: false, message: "" }
  if (start < 0) {
    var rest = all.filter(function(l, n) { return !(n === 0 && l.trim().length <= 1) && l.indexOf("Exited with status") !== 0 })
    result.message = rest.join("\n").trim()
    result.binary = /^Binary files .* differ$/m.test(result.message)
    return result
  }
  var hunk = null, oldNo = 0, newNo = 0
  for (var j = start; j < all.length; j++) {
    var line = all[j]
    if (line.indexOf("Exited with status") === 0) break
    var header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$/.exec(line)
    if (header) {
      oldNo = +header[1]; newNo = +header[3]
      hunk = { oldStart: oldNo, newStart: newNo, newCount: header[4] === undefined ? 1 : +header[4], context: header[5], lines: [] }
      result.hunks.push(hunk)
      continue
    }
    if (!hunk) continue
    if (result.lineCount >= DIFF_LINE_LIMIT) { result.truncated = true; break }
    var kind = line.charAt(0) === "+" ? "add" : (line.charAt(0) === "-" ? "remove" : (line.charAt(0) === "\\" ? "meta" : "context"))
    var entry = { kind: kind, text: kind === "meta" ? line : line.slice(1), number: 0 }
    if (kind === "add") { entry.number = newNo++; result.added++ }
    else if (kind === "remove") { entry.number = oldNo++; result.removed++ }
    else if (kind === "context") { entry.number = newNo; oldNo++; newNo++ }
    hunk.lines.push(entry)
    result.lineCount++
  }
  // Trailing blank context left by the "Exited with status" separator.
  var last = result.hunks.length ? result.hunks[result.hunks.length - 1].lines : []
  while (last.length && last[last.length - 1].kind === "context" && !last[last.length - 1].text.trim()) { last.pop(); result.lineCount-- }
  return result
}

// The first few lines of a diff for the row: whole hunks while they fit.
function diffPreview(diff, maxLines) {
  var lines = []
  for (var i = 0; i < diff.hunks.length && lines.length < maxLines; i++) {
    lines.push({ kind: "hunk", text: hunkLabel(diff.hunks[i]), number: 0 })
    var body = diff.hunks[i].lines
    for (var j = 0; j < body.length && lines.length < maxLines; j++) lines.push(body[j])
  }
  return lines
}

function hunkLabel(hunk) {
  var end = hunk.newStart + Math.max(0, hunk.newCount - 1)
  var range = hunk.newCount > 1 ? "Lines " + hunk.newStart + "–" + end : "Line " + hunk.newStart
  return hunk.context ? range + " · " + hunk.context.trim() : range
}

function diffStat(diff) {
  var changes = diff.hunks.length + (diff.hunks.length === 1 ? " change" : " changes")
  return "+" + diff.added + " −" + diff.removed + " · " + changes
}

// Name the replica a diff header path belongs to, e.g. "+ Backup  − Documents".
function diffLegend(diff, left, right) {
  function side(path) {
    if (left && left.root && path.indexOf(left.root) === 0) return left.name
    if (right && right.root && path.indexOf(right.root) === 0) return right.name
    return ""
  }
  var plus = side(diff.newPath), minus = side(diff.oldPath)
  if (!plus && minus) plus = minus === left.name ? right.name : left.name
  if (!minus && plus) minus = plus === left.name ? right.name : left.name
  return plus ? "+ " + plus + "    − " + minus : ""
}

// Unison's text UI output, minus the progress meter it redraws in place
// ("  53%  1/4  (7 B of 9 B)  --:-- ETA"), which otherwise floods the log.
function cleanLog(text) {
  return String(text || "")
    .replace(/ *\d+%\s+\d+\/\d+\s+\([^)]*\)[^\n\r\[]*?ETA */g, "\n")
    .replace(/\r/g, "\n")
    .split("\n").map(function(l) { return l.replace(/\s+$/, "") }).join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
}

// Client-side preview of a root the user is typing into the new-profile form.
function classify(root) {
  root = String(root || "").trim()
  var remote = /^(ssh|socket):\/\/([^/]*)\/?(.*)$/.exec(root)
  if (remote) {
    var host = remote[2].split("@").pop().split(":")[0]
    var path = remote[3].charAt(0) === "/" ? remote[3] : (remote[3] ? "~/" + remote[3] : "~")
    return { kind: remote[1], name: host || "host", path: path }
  }
  var media = /^\/run\/media\/[^/]+\/([^/]+)(\/.*)?$/.exec(root) || /^\/(?:media|mnt)\/([^/]+)(\/.*)?$/.exec(root)
  if (media) return { kind: "removable", name: media[1], path: media[2] || "/" }
  var name = root.replace(/\/+$/, "").split("/").pop()
  return { kind: "local", name: name || "Folder", path: root || "/path/to/folder" }
}
