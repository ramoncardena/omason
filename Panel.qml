pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
    id: root
    moduleName: "io.github.ramoncardena.omason"
    ipcTarget: moduleName
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    readonly property var barIdentity: hostWidget || root
    readonly property var host: hostWidget || ({ profiles: [], history: [], selectedProfile: "", available: true, busy: false, errorMessage: "", profileDirectory: "~/.unison", session: { phase: "idle", items: [], current: "", message: "", details: "", detailsPath: "", tail: "", run: "", totals: {}, progress: null, syncRequested: false } })
    readonly property var sessionState: host.session
    readonly property string family: bar ? bar.fontFamily : Style.font.family
    readonly property color foreground: root.barForeground
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property color accent: Commons.Color.accent
    readonly property color urgent: Commons.Color.urgent

    // Which screen is showing is derived from session state, so closing and
    // reopening the popup always lands on the live session.
    property bool creating: false
    property var record: null
    property string dismissedRun: ""
    property string expandedPath: ""
    property string diffPath: ""
    property string viewerPath: ""
    readonly property int previewLines: 8
    readonly property var viewerItem: viewerPath ? sessionState.items.find(function(i) { return i.path === root.viewerPath }) || null : null
    property bool showLog: false
    property int cursor: 0
    property bool cursorActive: false
    property int phraseIndex: 0
    property real now: Date.now()

    readonly property string phase: sessionState.phase
    readonly property bool finished: ["complete", "partial", "error", "cancelled"].indexOf(phase) >= 0
    readonly property bool syncing: phase === "syncing" || phase === "cancelling"
    // Set once a sync has started in this session, so "cancelling" can say Stopping.
    property bool committing: false
    onPhaseChanged: {
        if (phase === "syncing") committing = true
        else if (phase === "scanning" && !sessionState.items.length) committing = false
        // A cancelled review has nothing to show: go straight back to the profile.
        // Finished, failed and stopped syncs keep their result on screen.
        else if (phase === "cancelled" && !committing) dismissedRun = sessionState.run
    }
    readonly property bool sessionVisible: host.busy || (finished && !!sessionState.run && sessionState.run !== dismissedRun)
    readonly property string view: sessionVisible ? "session" : (creating ? "create" : (record ? "record" : "home"))
    readonly property var shownItems: view === "record" ? (record.items || []) : (view === "session" ? sessionState.items : [])
    readonly property var shownProfile: profileNamed(view === "record" ? record.profile : sessionState.profile)
    readonly property var leftReplica: Model.replicaOf(shownProfile, 0)
    readonly property var rightReplica: Model.replicaOf(shownProfile, 1)
    readonly property var plan: Model.sections(shownItems, leftReplica.name, rightReplica.name)
    readonly property var tally: Model.counts(shownItems)
    readonly property bool editable: view === "session" && sessionState.items.length > 0 && !sessionState.syncRequested
        && (phase === "review" || phase === "ready" || phase === "scanning")
    readonly property bool canSync: editable && tally.toRight + tally.toLeft > 0 && tally.merges === 0
    readonly property bool syncRowVisible: view === "session" && sessionState.items.length > 0 && phase !== "warning"
    readonly property var homeList: Model.profileGroups(host.profiles)
    readonly property var selected: profileNamed(host.selectedProfile)
    readonly property var profileOptions: homeList.rows.map(function(p) { return { value: p.name, label: p.label, description: Model.profileDescription(p, root.now) } })
    readonly property var recent: Model.recentRuns(host.history.filter(function(r) { return r.profile === root.host.selectedProfile }), 3)
    readonly property bool canScan: !host.busy && host.available && !!selected && !Model.offlineReplica(selected)
    readonly property int targetCount: view === "home" ? (host.profiles.length ? 2 + recent.length : 1)
        : (view === "session" ? plan.rows.length + (syncRowVisible ? 1 : 0) : (view === "record" ? plan.rows.length : 0))

    readonly property var scanPhrases: ["Comparing replicas", "Reading archives", "Walking both trees", "Spotting differences", "Checking fingerprints"]

    onViewChanged: {
        cursor = 0
        cursorActive = false
        expandedPath = ""
        diffPath = ""
        viewerPath = ""
        showLog = false
        if (panelFlick) panelFlick.contentY = 0
    }
    onTargetCountChanged: if (cursor >= targetCount) cursor = Math.max(0, targetCount - 1)
    onOpenedChanged: if (opened) {
        cursorActive = false
        now = Date.now()
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    function profileNamed(name) {
        return host.profiles.find(function(p) { return p.name === name }) || null
    }
    function send(command, args) { if (root.hostWidget) root.hostWidget.request(command, args) }
    function switchPanel(direction) {
        return root.bar && typeof root.bar.switchPanelFrom === "function" ? root.bar.switchPanelFrom(root.barIdentity, direction) : false
    }

    // ---- actions -------------------------------------------------------
    function startScan(name) {
        if (host.busy || !host.available || !name) return
        record = null
        creating = false
        showLog = false
        if (root.hostWidget) root.hostWidget.selectedProfile = name
        send("start", { profile: name })
    }
    function selectProfile(name) { if (root.hostWidget && name) root.hostWidget.selectedProfile = name }
    function cycleProfile(step) {
        const rows = homeList.rows
        if (!rows.length) return
        const at = rows.findIndex(function(p) { return p.name === root.host.selectedProfile })
        selectProfile(rows[(Math.max(0, at) + step + rows.length) % rows.length].name)
    }
    function scanLabel() {
        const offline = Model.offlineReplica(selected)
        if (offline) return offline.name + " is not connected"
        if (host.busy) return "Another session is running"
        return "Scan for changes"
    }
    function setDirection(item, choice) {
        if (!editable || !item || item.arrow === "error") return
        send("set", { path: item.path, choice: choice })
    }
    function cycle(item) {
        const d = Model.direction(item.arrow)
        setDirection(item, d === "right" ? "left" : (d === "left" ? "skip" : "right"))
    }
    // Diff is a toggle; Unison is asked again only when its output isn't for this row.
    function inspect(item) {
        if (!Model.diffable(item)) return
        if (diffPath === item.path) { diffPath = ""; return }
        expandedPath = item.path
        diffPath = item.path
        if ((sessionState.detailsPath !== item.path || !sessionState.details) && editable)
            send("inspect", { path: item.path })
    }
    // Full diff in the overlay; loads it first if this row's diff isn't the loaded one.
    function openFullDiff(item) {
        if (!Model.diffable(item)) return
        viewerPath = item.path
        if (sessionState.detailsPath === item.path && sessionState.details) { diffViewer.open(); return }
        expandedPath = item.path
        diffPath = item.path
        if (editable) send("inspect", { path: item.path })
    }
    onSessionStateChanged: {
        if (viewerPath && !diffViewer.opened && sessionState.detailsPath === viewerPath) diffViewer.open()
        // A diff that just arrived grows the open row: keep it in view.
        if (diffPath && diffPath === expandedPath && sessionState.detailsPath === diffPath) scrollToCursor()
    }
    function logPath() {
        if (view === "record") return record.logPath || ""
        return sessionState.run && host.stateDirectory ? host.stateDirectory + "/" + sessionState.run + ".log" : ""
    }
    // The popup covers the panel, so close it first or the editor opens behind.
    function openLogFile() {
        const path = logPath()
        if (!path) return
        showLog = false
        close()
        Qt.openUrlExternally("file://" + path)
    }
    function toggleExpand(item) {
        expandedPath = expandedPath === item.path ? "" : item.path
        if (expandedPath) scrollToCursor()
    }
    function sync() { if (canSync) send("apply") }
    function stop() { if (host.busy && phase !== "cancelling") send("cancel") }
    // Unison is held open from scan to confirmation, but until a sync starts
    // nothing has been copied: that is a cancel, not a stop.
    function stopLabel() {
        if (phase === "cancelling") return committing ? "Stopping…" : "Cancelling…"
        return phase === "syncing" ? "Stop sync" : "Cancel"
    }
    function done() { if (finished) dismissedRun = sessionState.run }
    function openCreate() {
        if (host.busy) return
        record = null
        creating = true
        focusDelay.restart()
    }
    function cancelForm() { creating = false; keyCatcher.forceActiveFocus() }
    function saveProfile() { send("create", { name: nameField.text, left: leftField.text, right: rightField.text }) }
    function fieldKey(event, next) {
        if (event.key === Qt.Key_Escape) { cancelForm(); event.accepted = true }
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && next) { next.forceActiveFocus(); event.accepted = true }
    }
    function back() {
        if (view === "session") done()
        else if (view === "record") record = null
        else if (view === "create") cancelForm()
    }

    // ---- cursor --------------------------------------------------------
    function cursorRow() { return (view === "session" || view === "record") && cursor < plan.rows.length ? plan.rows[cursor] : null }
    function setCursor(index) { cursorActive = true; cursor = index }
    function move(dx, dy) {
        if (dy !== 0) {
            if (!cursorActive) { cursorActive = true; return }
            cursor = Math.max(0, Math.min(targetCount - 1, cursor + dy))
            scrollToCursor()
        } else if (dx !== 0 && view === "home") {
            cycleProfile(dx > 0 ? 1 : -1)
        } else if (dx !== 0 && cursorActive && cursorRow() && view === "session") {
            setDirection(cursorRow(), dx > 0 ? "right" : "left")
        }
    }
    function activate() {
        if (!cursorActive) { cursorActive = true; return }
        if (view === "home") {
            if (!host.profiles.length) openCreate()
            else if (cursor === 0) profilePicker.open()
            else if (cursor === 1) startScan(host.selectedProfile)
            else record = recent[cursor - 2]
        } else if (cursorRow()) {
            toggleExpand(cursorRow())
        } else if (view === "session") {
            if (finished) done()
            else sync()
        }
    }
    function textKey(text) {
        const row = cursorActive ? cursorRow() : null
        if (text === "\b") back()
        else if (view === "home" && text === "n") openCreate()
        else if (view === "home" && text === "r") startScan(host.selectedProfile)
        else if (view === "home" && text === "p" && host.profiles.length) profilePicker.open()
        else if (view === "session" && text === "r" && finished) { const name = sessionState.profile; done(); startScan(name) }
        else if (view === "session" && text === "u" && row) setDirection(row, "default")
        else if (view === "session" && text === "d" && row) inspect(row)
        else if (view === "session" && text === "f" && row) openFullDiff(row)
        else if (view === "session" && text === "g") sync()
        else if (view === "session" && text === "c") stop()
        else if (view === "session" && text === "v") showLog = !showLog
    }
    function scrollToCursor() {
        Qt.callLater(function() {
            let item = null
            if (view === "home") {
                item = cursor === 0 ? profilePicker : (cursor === 1 ? scanButton : recentRepeater.itemAt(cursor - 2))
            } else if (cursor < plan.rows.length) {
                item = planRepeater.itemAt(plan.rowEntry[cursor])
            }
            if (!item) return
            const margin = Style.space(8)
            const top = item.mapToItem(panelFlick.contentItem, 0, 0).y
            const bottom = top + item.height
            const maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
            if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
            else if (bottom > panelFlick.contentY + panelFlick.height - margin)
                panelFlick.contentY = Math.min(maxY, Math.max(0, top - margin), bottom + margin - panelFlick.height)
        })
    }

    // ---- text for the hero and footer ----------------------------------
    function sessionMeta() {
        if (phase === "scanning" && !sessionState.items.length) return scanPhrases[phraseIndex % scanPhrases.length]
        if (phase === "warning") return "Needs your confirmation"
        if (sessionState.syncRequested) return "Starting sync"
        if (phase === "scanning") return sessionState.pending ? "Applying your choices" : "Working"
        if (phase === "syncing") {
            const progress = sessionState.progress
            return "Syncing · " + (progress && progress.bytes ? progress.bytes : (progress ? progress.percent : 0) + "%")
        }
        if (phase === "cancelling") return committing ? "Stopping safely" : "Cancelling"
        const result = sessionState.result
        if (phase === "complete" && !sessionState.items.length) return "Already in sync"
        if ((phase === "complete" || phase === "partial") && result) {
            let text = "Synced " + result.transferred + (result.transferred === 1 ? " item" : " items")
            if (result.skipped) text += " · held " + result.skipped
            if (result.failed) text += " · failed " + result.failed
            return text
        }
        if (phase === "complete") return "Synced"
        if (phase === "partial") return "Partly synced"
        if (phase === "cancelled") return committing ? "Stopped" : "Cancelled · nothing copied"
        if (phase === "error") return "Unison failed"
        const changes = tally.total + (tally.total === 1 ? " change" : " changes")
        return tally.unresolved ? changes + " · " + tally.unresolved + (tally.unresolved === 1 ? " needs you" : " need you") : changes
    }
    function homeMeta() {
        if (!host.available) return "Unison is not installed"
        const profiles = host.profiles
        const count = profiles.length + (profiles.length === 1 ? " profile" : " profiles")
        const offline = []
        profiles.forEach(function(p) {
            const r = Model.offlineReplica(p)
            if (r && offline.indexOf(r.name) < 0) offline.push(r.name)
        })
        if (offline.length) return offline.join(", ") + " not connected"
        const failed = profiles.filter(function(p) { return p.last && (p.last.phase === "error" || p.last.phase === "partial") }).length
        if (failed) return count + " · " + failed + (failed === 1 ? " needs attention" : " need attention")
        const last = host.history.find(function(r) { return r.committed })
        if (last) return count + " · last sync " + Model.relativeTime(last.finished, now)
        return count + " · never synced"
    }
    function syncLabel() {
        if (phase === "syncing") return "Syncing " + (sessionState.progress ? sessionState.progress.done + " of " + sessionState.progress.total : "") + "…"
        if (phase === "cancelling") return "Stopping…"
        if (sessionState.syncRequested) return "Starting sync…"
        if (tally.merges) return "Choose a side for " + tally.merges + (tally.merges === 1 ? " merge" : " merges")
        const count = tally.toRight + tally.toLeft
        if (!count) return "Nothing to sync"
        return "Sync " + count + (count === 1 ? " change" : " changes") + (tally.held ? " · hold " + tally.held : "")
    }
    function hint() {
        if (view === "home") return "←→ profile · P search · ⏎ scan · N new profile · Esc close"
        if (view === "record") return "↑↓ move · ⏎ details · ⌫ back"
        if (view === "create") return "⏎ next field · Esc cancel"
        if (finished) return "R scan again · ⏎ / ⌫ done · V output"
        if (syncing) return "C stop sync · V output"
        if (phase === "warning") return "C cancel · V output"
        return "←→ direction · X hold · U reset · D diff · F full diff · G sync · C cancel"
    }

    Timer { id: focusDelay; interval: 120; onTriggered: if (root.creating) nameField.forceActiveFocus() }
    Timer { interval: 30000; running: root.opened; repeat: true; onTriggered: root.now = Date.now() }
    Timer {
        interval: 2400
        running: root.opened && root.phase === "scanning" && !root.sessionState.items.length
        repeat: true
        onTriggered: phraseSwap.restart()
    }
    SequentialAnimation {
        id: phraseSwap
        PropertyAnimation { target: hero; property: "metaOpacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
        ScriptAction { script: root.phraseIndex = root.phraseIndex + 1 }
        PropertyAnimation { target: hero; property: "metaOpacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(540))
        contentHeight: panel.fittedContentHeight(stickyTop.implicitHeight + content.implicitHeight + stickyBottom.implicitHeight, Style.space(780))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: (root.creating && root.view === "create") || profilePicker.popupOpen || logPopup.opened || diffViewer.opened
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }
            onMoveRequested: function(dx, dy) { root.move(dx, dy) }
            onActivateRequested: root.activate()
            onDeleteRequested: if (root.cursorActive && root.cursorRow()) root.setDirection(root.cursorRow(), "skip")
            onTextKey: function(text) { root.textKey(text) }

            UnisonOutput {
                id: logPopup
                width: keyCatcher.width
                height: keyCatcher.height
            }
            DiffViewer {
                id: diffViewer
                width: keyCatcher.width
                height: keyCatcher.height
                item: root.viewerItem
            }

            // Header and actions stay put; only the content between them scrolls.
            Column {
                id: stickyTop
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(12)
                bottomPadding: Style.space(12)

            // ---- hero ----------------------------------------------
            Item {
                id: heroBox
                width: parent.width
                implicitHeight: hero.implicitHeight
                // Reached from the hero's trailingControl, whose `root` is PanelHero.
                readonly property string actionGlyph: root.view === "home" ? Model.glyph.added
                    : (root.view !== "session" ? Model.glyph.back : (root.syncing ? Model.glyph.stop : Model.glyph.close))
                readonly property string actionTip: root.view === "home" ? "New profile"
                    : (root.view !== "session" ? "Back" : (root.syncing ? "Stop sync" : (root.host.busy ? "Cancel review · nothing is copied" : "Done")))
                readonly property bool actionEnabled: root.view === "home" ? !root.host.busy && root.host.available
                    : (root.view !== "session" || !root.host.busy || root.phase !== "cancelling")
                function act() {
                    if (root.view === "home") root.openCreate()
                    else if (root.view === "session" && root.host.busy) root.stop()
                    else root.back()
                }

                PanelHero {
                    id: hero
                    width: parent.width
                    title: root.view === "home" ? "omaSon"
                        : (root.view === "create" ? "New profile"
                        : ((root.shownProfile ? root.shownProfile.label : (root.view === "record" ? root.record.profile : root.sessionState.profile)) || "omaSon"))
                    meta: root.view === "home" ? root.homeMeta()
                        : (root.view === "create" ? "Pair two replicas"
                        : (root.view === "record" ? Model.runSummary(root.record) + " · " + Qt.formatDateTime(new Date(root.record.started * 1000), "dd MMM HH:mm") : root.sessionMeta()))
                    foreground: root.foreground
                    fontFamily: root.family
                    iconComponent: Component {
                        Text {
                            id: heroIcon
                            text: Model.glyph.sync
                            color: root.phase === "error" && root.view === "session" ? root.urgent : root.foreground
                            font.family: root.family
                            font.pixelSize: Style.font.display
                            RotationAnimation on rotation {
                                running: root.view === "session" && (root.phase === "scanning" || root.syncing)
                                from: 0; to: -360; duration: 1600; loops: Animation.Infinite
                                onRunningChanged: if (!running) heroIcon.rotation = 0
                            }
                        }
                    }
                    trailingControl: Component {
                        PanelActionButton {
                            iconText: heroBox.actionGlyph
                            tooltipText: heroBox.actionTip
                            foreground: hero.foreground
                            fontFamily: hero.fontFamily
                            enabled: heroBox.actionEnabled
                            onClicked: heroBox.act()
                        }
                    }
                }
            }

            Text {
                visible: root.host.errorMessage !== "" || !root.host.available
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: !root.host.available ? "Unison is not installed. Install the unison package to begin." : root.host.errorMessage
                color: root.urgent
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
            }

            BridgeCard {
                visible: root.view === "session" || root.view === "record"
                width: parent.width
                leftSide: root.leftReplica
                rightSide: root.rightReplica
            }
            }

            Flickable {
                id: panelFlick
                anchors.top: stickyTop.bottom
                anchors.bottom: stickyBottom.top
                anchors.left: parent.left
                anchors.right: parent.right
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

                Column {
                    id: content
                    width: panelFlick.width
                    spacing: Style.space(12)

                    // ---- home ----------------------------------------------
                    Column {
                        visible: root.view === "home"
                        width: parent.width
                        spacing: Style.space(12)

                        PanelSeparator { foreground: root.foreground }

                        SearchableDropdown {
                            id: profilePicker
                            visible: root.host.profiles.length > 0
                            width: parent.width
                            label: "PROFILE"
                            placeholderText: "Search profiles…"
                            emptyText: "No matching profile"
                            options: root.profileOptions
                            value: root.host.selectedProfile
                            fontFamily: root.family
                            hasCursor: root.cursorActive && root.cursor === 0
                            onHovered: function(isHovered) { if (isHovered) root.setCursor(0) }
                            onChanged: function(value) {
                                root.selectProfile(value)
                                root.setCursor(1)
                                keyCatcher.forceActiveFocus()
                            }
                        }

                        BridgeCard {
                            visible: !!root.selected
                            width: parent.width
                            leftSide: Model.replicaOf(root.selected, 0)
                            rightSide: Model.replicaOf(root.selected, 1)
                            preview: true
                        }

                        Column {
                            visible: !!root.selected
                            width: parent.width
                            spacing: Style.spacing.labelGap
                            InfoPair { label: "Covers"; value: Model.profileCoverage(root.selected) }
                            InfoPair {
                                visible: !!root.selected && root.selected.ignores > 0
                                label: "Ignores"
                                value: root.selected ? root.selected.ignores + (root.selected.ignores === 1 ? " rule" : " rules") : ""
                            }
                            InfoPair {
                                readonly property var last: root.selected ? root.selected.last : null
                                label: "Last run"
                                value: last ? Model.runSummary(last) + " · " + Model.relativeTime(last.finished, root.now) : "Never synced"
                                valueColor: last && (last.phase === "error" || last.phase === "partial") ? root.urgent : root.foreground
                            }
                        }

                        Button {
                            id: scanButton
                            visible: root.host.profiles.length > 0
                            width: parent.width
                            text: root.scanLabel()
                            bordered: true
                            selected: root.canScan
                            hasCursor: root.cursorActive && root.cursor === 1
                            enabled: root.canScan
                            opacity: enabled ? 1 : 0.55
                            fontFamily: root.family
                            onHovered: function(isHovered) { if (isHovered) root.setCursor(1) }
                            onClicked: root.startScan(root.host.selectedProfile)
                        }

                        // No profiles yet.
                        Column {
                            visible: root.host.profiles.length === 0
                            width: parent.width
                            spacing: Style.space(10)
                            Caption { text: "No Unison profiles in " + root.host.profileDirectory + " yet. Pair two folders, a drive, or an SSH host to start." }
                            Button {
                                width: parent.width
                                text: "New profile"
                                bordered: true
                                hasCursor: root.cursorActive && root.cursor === 0
                                fontFamily: root.family
                                onHovered: function(isHovered) { if (isHovered) root.setCursor(0) }
                                onClicked: root.openCreate()
                            }
                        }

                        PanelSeparator { visible: root.recent.length > 0; foreground: root.foreground }
                        PanelSectionHeader { visible: root.recent.length > 0; text: "RECENT RUNS"; foreground: root.foreground; fontFamily: root.family }
                        Column {
                            visible: root.recent.length > 0
                            width: parent.width
                            spacing: Style.space(4)
                            Repeater {
                                id: recentRepeater
                                model: root.view === "home" ? root.recent : []
                                ListRow {
                                    id: recentRow
                                    required property var modelData
                                    required property int index
                                    width: parent.width
                                    rowIndex: 2 + index
                                    glyphText: Model.statusGlyph(modelData.phase)
                                    glyphColor: modelData.phase === "error" || modelData.phase === "partial" ? root.urgent : root.foreground
                                    title: Model.runSummary(modelData)
                                    caption: Qt.formatDateTime(new Date(modelData.finished * 1000), "ddd dd MMM · HH:mm")
                                    trailing: Model.relativeTime(modelData.finished, root.now)
                                    onActivated: root.record = recentRow.modelData
                                }
                            }
                        }
                    }

                    // ---- new profile ---------------------------------------
                    Column {
                        visible: root.view === "create"
                        width: parent.width
                        spacing: Style.space(8)

                        PanelSeparator { foreground: root.foreground }
                        BridgeCard {
                            width: parent.width
                            leftSide: Model.classify(leftField.text)
                            rightSide: Model.classify(rightField.text)
                            preview: true
                        }
                        FieldLabel { text: "NAME" }
                        TextField { id: nameField; width: parent.width; placeholderText: "documents"; Keys.onPressed: function(event) { root.fieldKey(event, leftField) } }
                        FieldLabel { text: "LEFT REPLICA" }
                        TextField { id: leftField; width: parent.width; placeholderText: "/home/you/Documents"; Keys.onPressed: function(event) { root.fieldKey(event, rightField) } }
                        FieldLabel { text: "RIGHT REPLICA" }
                        TextField { id: rightField; width: parent.width; placeholderText: "/run/media/you/Drive/Documents  or  ssh://user@host//path"; Keys.onPressed: function(event) { root.fieldKey(event, null) }; onAccepted: root.saveProfile() }
                        Caption { text: "Local folders must already exist. SSH uses your agent and known hosts. New profiles keep five backup versions of replaced files." }
                        Row {
                            width: parent.width
                            spacing: Style.space(8)
                            Button { width: (parent.width - parent.spacing) / 2; text: "Create profile"; bordered: true; focusable: true; fontFamily: root.family; onClicked: root.saveProfile() }
                            Button { width: (parent.width - parent.spacing) / 2; text: "Cancel"; bordered: true; focusable: true; fontFamily: root.family; onClicked: root.cancelForm() }
                        }
                    }

                    // ---- session & record ----------------------------------
                    Column {
                        visible: root.view === "session" || root.view === "record"
                        width: parent.width
                        spacing: Style.space(12)

                        WarningCard { visible: root.view === "session" && root.phase === "warning"; width: parent.width }

                        // Empty and in-between states.
                        Column {
                            visible: root.shownItems.length === 0 && root.phase !== "warning"
                            width: parent.width
                            topPadding: Style.space(10)
                            bottomPadding: Style.space(10)
                            spacing: Style.space(6)
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.phase === "scanning" || root.view === "record" ? "" : (root.phase === "complete" ? Model.glyph.check : Model.statusGlyph(root.phase))
                                visible: text !== ""
                                color: root.phase === "complete" ? root.accent : root.urgent
                                font.family: root.family
                                font.pixelSize: Style.font.display
                            }
                            Text {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                textFormat: Text.PlainText
                                wrapMode: Text.WordWrap
                                text: root.view === "record" ? "No changes were recorded for this session."
                                    : (root.phase === "scanning" ? "Looking for changes on both sides…"
                                    : (root.phase === "complete" ? "Everything is in sync." : root.sessionState.message))
                                color: root.dim
                                font.family: root.family
                                font.pixelSize: Style.font.body
                            }
                        }

                        Caption {
                            // On success the hero says what happened; holding changes isn't a problem either.
                            visible: root.view === "record" || (root.finished && root.shownItems.length > 0
                                && (root.phase === "error" || (root.phase === "cancelled" ? root.committing : (!root.sessionState.result || root.sessionState.result.failed > 0))))
                            text: root.view === "record" ? root.record.message + "\nLog: " + root.record.logPath : root.sessionState.message
                            color: root.view === "session" && root.phase !== "complete" ? root.urgent : root.dim
                        }

                        Column {
                            visible: root.shownItems.length > 0
                            width: parent.width
                            spacing: Style.space(3)
                            Repeater {
                                id: planRepeater
                                model: root.plan.entries
                                Column {
                                    id: entryBox
                                    required property var modelData
                                    width: parent.width
                                    topPadding: modelData.header ? Style.space(8) : 0
                                    bottomPadding: modelData.header ? Style.space(2) : 0
                                    Row {
                                        visible: entryBox.modelData.header
                                        width: parent.width
                                        spacing: Style.space(8)
                                        PanelSectionHeader {
                                            text: entryBox.modelData.header ? entryBox.modelData.title + " · " + entryBox.modelData.count : ""
                                            foreground: root.foreground
                                            fontFamily: root.family
                                        }
                                        PanelSectionHeader {
                                            // Only the attention group tracks decisions: "1 OPEN" once some are made, "DECIDED" when all are.
                                            readonly property var entry: entryBox.modelData
                                            visible: entry.header && entry.key === "attention" && entry.pending < entry.count
                                            text: !visible ? "" : (entry.pending ? entry.pending + " OPEN" : "DECIDED")
                                            foreground: entry.pending ? root.urgent : root.accent
                                            color: entry.pending ? root.urgent : root.accent
                                            fontFamily: root.family
                                        }
                                    }
                                    ChangeRow {
                                        visible: !entryBox.modelData.header
                                        width: parent.width
                                        item: entryBox.modelData.header ? null : entryBox.modelData.item
                                        rowIndex: entryBox.modelData.header ? -1 : entryBox.modelData.index
                                    }
                                }
                            }
                        }

                    }
                }
            }

            // Hairlines where the list continues out of view.
            Rectangle {
                visible: panelFlick.contentY > 1
                anchors.top: panelFlick.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: root.foreground
                opacity: 0.18
            }
            Rectangle {
                visible: panelFlick.contentY < panelFlick.contentHeight - panelFlick.height - 1
                anchors.bottom: panelFlick.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 1
                color: root.foreground
                opacity: 0.18
            }

            Column {
                id: stickyBottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(12)
                topPadding: Style.space(12)

            // Progress through propagation.
            Item {
                visible: root.view === "session" && root.syncing
                width: parent.width
                height: Style.space(4)
                Rectangle { anchors.fill: parent; radius: height / 2; color: root.foreground; opacity: 0.12 }
                Rectangle {
                    width: parent.width * Math.min(1, (root.sessionState.progress ? root.sessionState.progress.percent : 0) / 100)
                    height: parent.height
                    radius: height / 2
                    color: root.accent
                    Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                }
            }

            Row {
                id: actionRow
                visible: root.view === "session" && (root.syncRowVisible || root.finished)
                width: parent.width
                spacing: Style.space(8)
                readonly property bool primaryHasCursor: root.cursorActive && root.cursor === root.plan.rows.length && root.syncRowVisible
                Button {
                    width: (parent.width - parent.spacing) / 2
                    text: root.finished ? "Scan again" : root.syncLabel()
                    bordered: true
                    selected: !root.finished && root.canSync
                    // The one action that changes files: drawn in the accent colour.
                    foreground: !root.finished && root.canSync ? root.accent : root.foreground
                    hasCursor: actionRow.primaryHasCursor
                    fontFamily: root.family
                    enabled: root.finished || root.canSync
                    opacity: enabled ? 1 : 0.55
                    onHovered: function(isHovered) { if (isHovered && root.syncRowVisible) root.setCursor(root.plan.rows.length) }
                    Rectangle {
                        visible: !root.finished && root.canSync
                        anchors.fill: parent
                        z: -1
                        radius: Style.cornerRadius
                        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                        border.width: 1
                        border.color: root.accent
                    }
                    onClicked: {
                        if (!root.finished) { root.sync(); return }
                        const name = root.sessionState.profile
                        root.done()
                        root.startScan(name)
                    }
                }
                Button {
                    width: (parent.width - parent.spacing) / 2
                    text: root.finished ? "Done" : root.stopLabel()
                    bordered: true
                    fontFamily: root.family
                    enabled: root.finished || root.phase !== "cancelling"
                    opacity: enabled ? 1 : 0.55
                    onClicked: root.finished ? root.done() : root.stop()
                }
            }

            Button {
                visible: root.view === "session" && root.sessionState.tail !== ""
                width: parent.width
                text: "Show Unison output"
                fontFamily: root.family
                fontSize: Style.font.bodySmall
                onClicked: root.showLog = true
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: root.hint()
                color: root.dim
                opacity: 0.8
                font.family: root.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
            }
            }
        }
    }

    // ---- components --------------------------------------------------------

    // Frame shared by the overlays: covers the panel content, title and close
    // button on top, a tinted body, a row of buttons at the bottom.
    component Overlay: Controls.Popup {
        id: overlay
        property string title: ""
        property string subtitle: ""
        default property alias body: overlayBody.data
        property alias buttons: overlayButtons.data

        x: 0
        y: 0
        padding: Style.space(14)
        modal: true
        dim: false
        focus: true
        closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
        onClosed: keyCatcher.forceActiveFocus()

        background: BorderSurface {
            color: Commons.Color.popups.background
            borderSpec: Border.localOrSurfaceSpec("popups", "border", Commons.Color.popups.border, Commons.Color.popups.border, Style.normalBorderWidth)
            radius: Style.cornerRadius
        }

        contentItem: Column {
            spacing: Style.space(10)

            Item {
                id: overlayHeader
                width: parent.width
                implicitHeight: Math.max(overlayTitle.implicitHeight, overlayClose.implicitHeight)
                Column {
                    id: overlayTitle
                    anchors.left: parent.left
                    anchors.right: overlayClose.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    PanelSectionHeader { text: overlay.title; foreground: root.foreground; fontFamily: root.family }
                    Text {
                        width: parent.width
                        visible: text !== ""
                        textFormat: Text.PlainText
                        text: overlay.subtitle
                        color: root.dim
                        font.family: root.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                    }
                }
                PanelActionButton {
                    id: overlayClose
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: Model.glyph.close
                    tooltipText: "Close"
                    foreground: root.foreground
                    fontFamily: root.family
                    onClicked: overlay.close()
                }
            }

            Rectangle {
                id: overlayBody
                width: parent.width
                height: Math.max(Style.space(80), overlay.availableHeight - overlayHeader.height - overlayButtons.height - parent.spacing * 2)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            }

            Row {
                id: overlayButtons
                width: parent.width
                spacing: Style.space(8)
            }
        }
    }

    // Unison's raw output over the panel, so the panel itself never scrolls
    // through it. Follows new output while scrolled to the end.
    component UnisonOutput: Overlay {
        id: output
        property bool following: true
        readonly property string text: Model.cleanLog(root.sessionState.tail)

        title: "UNISON OUTPUT"
        subtitle: "Latest output of this session · " + (root.logPath().split("/").pop() || "no log yet")
        onOpened: {
            following = true
            logText.forceActiveFocus()
            Qt.callLater(scrollToEnd)
        }
        onClosed: root.showLog = false
        onTextChanged: if (opened && following) Qt.callLater(scrollToEnd)

        function scrollToEnd() { logFlick.contentY = Math.max(0, logFlick.contentHeight - logFlick.height) }
        function scrollBy(dy) {
            logFlick.contentY = Math.max(0, Math.min(logFlick.contentHeight - logFlick.height, logFlick.contentY + dy))
            following = logFlick.atYEnd
        }

        Connections {
            target: root
            function onShowLogChanged() { if (root.showLog) output.open(); else output.close() }
        }

        Flickable {
            id: logFlick
            anchors.fill: parent
            anchors.margins: Style.space(8)
            contentWidth: width
            contentHeight: logText.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onMovementEnded: output.following = atYEnd
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }

            TextEdit {
                id: logText
                width: logFlick.width
                readOnly: true
                selectByMouse: true
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.WrapAnywhere
                text: output.text
                color: root.foreground
                selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                font.family: root.family
                font.pixelSize: Style.font.caption
                Keys.onPressed: function(event) {
                    const page = logFlick.height * 0.9
                    if (event.key === Qt.Key_Down || event.text === "j") output.scrollBy(Style.space(40))
                    else if (event.key === Qt.Key_Up || event.text === "k") output.scrollBy(-Style.space(40))
                    else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_Space) output.scrollBy(page)
                    else if (event.key === Qt.Key_PageUp) output.scrollBy(-page)
                    else if (event.key === Qt.Key_End || event.text === "G") { output.scrollToEnd(); output.following = true }
                    else if (event.key === Qt.Key_Home || event.text === "g") output.scrollBy(-logFlick.contentHeight)
                    else if (event.text === "v" || event.text === "q") output.close()
                    else if (event.text === "o") root.openLogFile()
                    else return
                    event.accepted = true
                }
            }
        }

        buttons: [
            Button {
                width: (output.availableWidth - Style.space(8)) / 2
                text: "Open log file"
                bordered: true
                enabled: root.logPath() !== ""
                fontFamily: root.family
                onClicked: root.openLogFile()
            },
            Button {
                width: (output.availableWidth - Style.space(8)) / 2
                text: "Close"
                bordered: true
                fontFamily: root.family
                onClicked: output.close()
            }
        ]
    }

    // The whole diff of one change: a section per hunk with its line range,
    // line numbers, tinted added/removed lines. N/P jump between hunks.
    component DiffViewer: Overlay {
        id: viewer
        property var item: null
        property int hunk: 0
        readonly property var diff: item && root.sessionState.detailsPath === item.path ? Model.parseDiff(root.sessionState.details) : null
        readonly property int hunkCount: diff ? diff.hunks.length : 0

        title: "DIFF"
        subtitle: !item ? "" : item.path + (diff && diff.unified ? "  ·  " + Model.diffStat(diff) + "  ·  " + Model.diffLegend(diff, root.leftReplica, root.rightReplica) : "")
        onOpened: {
            hunk = 0
            diffFlick.contentY = 0
            diffKeys.forceActiveFocus()
        }
        onClosed: root.viewerPath = ""

        function jump(step) {
            if (!hunkCount) return
            hunk = Math.max(0, Math.min(hunkCount - 1, hunk + step))
            const target = hunkRepeater.itemAt(hunk)
            if (target) diffFlick.contentY = Math.max(0, Math.min(diffFlick.contentHeight - diffFlick.height, target.y))
        }
        function scrollBy(dy) { diffFlick.contentY = Math.max(0, Math.min(diffFlick.contentHeight - diffFlick.height, diffFlick.contentY + dy)) }

        Flickable {
            id: diffFlick
            anchors.fill: parent
            anchors.margins: Style.space(8)
            contentWidth: width
            contentHeight: diffColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Controls.ScrollBar.vertical: Controls.ScrollBar { policy: Controls.ScrollBar.AsNeeded }
            // Keep "change N of M" in step with manual scrolling.
            onContentYChanged: {
                for (let i = viewer.hunkCount - 1; i >= 0; i--) {
                    const section = hunkRepeater.itemAt(i)
                    if (section && section.y <= contentY + Style.space(12)) { viewer.hunk = i; return }
                }
            }

            Item {
                id: diffKeys
                focus: true
                Keys.onPressed: function(event) {
                    const page = diffFlick.height * 0.9
                    if (event.text === "n" || event.key === Qt.Key_Right || event.text === "l") viewer.jump(1)
                    else if (event.text === "p" || event.key === Qt.Key_Left || event.text === "h") viewer.jump(-1)
                    else if (event.key === Qt.Key_Down || event.text === "j") viewer.scrollBy(Style.space(40))
                    else if (event.key === Qt.Key_Up || event.text === "k") viewer.scrollBy(-Style.space(40))
                    else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_Space) viewer.scrollBy(page)
                    else if (event.key === Qt.Key_PageUp) viewer.scrollBy(-page)
                    else if (event.key === Qt.Key_Home || event.text === "g") viewer.scrollBy(-diffFlick.contentHeight)
                    else if (event.key === Qt.Key_End || event.text === "G") viewer.scrollBy(diffFlick.contentHeight)
                    else if (event.text === "f" || event.text === "q" || event.text === "d") viewer.close()
                    else return
                    event.accepted = true
                }
            }

            Column {
                id: diffColumn
                width: diffFlick.width
                spacing: Style.space(10)

                Text {
                    visible: !!viewer.diff && !viewer.diff.unified
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: viewer.diff ? (viewer.diff.message || "Unison shows no differences.") : "Loading diff…"
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                }
                Repeater {
                    id: hunkRepeater
                    model: viewer.diff ? viewer.diff.hunks : []
                    Column {
                        id: section
                        required property var modelData
                        width: diffColumn.width
                        DiffLine { width: section.width; line: ({ kind: "hunk", text: Model.hunkLabel(section.modelData), number: 0 }) }
                        Repeater {
                            model: section.modelData.lines
                            DiffLine { required property var modelData; width: section.width; line: modelData }
                        }
                    }
                }
                Text {
                    visible: !!viewer.diff && (viewer.diff.truncated || root.sessionState.detailsTruncated)
                    width: parent.width
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: "Diff truncated. Open the log file from Unison output for the rest."
                    color: root.urgent
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                }
            }
        }

        buttons: [
            Button {
                width: (viewer.availableWidth - Style.space(8)) / 2
                text: viewer.hunkCount > 1 ? "Previous change · " + (viewer.hunk + 1) + " of " + viewer.hunkCount : "Previous change"
                bordered: true
                enabled: viewer.hunk > 0
                opacity: enabled ? 1 : 0.55
                fontFamily: root.family
                onClicked: viewer.jump(-1)
            },
            Button {
                width: (viewer.availableWidth - Style.space(8)) / 2
                text: "Next change"
                bordered: true
                enabled: viewer.hunk < viewer.hunkCount - 1
                opacity: enabled ? 1 : 0.55
                fontFamily: root.family
                onClicked: viewer.jump(1)
            }
        ]
    }

    // One diff line: number, sign, text; added/removed lines get a faint tint.
    component DiffLine: Item {
        id: diffLine
        property var line: null
        readonly property string kind: line ? line.kind : "context"
        readonly property color tint: kind === "add" ? root.accent : (kind === "remove" ? root.urgent : root.foreground)
        implicitHeight: kind === "hunk" ? hunkText.implicitHeight + Style.space(6) : lineText.implicitHeight

        Rectangle {
            anchors.fill: parent
            visible: diffLine.kind !== "context" && diffLine.kind !== "meta"
            radius: diffLine.kind === "hunk" ? Style.cornerRadius : 0
            color: Qt.rgba(diffLine.tint.r, diffLine.tint.g, diffLine.tint.b, diffLine.kind === "hunk" ? 0.06 : 0.10)
        }
        Text {
            id: hunkText
            visible: diffLine.kind === "hunk"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: visible ? diffLine.line.text : ""
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
        }
        Text {
            id: gutter
            visible: diffLine.kind !== "hunk"
            width: Style.space(34)
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: diffLine.line && diffLine.line.number ? String(diffLine.line.number) : ""
            color: root.dim
            opacity: 0.7
            font.family: root.family
            font.pixelSize: Style.font.caption
        }
        Text {
            id: sign
            visible: diffLine.kind !== "hunk"
            anchors.left: gutter.right
            anchors.leftMargin: Style.space(6)
            width: Style.space(10)
            textFormat: Text.PlainText
            text: diffLine.kind === "add" ? "+" : (diffLine.kind === "remove" ? "−" : "")
            color: diffLine.tint
            font.family: root.family
            font.pixelSize: Style.font.caption
            font.bold: true
        }
        Text {
            id: lineText
            visible: diffLine.kind !== "hunk"
            anchors.left: sign.right
            anchors.right: parent.right
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            text: visible ? (diffLine.line.text || " ") : ""
            color: diffLine.kind === "context" ? root.foreground : (diffLine.kind === "meta" ? root.dim : diffLine.tint)
            opacity: diffLine.kind === "context" ? 0.7 : 1
            font.family: root.family
            font.pixelSize: Style.font.caption
        }
    }

    // Proportion of added to removed lines, like a tiny git --stat bar.
    component DiffBar: Row {
        id: bar
        property var diff: null
        readonly property int total: diff ? diff.added + diff.removed : 0
        readonly property int blocks: 10
        readonly property int addBlocks: total ? Math.round(blocks * diff.added / total) : 0
        spacing: Style.space(2)
        Repeater {
            model: bar.total ? bar.blocks : 0
            Rectangle {
                required property int index
                width: Style.space(5)
                height: Style.space(8)
                radius: 1
                color: index < bar.addBlocks ? root.accent : root.urgent
                opacity: 0.85
            }
        }
    }

    component Caption: Text {
        width: parent ? parent.width : implicitWidth
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.dim
        font.family: root.family
        font.pixelSize: Style.font.caption
    }

    component FieldLabel: PanelSectionHeader {
        foreground: root.foreground
        fontFamily: root.family
    }

    // Generic selectable row: glyph, title, caption, trailing text.
    component ListRow: CursorSurface {
        id: listRow
        property int rowIndex: 0
        property string glyphText: ""
        property color glyphColor: root.foreground
        property string title: ""
        property string caption: ""
        property color captionColor: root.dim
        property string trailing: ""
        property string trailingGlyph: ""
        property color trailingColor: root.dim
        property real contentOpacity: 1
        signal activated()

        hasCursor: root.cursorActive && root.cursor === rowIndex
        foreground: root.foreground
        implicitHeight: listContent.implicitHeight + Style.spacing.rowPaddingX

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.setCursor(listRow.rowIndex)
            onClicked: listRow.activated()
        }

        RowLayout {
            id: listContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)
            opacity: listRow.contentOpacity

            Text {
                text: listRow.glyphText
                color: listRow.glyphColor
                font.family: root.family
                font.pixelSize: Style.font.heading
                Layout.preferredWidth: Style.space(20)
                horizontalAlignment: Text.AlignHCenter
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)
                Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: listRow.title
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    textFormat: Text.PlainText
                    text: listRow.caption
                    color: listRow.captionColor
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                }
            }
            Text {
                visible: text !== ""
                textFormat: Text.PlainText
                text: listRow.trailing
                color: listRow.trailingColor
                font.family: root.family
                font.pixelSize: Style.font.caption
            }
            Text {
                visible: text !== ""
                text: listRow.trailingGlyph
                color: listRow.trailingColor
                font.family: root.family
                font.pixelSize: Style.font.body
            }
        }
    }

    component InfoPair: Item {
        id: info
        property string label: ""
        property string value: ""
        property color valueColor: root.foreground
        width: parent ? parent.width : implicitWidth
        implicitHeight: Math.max(infoLabel.implicitHeight, infoValue.implicitHeight)
        Text {
            id: infoLabel
            anchors.left: parent.left
            anchors.leftMargin: Style.space(2)
            textFormat: Text.PlainText
            text: info.label
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
        }
        Text {
            id: infoValue
            anchors.right: parent.right
            anchors.rightMargin: Style.space(2)
            width: Math.min(implicitWidth, parent.width - infoLabel.implicitWidth - Style.space(16))
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: info.value
            color: info.valueColor
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideLeft
        }
    }

    // The two replicas facing each other, with what flows between them.
    component BridgeCard: Item {
        id: bridge
        property var leftSide: null
        property var rightSide: null
        property bool preview: false
        readonly property bool flowing: root.view === "session" && root.syncing

        implicitHeight: Math.max(leftCard.implicitHeight, rightCard.implicitHeight, flow.implicitHeight)

        ReplicaCard { id: leftCard; replica: bridge.leftSide; anchors.left: parent.left; width: (parent.width - flow.width) / 2; height: bridge.height }
        Column {
            id: flow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(96)
            spacing: Style.space(2)

            FlowLine { glyphText: Model.glyph.right; count: root.tally.toRight; size: root.sessionState.totals ? root.sessionState.totals.toRight || "" : ""; tint: root.accent; trailingGlyph: true }
            FlowLine { glyphText: Model.glyph.left; count: root.tally.toLeft; size: root.sessionState.totals ? root.sessionState.totals.toLeft || "" : ""; tint: root.accent }
            FlowLine { glyphText: Model.glyph.conflict; count: root.tally.unresolved; tint: root.urgent }
            FlowLine { glyphText: Model.glyph.held; count: root.tally.held - root.tally.unresolved; tint: root.dim }
            FlowLine { glyphText: Model.glyph.error; count: root.tally.errors; tint: root.urgent }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: bridge.preview || root.shownItems.length === 0
                text: bridge.preview ? Model.glyph.swap : (root.phase === "scanning" ? "···" : Model.glyph.check)
                color: bridge.preview || root.phase === "scanning" ? root.dim : root.accent
                font.family: root.family
                font.pixelSize: Style.font.heading
            }
            SequentialAnimation on opacity {
                running: bridge.flowing
                loops: Animation.Infinite
                NumberAnimation { to: 0.45; duration: 650; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                onRunningChanged: if (!running) flow.opacity = 1
            }
        }
        ReplicaCard { id: rightCard; replica: bridge.rightSide; anchors.right: parent.right; width: (parent.width - flow.width) / 2; height: bridge.height }
    }

    component FlowLine: Row {
        id: flowLine
        property string glyphText: ""
        property int count: 0
        property string size: ""
        property color tint: root.foreground
        property bool trailingGlyph: false
        visible: count > 0 && !(root.view === "create")
        anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined
        spacing: Style.space(5)
        Text { text: flowLine.glyphText; color: flowLine.tint; font.family: root.family; font.pixelSize: Style.font.body }
        Text { text: String(flowLine.count); color: root.foreground; font.family: root.family; font.pixelSize: Style.font.body; font.bold: true }
        Text { visible: flowLine.size !== "" && flowLine.size !== "0 B"; text: flowLine.size; color: root.dim; font.family: root.family; font.pixelSize: Style.font.caption; anchors.baseline: parent.children[1].baseline }
    }

    component ReplicaCard: CursorSurface {
        id: card
        property var replica: null
        bordered: true
        foreground: root.foreground
        implicitHeight: cardColumn.implicitHeight + Style.space(18)

        Column {
            id: cardColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(2)
            Row {
                width: parent.width
                spacing: Style.space(7)
                Text {
                    id: cardGlyph
                    text: Model.replicaGlyph(card.replica)
                    color: card.replica && card.replica.online === false ? root.urgent : root.foreground
                    font.family: root.family
                    font.pixelSize: Style.font.heading
                }
                Text {
                    width: parent.width - cardGlyph.implicitWidth - parent.spacing
                    anchors.verticalCenter: cardGlyph.verticalCenter
                    textFormat: Text.PlainText
                    text: card.replica ? card.replica.name : ""
                    color: root.foreground
                    font.family: root.family
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                }
            }
            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: card.replica ? card.replica.path : ""
                color: root.foreground
                opacity: 0.8
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
            }
            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: Model.replicaWhere(card.replica).toUpperCase()
                color: card.replica && card.replica.online === false ? root.urgent : root.dim
                font.family: root.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
            }
        }
    }

    component WarningCard: CursorSurface {
        id: warning
        readonly property bool firstRun: root.sessionState.warning === "first-run"
        bordered: true
        foreground: root.urgent
        implicitHeight: warningColumn.implicitHeight + Style.space(20)

        Column {
            id: warningColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            spacing: Style.space(8)
            Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: Model.glyph.conflict + "  " + (warning.firstRun ? "First sync for this profile" : "A whole replica would be emptied")
                color: root.urgent
                font.family: root.family
                font.pixelSize: Style.font.body
                font.bold: true
            }
            Caption {
                text: warning.firstRun
                    ? "Unison has no history for these replicas yet, so everything on each side looks new. Check the list carefully before syncing."
                    : "Every file on one side was deleted or is missing. That can mean an unmounted drive. Continue only if this is intentional.\n\n" + root.sessionState.message.slice(-600)
            }
            Row {
                width: parent.width
                spacing: Style.space(8)
                Button { width: (parent.width - parent.spacing) / 2; text: warning.firstRun ? "Continue" : "I understand, continue"; bordered: true; fontFamily: root.family; onClicked: root.send("acknowledge") }
                Button { width: (parent.width - parent.spacing) / 2; text: "Cancel"; bordered: true; fontFamily: root.family; onClicked: root.stop() }
            }
        }
    }

    // One pending change: what happened on each side and which way it goes.
    component ChangeRow: CursorSurface {
        id: change
        property var item: null
        property int rowIndex: -1
        readonly property var parts: Model.splitPath(item ? item.path : "")
        readonly property string dir: Model.direction(item ? item.arrow : "")
        readonly property bool open: item !== null && root.expandedPath === item.path
        readonly property bool waiting: item !== null && Model.unresolved(item)
        readonly property bool readOnly: root.view !== "session" || !root.editable
        readonly property color arrowTint: dir === "error" || waiting ? root.urgent : (dir === "held" ? root.dim : root.accent)

        hasCursor: root.cursorActive && root.cursor === rowIndex
        foreground: root.foreground
        implicitHeight: changeColumn.implicitHeight + Style.space(12)

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.setCursor(change.rowIndex)
            onClicked: if (change.item) root.toggleExpand(change.item)
        }

        Column {
            id: changeColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Style.space(6)
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(6)

            RowLayout {
                width: parent.width
                spacing: Style.space(10)

                Text {
                    id: rowGlyph
                    readonly property bool active: !!change.item && !!change.item.active && root.syncing
                    text: change.item ? (change.item.done ? Model.glyph.check : (active ? Model.glyph.sync : Model.kindGlyph(change.item))) : ""
                    color: change.item && (change.item.done || active) ? root.accent : root.dim
                    RotationAnimation on rotation {
                        running: rowGlyph.active
                        from: 0; to: -360; duration: 1200; loops: Animation.Infinite
                        onRunningChanged: if (!running) rowGlyph.rotation = 0
                    }
                    font.family: root.family
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: change.parts.name
                        color: root.foreground
                        font.family: root.family
                        font.pixelSize: Style.font.body
                        elide: Text.ElideMiddle
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: change.parts.dir !== ""
                        textFormat: Text.PlainText
                        text: change.parts.dir
                        color: root.dim
                        font.family: root.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideMiddle
                    }
                }

                // left state · direction pill · right state
                Text {
                    text: change.item ? Model.sideGlyph(change.item.left) : ""
                    color: change.item && change.item.left.indexOf("deleted") === 0 ? root.urgent : root.foreground
                    font.family: root.family
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                }
                Rectangle {
                    id: pill
                    opacity: change.item && change.item.done ? 0.4 : 1
                    Layout.preferredWidth: Style.space(44)
                    Layout.preferredHeight: Style.space(22)
                    radius: Style.cornerRadius
                    color: Qt.rgba(change.arrowTint.r, change.arrowTint.g, change.arrowTint.b, pillMouse.containsMouse && !change.readOnly ? 0.28 : 0.14)
                    border.width: change.item && Model.overridden(change.item) ? 1 : 0
                    border.color: change.arrowTint
                    Text {
                        anchors.centerIn: parent
                        text: change.item ? Model.directionGlyph(change.item.arrow) : ""
                        color: change.arrowTint
                        font.family: root.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                    }
                    MouseArea {
                        id: pillMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !change.readOnly
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.setCursor(change.rowIndex)
                        onClicked: if (change.item) root.cycle(change.item)
                    }
                }
                Text {
                    text: change.item ? Model.sideGlyph(change.item.right) : ""
                    color: change.item && change.item.right.indexOf("deleted") === 0 ? root.urgent : root.foreground
                    font.family: root.family
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // Expanded: both sides in words, direction choice, and the diff.
            Column {
                id: detailBox
                visible: change.open
                width: parent.width
                leftPadding: Style.space(26)
                spacing: Style.space(6)
                bottomPadding: Style.space(4)
                readonly property real innerWidth: width - leftPadding

                Repeater {
                    model: change.open ? [
                        { name: root.leftReplica.name, text: Model.sideText(change.item.leftInfo, change.item.left) },
                        { name: root.rightReplica.name, text: Model.sideText(change.item.rightInfo, change.item.right) }
                    ] : []
                    Text {
                        required property var modelData
                        width: detailBox.width - detailBox.leftPadding
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: modelData.name + "  " + modelData.text
                        color: root.dim
                        font.family: root.family
                        font.pixelSize: Style.font.caption
                    }
                }
                ButtonGroup {
                    visible: !change.readOnly && change.dir !== "error"
                    options: [
                        { value: "right", label: "To " + root.rightReplica.name, icon: Model.glyph.right },
                        { value: "left", label: "To " + root.leftReplica.name, icon: Model.glyph.left },
                        { value: "skip", label: "Hold", icon: Model.glyph.held }
                    ]
                    value: change.dir === "right" || change.dir === "left" ? change.dir : "skip"
                    foreground: root.foreground
                    fontFamily: root.family
                    fontSize: Style.font.bodySmall
                    focusable: false
                    onChanged: function(value) { if (change.item) root.setDirection(change.item, value) }
                }
                Row {
                    visible: !change.readOnly && change.dir !== "error"
                    spacing: Style.space(8)
                    Button {
                        visible: Model.diffable(change.item)
                        text: change.item && root.diffPath === change.item.path ? "Hide diff" : "Diff"
                        selected: change.item !== null && root.diffPath === change.item.path
                        bordered: true
                        fontFamily: root.family
                        fontSize: Style.font.bodySmall
                        onClicked: if (change.item) root.inspect(change.item)
                    }
                    Button {
                        visible: change.item !== null && Model.overridden(change.item)
                        text: "Reset to Unison's suggestion"
                        bordered: true
                        fontFamily: root.family
                        fontSize: Style.font.bodySmall
                        onClicked: if (change.item) root.setDirection(change.item, "default")
                    }
                }
                Text {
                    visible: change.open && root.diffPath === change.item.path && root.sessionState.detailsPath !== change.item.path
                    textFormat: Text.PlainText
                    text: root.editable ? "Loading diff…" : "Diff is available while reviewing."
                    color: root.dim
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                }
                // Unison's diff, kept short in the row: size of the change, which side
                // is which, the first lines, and the full diff one click away.
                Column {
                    id: diffView
                    readonly property bool wanted: change.open && root.diffPath === change.item.path
                    readonly property var diff: wanted && root.sessionState.detailsPath === change.item.path
                        ? Model.parseDiff(root.sessionState.details) : null
                    readonly property var preview: diff && diff.unified ? Model.diffPreview(diff, root.previewLines) : []
                    readonly property bool shortened: !!diff && (diff.lineCount + diff.hunks.length > preview.length || root.sessionState.detailsTruncated)
                    visible: diff !== null
                    width: detailBox.width - detailBox.leftPadding
                    spacing: Style.space(4)

                    Row {
                        visible: !!diffView.diff && diffView.diff.unified
                        spacing: Style.space(10)
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: diffView.diff ? Model.diffStat(diffView.diff) : ""
                            color: root.foreground
                            font.family: root.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                        }
                        DiffBar { anchors.verticalCenter: parent.verticalCenter; diff: diffView.diff }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: diffView.diff ? Model.diffLegend(diffView.diff, root.leftReplica, root.rightReplica) : ""
                            color: root.dim
                            font.family: root.family
                            font.pixelSize: Style.font.caption
                        }
                    }
                    Text {
                        visible: !!diffView.diff && !diffView.diff.unified
                        width: parent.width
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        text: !diffView.diff ? "" : (diffView.diff.binary
                            ? "Binary file · " + root.leftReplica.name + " " + (Model.formatSize(change.item.leftInfo ? change.item.leftInfo.size : null) || "—")
                              + " · " + root.rightReplica.name + " " + (Model.formatSize(change.item.rightInfo ? change.item.rightInfo.size : null) || "—")
                            : (diffView.diff.message || "Unison shows no differences."))
                        color: root.dim
                        font.family: root.family
                        font.pixelSize: Style.font.caption
                    }
                    Column {
                        width: parent.width
                        Repeater {
                            model: diffView.preview
                            DiffLine { required property var modelData; width: diffView.width; line: modelData }
                        }
                    }
                    Button {
                        visible: diffView.shortened
                        text: "View full diff"
                        bordered: true
                        fontFamily: root.family
                        fontSize: Style.font.bodySmall
                        onClicked: if (change.item) root.openFullDiff(change.item)
                    }
                }
            }
        }
    }
}
