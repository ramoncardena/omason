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
    property bool showLog: false
    property int cursor: 0
    property bool cursorActive: false
    property int phraseIndex: 0
    property real now: Date.now()

    readonly property string phase: sessionState.phase
    readonly property bool finished: ["complete", "partial", "error", "cancelled"].indexOf(phase) >= 0
    readonly property bool syncing: phase === "syncing" || phase === "cancelling"
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
    readonly property var recent: Model.recentRuns(host.history, 3)
    readonly property var homeList: Model.profileGroups(host.profiles)
    readonly property int targetCount: view === "home" ? homeList.rows.length + 1 + recent.length
        : (view === "session" ? plan.rows.length + (syncRowVisible ? 1 : 0) : (view === "record" ? plan.rows.length : 0))

    readonly property var scanPhrases: ["Comparing replicas", "Reading archives", "Walking both trees", "Spotting differences", "Checking fingerprints"]

    onViewChanged: {
        cursor = 0
        cursorActive = false
        expandedPath = ""
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
    function setDirection(item, choice) {
        if (!editable || !item || item.arrow === "error") return
        send("set", { path: item.path, choice: choice })
    }
    function cycle(item) {
        const d = Model.direction(item.arrow)
        setDirection(item, d === "right" ? "left" : (d === "left" ? "skip" : "right"))
    }
    function inspect(item) {
        if (!editable || !item || item.arrow === "error") return
        expandedPath = item.path
        send("inspect", { path: item.path })
    }
    function toggleExpand(item) { expandedPath = expandedPath === item.path ? "" : item.path }
    function sync() { if (canSync) send("apply") }
    function stop() { if (host.busy && phase !== "cancelling") send("cancel") }
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
        } else if (dx !== 0 && cursorActive && cursorRow() && view === "session") {
            setDirection(cursorRow(), dx > 0 ? "right" : "left")
        }
    }
    function activate() {
        if (!cursorActive) { cursorActive = true; return }
        if (view === "home") {
            const profiles = homeList.rows
            if (cursor < profiles.length) startScan(profiles[cursor].name)
            else if (cursor === profiles.length) openCreate()
            else record = recent[cursor - profiles.length - 1]
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
        else if (view === "home" && text === "r") startScan((homeList.rows[cursor] || homeList.rows[0] || {}).name)
        else if (view === "session" && text === "r" && finished) { const name = sessionState.profile; done(); startScan(name) }
        else if (view === "session" && text === "u" && row) setDirection(row, "default")
        else if (view === "session" && text === "d" && row) inspect(row)
        else if (view === "session" && text === "g") sync()
        else if (view === "session" && text === "c") stop()
        else if (view === "session" && text === "v") showLog = !showLog
    }
    function scrollToCursor() {
        Qt.callLater(function() {
            let item = null
            if (view === "home") {
                const count = homeList.rows.length
                const entry = homeList.entries.findIndex(function(e) { return !e.header && e.index === cursor })
                item = cursor < count ? profileRepeater.itemAt(entry) : (cursor === count ? newProfileRow : recentRepeater.itemAt(cursor - count - 1))
            } else if (cursor < plan.rows.length) {
                item = planRepeater.itemAt(plan.rowEntry[cursor])
            } else {
                item = actionRow
            }
            if (!item) return
            const margin = Style.space(8)
            const top = item.mapToItem(panelFlick.contentItem, 0, 0).y
            const bottom = top + item.height
            const maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
            if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
            else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
        })
    }

    // ---- text for the hero and footer ----------------------------------
    function sessionMeta() {
        if (phase === "scanning" && !sessionState.items.length) return scanPhrases[phraseIndex % scanPhrases.length]
        if (phase === "warning") return "Needs your confirmation"
        if (sessionState.syncRequested) return "Starting sync"
        if (phase === "scanning") return sessionState.pending ? "Applying your choices" : "Working"
        if (phase === "syncing") return "Syncing · " + (sessionState.progress ? sessionState.progress.percent : 0) + "%"
        if (phase === "cancelling") return "Stopping safely"
        if (phase === "complete") return sessionState.items.length ? "Synced" : "Already in sync"
        if (phase === "partial") return "Partly synced"
        if (phase === "cancelled") return "Stopped"
        if (phase === "error") return "Unison failed"
        const changes = tally.total + (tally.total === 1 ? " change" : " changes")
        return tally.unresolved ? changes + " · " + tally.unresolved + " need you" : changes
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
        if (view === "home") return "↑↓ move · ⏎ scan · N new profile · Esc close"
        if (view === "record") return "↑↓ move · ⏎ details · ⌫ back"
        if (view === "create") return "⏎ next field · Esc cancel"
        if (finished) return "R scan again · ⏎ / ⌫ done · V output"
        if (syncing) return "C stop · V output"
        if (phase === "warning") return "C stop · V output"
        return "←→ direction · X hold · U reset · D diff · G sync · C stop"
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
        contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(780))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: root.creating && root.view === "create"
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }
            onMoveRequested: function(dx, dy) { root.move(dx, dy) }
            onActivateRequested: root.activate()
            onDeleteRequested: if (root.cursorActive && root.cursorRow()) root.setDirection(root.cursorRow(), "skip")
            onTextKey: function(text) { root.textKey(text) }

            Flickable {
                id: panelFlick
                anchors.fill: parent
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

                    // ---- hero ----------------------------------------------
                    Item {
                        id: heroBox
                        width: parent.width
                        implicitHeight: hero.implicitHeight
                        // Reached from the hero's trailingControl, whose `root` is PanelHero.
                        readonly property string actionGlyph: root.view === "home" ? Model.glyph.added
                            : (root.view !== "session" ? Model.glyph.back : (root.host.busy ? Model.glyph.stop : Model.glyph.close))
                        readonly property string actionTip: root.view === "home" ? "New profile"
                            : (root.view !== "session" ? "Back" : (root.host.busy ? "Stop session" : "Done"))
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

                    // ---- home ----------------------------------------------
                    Column {
                        visible: root.view === "home"
                        width: parent.width
                        spacing: Style.space(12)

                        PanelSeparator { foreground: root.foreground }

                        Column {
                            width: parent.width
                            spacing: Style.space(4)
                            Repeater {
                                id: profileRepeater
                                model: root.view === "home" ? root.homeList.entries : []
                                Column {
                                    id: homeEntry
                                    required property var modelData
                                    required property int index
                                    width: parent.width
                                    topPadding: modelData.header && index > 0 ? Style.space(10) : 0
                                    bottomPadding: modelData.header ? Style.space(4) : 0
                                    PairHeader {
                                        visible: homeEntry.modelData.header
                                        width: parent.width
                                        group: homeEntry.modelData.header ? homeEntry.modelData.group : null
                                    }
                                    ProfileRow {
                                        visible: !homeEntry.modelData.header
                                        width: parent.width
                                        name: homeEntry.modelData.header ? "" : homeEntry.modelData.name
                                        profile: homeEntry.modelData.header ? null : homeEntry.modelData.profile
                                        rowIndex: homeEntry.modelData.header ? -1 : homeEntry.modelData.index
                                    }
                                }
                            }
                            ListRow {
                                id: newProfileRow
                                width: parent.width
                                rowIndex: root.homeList.rows.length
                                glyphText: Model.glyph.added
                                title: "New profile"
                                caption: root.host.profiles.length ? "Pair two folders, a drive, or an SSH host" : "No profiles in " + root.host.profileDirectory + " yet. Start here."
                                onActivated: root.openCreate()
                            }
                        }

                        PanelSeparator { visible: root.recent.length > 0; foreground: root.foreground }
                        PanelSectionHeader { visible: root.recent.length > 0; text: "RECENT"; foreground: root.foreground; fontFamily: root.family }
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
                                    rowIndex: root.homeList.rows.length + 1 + index
                                    glyphText: Model.statusGlyph(modelData.phase)
                                    glyphColor: modelData.phase === "error" || modelData.phase === "partial" ? root.urgent : root.foreground
                                    title: (root.profileNamed(modelData.profile) || { label: modelData.profile }).label
                                    caption: Model.runSummary(modelData)
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

                        BridgeCard {
                            width: parent.width
                            leftSide: root.leftReplica
                            rightSide: root.rightReplica
                        }

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
                            visible: root.view === "record" || (root.finished && root.shownItems.length > 0)
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
                                            visible: entryBox.modelData.header && entryBox.modelData.pending > 0
                                            text: visible ? entryBox.modelData.pending + " OPEN" : ""
                                            foreground: root.urgent
                                            color: root.urgent
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
                                hasCursor: actionRow.primaryHasCursor
                                fontFamily: root.family
                                enabled: root.finished || root.canSync
                                opacity: enabled ? 1 : 0.55
                                onHovered: function(isHovered) { if (isHovered && root.syncRowVisible) root.setCursor(root.plan.rows.length) }
                                onClicked: {
                                    if (!root.finished) { root.sync(); return }
                                    const name = root.sessionState.profile
                                    root.done()
                                    root.startScan(name)
                                }
                            }
                            Button {
                                width: (parent.width - parent.spacing) / 2
                                text: root.finished ? "Done" : (root.phase === "cancelling" ? "Stopping…" : "Stop")
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
                            text: root.showLog ? "Hide Unison output" : "Show Unison output"
                            fontFamily: root.family
                            fontSize: Style.font.bodySmall
                            onClicked: root.showLog = !root.showLog
                        }
                        Text {
                            visible: root.view === "session" && root.showLog
                            width: parent.width
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAnywhere
                            text: root.sessionState.tail.slice(-4000)
                            color: root.dim
                            font.family: root.family
                            font.pixelSize: Style.font.caption
                        }
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
    }

    // ---- components --------------------------------------------------------

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

    component ProfileRow: ListRow {
        id: profileRow
        property var profile: null
        property string name: ""
        readonly property var offline: Model.offlineReplica(profile)
        readonly property var last: profile ? profile.last : null

        glyphText: Model.glyph.folder
        glyphColor: root.dim
        title: name || (profile ? profile.label : "")
        caption: Model.profileScope(profile, name)
        trailing: last ? Model.relativeTime(last.finished, root.now) : "never synced"
        trailingGlyph: last ? Model.statusGlyph(last.phase) : ""
        trailingColor: last && (last.phase === "error" || last.phase === "partial") ? root.urgent : (last && last.phase === "complete" ? root.accent : root.dim)
        contentOpacity: offline ? 0.7 : 1
        enabled: !root.host.busy
        onActivated: if (profile) root.startScan(profile.name)
    }

    // "Home ⇄ PERSONAL_SSD /Gator" above the profiles that share those roots.
    component PairHeader: Item {
        id: pair
        property var group: null
        readonly property bool offline: !!(group && group.offline)
        implicitHeight: pairRow.implicitHeight

        RowLayout {
            id: pairRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(6)

            PairSide { replica: pair.group ? pair.group.left : null }
            Text { text: Model.glyph.swap; color: root.dim; font.family: root.family; font.pixelSize: Style.font.bodySmall }
            PairSide { replica: pair.group ? pair.group.right : null; Layout.fillWidth: true }
            PanelSectionHeader {
                visible: text !== ""
                text: pair.offline ? "NOT CONNECTED" : (pair.group && pair.group.right.kind === "ssh" ? "SSH" : "")
                foreground: pair.offline ? root.urgent : root.foreground
                color: pair.offline ? root.urgent : Qt.darker(root.foreground, 1.4)
                fontFamily: root.family
            }
        }
    }

    component PairSide: Row {
        id: side
        property var replica: null
        spacing: Style.space(5)
        Text {
            text: Model.replicaGlyph(side.replica)
            color: side.replica && side.replica.online === false ? root.urgent : root.foreground
            font.family: root.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: side.replica ? side.replica.name.toUpperCase() : ""
            color: root.foreground
            font.family: root.family
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: !!side.replica && side.replica.path !== "~" && side.replica.path !== "/" && side.replica.kind !== "local"
            text: side.replica ? side.replica.path : ""
            color: root.dim
            font.family: root.family
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
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
                Button { width: (parent.width - parent.spacing) / 2; text: "Stop"; bordered: true; fontFamily: root.family; onClicked: root.stop() }
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
                    text: change.item ? (change.item.done ? Model.glyph.check : Model.kindGlyph(change.item)) : ""
                    color: change.item && change.item.done ? root.accent : root.dim
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
                        width: parent.width - Style.space(26)
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
                    Button { text: "Diff"; bordered: true; fontFamily: root.family; fontSize: Style.font.bodySmall; onClicked: if (change.item) root.inspect(change.item) }
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
                    visible: change.open && root.sessionState.detailsPath === change.item.path && root.sessionState.details !== ""
                    width: parent.width - Style.space(26)
                    textFormat: Text.PlainText
                    wrapMode: Text.WrapAnywhere
                    text: visible ? root.sessionState.details.slice(-6000) : ""
                    color: root.foreground
                    opacity: 0.85
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                }
            }
        }
    }
}
