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
    property var session: ({ phase: "idle", items: [], current: "", profile: "", message: "Choose a profile to review changes.", details: "", detailsPath: "", tail: "", run: "", totals: {}, progress: null, pending: 0, syncRequested: false })
    readonly property bool busy: ["scanning", "review", "ready", "warning", "syncing", "cancelling"].indexOf(session.phase) >= 0
    readonly property bool working: session.phase === "scanning" || session.phase === "syncing" || session.phase === "cancelling"
    readonly property bool needsAttention: session.phase === "warning" || session.phase === "error"
        || ((session.phase === "review" || session.phase === "ready") && session.items.some(Model.unresolved))
    readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("bin/omason")).replace(/^file:\/\//, ""))

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
                const before = session.phase
                session = data
                if (["scanning", "syncing", "cancelling", "review", "ready", "warning"].indexOf(before) >= 0) notifyIfClosed(data)
            } else if (data.type === "created") {
                selectedProfile = data.profile
                if (panelLoader.item) panelLoader.item.creating = false
            } else if (data.type === "error") {
                errorMessage = data.error
            }
        } catch (e) {
            errorMessage = "Could not read helper response: " + String(e)
        }
    }

    Process {
        id: backend
        command: ["python3", root.helperPath, "serve"]
        stdinEnabled: true
        running: true
        stdout: SplitParser { onRead: function(line) { root.receive(line) } }
        stderr: StdioCollector { id: diagnostics; waitForEnd: true }
        onExited: function(exitCode) {
            root.errorMessage = "omaSon helper stopped (" + exitCode + "). " + diagnostics.text.slice(-1000)
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
        if (s.phase === "scanning") return "omaSon · scanning" + where
        if (s.phase === "warning") return "omaSon · needs confirmation" + where
        if (s.phase === "review" || s.phase === "ready") return "omaSon · " + s.items.length + " changes to review" + where
        if (s.phase === "syncing") return "omaSon · syncing" + where + (s.progress ? " · " + s.progress.percent + "%" : "")
        if (s.phase === "error") return "omaSon · last session failed" + where
        return "omaSon · Unison"
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: Model.glyph.sync
        active: root.needsAttention
        tooltipText: root.statusText()
        onPressed: function(mouseButton) { if (mouseButton === Qt.LeftButton) root.toggle() }
        NumberAnimation on textRotation {
            running: root.working
            from: 0; to: -360; duration: 1600; loops: Animation.Infinite
            onRunningChanged: if (!running) button.textRotation = 0
        }
    }
}
