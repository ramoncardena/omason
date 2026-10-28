import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
    id: root
    moduleName: "io.github.ramoncardena.omason"

    property var profiles: []
    property var history: []
    property bool available: true
    property string selectedProfile: ""
    property string profileDirectory: "~/.unison"
    property string stateDirectory: ""
    property string errorMessage: ""
    property var checks: ({})
    property var profileDoc: null
    property var prefs: []
    property var prefsByName: ({})
    property string notice: ""
    property string pickField: ""
    property var session: ({ phase: "idle", items: [], current: "", profile: "", message: "Choose a profile to review changes.", details: "", detailsPath: "", tail: "", run: "", totals: {}, progress: null, pending: 0, syncRequested: false })
    // Keep phase as its own string: QML bindings on fields of a replaced `var`
    // object are easy to miss; this drives the bar icon reliably.
    property string phase: "idle"
    property bool hasUnresolved: false
    readonly property bool busy: ["scanning", "review", "ready", "warning", "syncing", "cancelling"].indexOf(phase) >= 0
    readonly property bool working: phase === "scanning" || phase === "syncing" || phase === "cancelling"
    // Lit after a scan (or a finished sync that needs a look) so the bar shows
    // that something is waiting, not only when there are conflicts.
    readonly property bool needsAttention: phase === "warning" || phase === "error"
        || phase === "review" || phase === "ready" || phase === "partial"
    readonly property bool attentionUrgent: phase === "error" || phase === "warning" || phase === "partial" || hasUnresolved
    readonly property string statusGlyph: {
        if (root.working) return Model.glyph.sync
        if (phase === "error") return Model.glyph.error
        if (root.attentionUrgent) return Model.glyph.conflict
        if (phase === "review" || phase === "ready") return Model.glyph.check
        return Model.glyph.sync
    }
    readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omason")).replace(/^file:\/\//, ""))

    function applySession(data) {
        const beforeWorking = root.working
        session = data
        phase = data.phase || "idle"
        hasUnresolved = !!(data.items && data.items.some(Model.unresolved))
        if (beforeWorking && !root.working && root.needsAttention) attentionPulse.restart()
    }

    function request(command, args) {
        if (!backend.running) {
            errorMessage = "omaSon’s helper is unavailable. Reload the plugin to reconnect."
            return
        }
        if (command !== "catalog") errorMessage = ""
        var payload = args || {}
        payload.command = command
        backend.write(JSON.stringify(payload) + "\n")
    }

    function receive(line) {
        try {
            const data = JSON.parse(line)
            if (data.type === "catalog") {
                profiles = data.profiles
                history = data.history
                available = data.available
                profileDirectory = data.profileDirectory
                stateDirectory = data.stateDirectory
                if (!profiles.some(function(p) { return p.name === root.selectedProfile })) {
                    // Start on the most recently used profile that still exists.
                    const recent = history.find(function(r) { return profiles.some(function(p) { return p.name === r.profile }) })
                    selectedProfile = recent ? recent.profile : (profiles.length ? profiles[0].name : "")
                }
            } else if (data.type === "state") {
                const before = root.phase
                root.applySession(data)
                if (["scanning", "syncing", "cancelling", "review", "ready", "warning"].indexOf(before) >= 0) notifyIfClosed(data)
            } else if (data.type === "profile") {
                profileDoc = data
            } else if (data.type === "prefs") {
                const byName = {}
                for (const p of data.prefs) byName[p.name] = p
                prefsByName = byName
                prefs = data.prefs
            } else if (data.type === "saved") {
                notice = "Saved " + data.profile + "." + (data.note ? " " + data.note : "") + " The previous version was kept in omaSon's state folder."
                if (panelLoader.item) panelLoader.item.closeEdit()
            } else if (data.type === "renamed") {
                selectedProfile = data.newName
                notice = "Renamed " + data.profile + " to " + data.newName + "."
                if (panelLoader.item) panelLoader.item.closeEdit()
            } else if (data.type === "deleted") {
                if (selectedProfile === data.profile) selectedProfile = ""
                notice = "Deleted " + data.profile + ". A copy is kept in omaSon's state folder (deleted-profiles)."
                if (panelLoader.item) panelLoader.item.closeEdit()
            } else if (data.type === "check") {
                checks = data.results
            } else if (data.type === "created") {
                selectedProfile = data.profile
                notice = "Created " + data.profile + "." + (data.note ? " " + data.note : "")
                if (panelLoader.item) panelLoader.item.creating = false
            } else if (data.type === "error") {
                errorMessage = data.error
            }
        } catch (e) {
            errorMessage = "Could not read helper response: " + String(e)
        }
    }

    // Exit 75: this instance was a client and the shared helper went away — restart
    // so another monitor (or this one) can become the server. Other exits: show the
    // error, then retry so a crashed helper does not leave the bar dead.
    Timer {
        id: helperRestart
        interval: 400
        onTriggered: if (!backend.running) backend.running = true
    }
    Process {
        id: backend
        command: ["python3", root.helperPath, "serve"]
        stdinEnabled: true
        running: true
        stdout: SplitParser { onRead: function(line) { root.receive(line) } }
        stderr: StdioCollector { id: diagnostics; waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode === 75) {
                helperRestart.restart()
                return
            }
            root.errorMessage = "omaSon helper stopped (" + exitCode + "). " + diagnostics.text.slice(-1000)
            helperRestart.restart()
        }
    }

    // Folder chooser for the new-profile form; see Panel.browse().
    function browse(field, start, title) {
        if (picker.running) return
        pickField = field
        close()
        picker.command = ["python3", root.helperPath, "pick", title, start]
        picker.running = true
    }

    Process {
        id: picker
        stdout: StdioCollector { id: picked; waitForEnd: true }
        stderr: StdioCollector { id: pickErrors; waitForEnd: true }
        onExited: function(exitCode) {
            root.open()
            const path = picked.text.trim()
            const problem = pickErrors.text.trim()
            if (exitCode !== 0 && problem) root.errorMessage = "The folder chooser is unavailable: " + problem.split("\n").pop()
            else if (path && panelLoader.item) panelLoader.item.applyPick(root.pickField, path)
        }
    }

    Timer {
        interval: 30000
        running: backend.running
        repeat: true
        onTriggered: root.request("catalog")
    }

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
    function open() { if (panelLoader.item) { request("catalog"); panelLoader.item.open() } }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function toggle() { if (opened) close(); else open() }
    function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        target.bar = root.bar
        target.settings = root.settings
        target.anchorItem = button
        target.hostWidget = root
    }
    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    Loader {
        id: panelLoader
        active: true
        visible: false
        source: Qt.resolvedUrl("Panel.qml")
        onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
    }

    IpcHandler {
        target: root.moduleName
        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.toggle() }
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // Only the instance that ran the session sees it finish, so this fires once
    // even with one widget per monitor. Clicking the notification opens the panel.
    function notifyIfClosed(s) {
        if (opened || ["complete", "partial", "error"].indexOf(s.phase) < 0) return
        const result = s.result
        let title = "omaSon · " + s.profile
        let body = s.message
        let urgency = "normal"
        let glyph = Model.glyph.check
        if (s.phase === "error") { urgency = "critical"; glyph = Model.glyph.error; title += (result ? " · sync incomplete" : " · Unison could not finish") }
        else if (s.phase === "partial") glyph = Model.glyph.conflict
        else if (!s.items.length) body = "Already in sync."
        Util.execArgv(["omarchy-notification-send", "--app-name", "omaSon", "-g", glyph, "-u", urgency, title, body,
                       "--exec", "omarchy-shell", "shell", "summon", root.moduleName, "{}"])
    }

    function statusText() {
        const s = root.session
        const where = s.profile ? " · " + s.profile : ""
        if (root.phase === "scanning") return "omaSon · scanning" + where
        if (root.phase === "warning") return "omaSon · needs confirmation" + where
        if (root.phase === "review" || root.phase === "ready") return "omaSon · " + (s.items ? s.items.length : 0) + " changes to review" + where
        if (root.phase === "syncing") return "omaSon · syncing" + where + (s.progress ? " · " + s.progress.percent + "%" : "")
        if (root.phase === "error") return "omaSon · last session failed" + where
        if (root.phase === "partial") return "omaSon · partly synced" + where
        return "omaSon · Unison"
    }

    // Flash the icon when a scan/sync finishes so a glance at the bar catches it.
    SequentialAnimation {
        id: attentionPulse
        loops: 4
        NumberAnimation { target: button; property: "opacity"; to: 0.25; duration: 160 }
        NumberAnimation { target: button; property: "opacity"; to: 1.0; duration: 160 }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.statusGlyph
        active: root.needsAttention
        // Accent for "ready to review"; urgent only when something is wrong.
        activeColor: root.attentionUrgent ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
        tooltipText: root.statusText()
        onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.toggle() }
        NumberAnimation on textRotation {
            running: root.working
            from: 0; to: -360; duration: 1600; loops: Animation.Infinite
            onRunningChanged: if (!running) button.textRotation = 0
        }
    }
}
