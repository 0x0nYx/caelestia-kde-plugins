pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtCore
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.services.api
import "Model.js" as Model
import "."

Item {
    id: root


    Settings {
        id: cfg
        category: "Plugin_proton-authenticator"
        property string sortMode: "recent"
        property bool closeOnCopy: true
        property bool toastOnCopy: true
        property int clipboardClearSec: 20
        property bool demoMode: false
    }

    readonly property string sortMode: ["recent", "alpha", "vault"].indexOf(String(cfg.sortMode)) >= 0 ? String(cfg.sortMode) : "recent"
    readonly property bool closeOnCopy: cfg.closeOnCopy
    readonly property bool toastOnCopy: cfg.toastOnCopy
    readonly property int clipboardClearSec: {
        var n = parseInt(String(cfg.clipboardClearSec), 10);
        return (isFinite(n) && n >= 0) ? Math.min(n, 600) : 20;
    }

    readonly property bool opened: visible && ProtonBridge.popoutShown
    property string searchText: ""
    property int selectedIndex: 0
    property string copiedKey: ""
    property real nowSec: Date.now() / 1000

    property bool locked: true
    property string mode: "checking"
    property string unlockError: ""
    property bool unlockBusy: false
    property string _unlockSecret: ""
    property string _token: ""

    readonly property var unlockCmd: ({ create: "create", unlock: "verify", reset: "reset" })
    readonly property var unlockCmdNames: ["create", "verify", "reset"]
    readonly property var labels: ({
        checking: { title: qsTr("Enter unlock code"), placeholder: qsTr("Unlock code"), action: qsTr("Unlock"), toggle: "" },
        unlock: { title: qsTr("Enter unlock code"), placeholder: qsTr("Unlock code"), action: qsTr("Unlock"), toggle: qsTr("Forgot code?") },
        create: { title: qsTr("Create unlock code"), placeholder: qsTr("New code (6+ characters)"), action: qsTr("Set code"), toggle: "" },
        reset: { title: qsTr("Reset unlock code"), placeholder: qsTr("root password"), action: qsTr("Reset code"), toggle: qsTr("Back") }
    })[mode]

    function lock(): void {
        if (_token.length > 0 && ProtonPaths.ready) Quickshell.execDetached([ProtonPaths.unlock, "lock"]);
        _token = "";
        locked = true;
        unlockError = "";
        svc.cancel();
        _copyRequests = ({});
        forgetTimer.restart();
        if (mode === "reset") mode = "unlock";
        if (mode === "unlock" || mode === "create") return;
        unlockStatus();
    }

    function unlockStatus(): void {
        if (!ProtonPaths.ready || unlockProc.running) return;
        unlockProc.command = [ProtonPaths.unlock, "status"];
        unlockProc.stdinEnabled = false;
        unlockProc.running = true;
    }

    function submitUnlock(code: string, confirm: string): void {
        var cmd = unlockCmd[mode];
        if (!cmd || unlockBusy || !ProtonPaths.ready || unlockProc.running) return;
        if (mode === "create") {
            if (code.length < 6) { unlockError = qsTr("Use at least 6 characters"); return; }
            if (code !== confirm) { unlockError = qsTr("Codes don't match"); return; }
        } else if (code.length === 0) return;
        unlockError = "";
        unlockBusy = true;
        _unlockSecret = code;
        unlockProc.command = [ProtonPaths.unlock, cmd];
        unlockProc.stdinEnabled = true;
        unlockProc.running = true;
    }

    function _unlockDone(text: string): void {
        unlockBusy = false;
        var r = Model.parseUnlock(text);
        if (r.status === "set" || r.status === "unset") {
            mode = r.status === "set" ? "unlock" : "create";
            return;
        }
        if (r.status === "reset") {
            mode = "create";
            unlockError = "";
        } else if (r.status === "unlocked") {
            _token = r.token;
            mode = "unlock";
            locked = false;
            forgetTimer.stop();
            nowSec = Date.now() / 1000;
            svc.refresh();
            idleTimer.restart();
        } else if (r.status === "wait") {
            unlockError = qsTr("Too many attempts. Try again in %1 s").arg(r.waitSec || 30);
        } else if (r.status === "bad") {
            unlockError = mode === "reset" ? qsTr("Wrong password") : qsTr("Wrong code");
        } else if (r.status === "exists") {
            mode = "unlock";
            unlockError = qsTr("An unlock code is already set");
        } else if (r.status === "missing") {
            mode = "create";
            unlockError = qsTr("No unlock code is set. Create one");
        } else if (r.status === "invalid") {
            unlockError = qsTr("Use 6 to 128 characters");
        } else if (r.status === "unsafe") {
            unlockError = r.message ? qsTr("Unsafe state directory: %1").arg(r.message) : qsTr("Unsafe state directory");
        } else {
            unlockError = qsTr("Could not unlock");
        }
    }

    Process {
        id: unlockProc
        stdinEnabled: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._unlockDone(text)
        }
        onStarted: {
            var sub = command.length > 1 ? String(command[1]) : "";
            if (root._unlockSecret.length > 0 && root.unlockCmdNames.indexOf(sub) >= 0) write(root._unlockSecret + "\n");
            root._unlockSecret = "";
            stdinEnabled = false;
        }
    }

    Timer { id: idleTimer; interval: 45000; onTriggered: root.lock() }

    function close(): void { ProtonBridge.close(); }

    Connections {
        target: ProtonBridge
        function onRefreshRequested() { if (root.opened && !root.locked) svc.refresh(); }
        function onCopyResult(id, ok, reason, label, toast) { root._onCopyResult(id, ok); }
    }

    Component.onCompleted: loadPrefs()

    Component.onDestruction: {
        if (_token.length > 0 && ProtonPaths.ready) Quickshell.execDetached([ProtonPaths.unlock, "lock"]);
    }

    property var pins: ({})
    property var used: ({})
    property bool _prefsDirty: false
    property bool _prefsTouched: false
    property string prefsError: ""

    function _prefsReply(text: string): void {
        var t = String(text || "").trim();
        if (!t.length) { prefsError = ""; return; }
        try {
            const d = JSON.parse(t.length <= 4096 ? t : "");
            prefsError = (d && d.error) ? Model.errorHint(d.error) : "";
        } catch (e) {
            prefsError = "";
        }
    }

    function loadPrefs(): void {
        if (prefsRead.running || !ProtonPaths.ready) return;
        prefsRead.command = [ProtonPaths.prefs, "read"];
        prefsRead.running = true;
    }

    function savePrefs(): void {
        if (!ProtonPaths.ready) return;
        _prefsTouched = true;
        if (prefsWrite.running) { _prefsDirty = true; return; }
        _prefsDirty = false;
        prefsWrite.command = [ProtonPaths.prefs, "write"];
        prefsWrite.stdinEnabled = true;
        prefsWrite.running = true;
    }

    Process {
        id: prefsRead
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (root._prefsTouched) return;
                const raw = String(text || "").trim();
                if (!raw.length) {
                    root.prefsError = qsTr("Could not read saved pins and recents");
                    return;
                }
                try {
                    const d = JSON.parse(raw.length <= 262144 ? raw : "");
                    root.prefsError = (d && d.error) ? Model.errorHint(d.error) : "";
                    root.pins = (d && typeof d.pins === "object" && d.pins) ? d.pins : {};
                    root.used = (d && typeof d.used === "object" && d.used) ? d.used : {};
                } catch (e) {
                    root.prefsError = qsTr("Could not read saved pins and recents");
                    root.pins = {};
                    root.used = {};
                }
            }
        }
    }

    Process {
        id: prefsWrite
        stdinEnabled: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._prefsReply(text)
        }
        onStarted: {
            write(JSON.stringify({ pins: root.pins, used: root.used }) + "\n");
            stdinEnabled = false;
        }
        onExited: {
            stdinEnabled = false;
            if (root._prefsDirty) root.savePrefs();
        }
    }

    function togglePin(entry): void {
        var key = Model.entryKey(entry);
        if (!key) return;
        var next = Object.assign({}, pins);
        if (next[key]) delete next[key]; else next[key] = true;
        pins = next;
        savePrefs();
    }

    function markUsed(entry): void {
        var key = Model.entryKey(entry);
        if (!key) return;
        var next = Object.assign({}, used);
        next[key] = Math.floor(Date.now() / 1000);
        used = next;
        savePrefs();
    }

    readonly property var rows: Model.rankEntries(svc.result.entries, searchText, pins, used, sortMode)
    readonly property var selectedRow: rows.length ? rows[Math.min(selectedIndex, rows.length - 1)] : null

    readonly property string statusLine: {
        if (svc.refreshing && svc.result.entries.length === 0) return qsTr("Loading…");
        if (!svc.result.ok && svc.result.error) return Model.errorHint(svc.result.error);
        if (rows.length === 0) return searchText.length ? qsTr("No matches") : qsTr("No accounts");
        if (svc.result.skipped.length > 0)
            return qsTr("%n account(s) could not be read: %1", "", svc.result.skipped.length).arg(svc.result.skipped.slice(0, 3).join(", "));
        if (svc.result.warning === "FALLBACK_KEY")
            return qsTr("Proton Authenticator is using its unprotected fallback key. Open it and choose “Secure now”.");
        if (prefsError.length > 0) return qsTr("Pins and recents are not being saved. %1").arg(prefsError);
        return "";
    }

    onSearchTextChanged: { selectedIndex = 0; if (opened && !locked) idleTimer.restart(); }

    function moveCursor(dy: int): void {
        if (rows.length === 0) return;
        selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + dy));
    }

    function copySelected(): void {
        var row = selectedRow;
        if (!row) return;
        var st = Model.codeState(row.entry, nowSec);
        copyCode(row.entry, st.code);
    }

    function copyCode(entry, code): void {
        if (locked) return;
        code = String(code || "").replace(/\s+/g, "");
        if (!Model.isCode(code)) return;
        var id = ProtonBridge.copy(code, clipboardClearSec, String(entry.issuer || qsTr("Account")), toastOnCopy);
        if (id > 0) _copyRequests[id] = { key: Model.entryKey(entry), entry: entry };
    }

    property var _copyRequests: ({})

    function _onCopyResult(id: int, ok: bool): void {
        var request = _copyRequests[id];
        if (request) delete _copyRequests[id];
        if (!ok || !request) return;
        copiedKey = request.key;
        markUsed(request.entry);
        if (closeOnCopy) closeAfterCopy.restart(); else copiedTimer.restart();
    }

    function openApp(): void {
        Quickshell.execDetached(["proton-authenticator"]);
        close();
    }

    onOpenedChanged: {
        if (opened) {
            forgetTimer.stop();
            selectedIndex = 0;
            nowSec = Date.now() / 1000;
            if (locked) unlockStatus();
            else { svc.refresh(); idleTimer.restart(); }
        } else {
            idleTimer.stop();
            lock();
            closeAfterCopy.stop();
            copiedKey = "";

            forgetTimer.restart();
        }
    }

    Service {
        id: svc
        demoMode: cfg.demoMode
        token: root._token
    }

    Connections {
        target: svc
        function onResultChanged() { if (svc.result.error && svc.result.error.code === "LOCKED" && root.opened && !root.locked) root.lock(); }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.opened
        onTriggered: {
            root.nowSec = Date.now() / 1000;
            svc.tick(root.nowSec);
        }
    }

    onSelectedIndexChanged: if (opened && !locked) idleTimer.restart()

    Timer { id: copiedTimer; interval: 1200; onTriggered: root.copiedKey = "" }
    Timer { id: closeAfterCopy; interval: 180; onTriggered: root.close() }
    Timer { id: forgetTimer; interval: 260; onTriggered: svc.forget() }

    implicitWidth: 380
    implicitHeight: (shownLocked ? Math.max(content.implicitHeight, lockColumn.implicitHeight) : content.implicitHeight)
        + Tokens.padding.extraLarge * 2

    property bool shownLocked: true
    Binding {
        target: root
        property: "shownLocked"
        value: root.locked
        when: root.opened
    }

    property real lockAmt: shownLocked ? 1 : 0
    Behavior on lockAmt { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    MouseArea { anchors.fill: parent }

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: Tokens.padding.extraLarge
        spacing: Tokens.spacing.large

        enabled: !root.locked
        layer.enabled: root.lockAmt > 0.001
        layer.effect: MultiEffect {
            blurEnabled: true
            blurMax: 64
            blur: root.lockAmt
            saturation: -0.3 * root.lockAmt
            brightness: -0.08 * root.lockAmt
        }

        StyledTextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: qsTr("Search accounts")
            leadingIcon: "search"
            focus: root.opened && !root.locked
            enabled: !root.locked
            onTextChanged: root.searchText = text

            Connections {
                target: root
                function onOpenedChanged() {
                    if (root.opened && !root.locked) {
                        searchField.text = "";
                        searchField.forceActiveFocus();
                    }
                }
            }

            Keys.onPressed: event => {
                const ctrl = event.modifiers & Qt.ControlModifier;
                if (event.key === Qt.Key_Escape) root.close();
                else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_J)) root.moveCursor(1);
                else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) root.moveCursor(-1);
                else if (event.key === Qt.Key_PageDown) root.moveCursor(5);
                else if (event.key === Qt.Key_PageUp) root.moveCursor(-5);
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.copySelected();
                else if (ctrl && event.key === Qt.Key_P) { if (root.selectedRow) root.togglePin(root.selectedRow.entry); }
                else return;
                event.accepted = true;
            }
        }

        RowLayout {
            Layout.fillWidth: true
            StyledText {
                Layout.fillWidth: true
                text: root.searchText.length ? qsTr("Results") : qsTr("Accounts")
                color: Colours.palette.m3primary
                font: Tokens.font.label.small
            }
            StyledText {
                visible: root.rows.length > 0
                text: String(root.rows.length)
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: text.length > 0
            text: root.statusLine
            color: (!svc.result.ok && svc.result.error) ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            wrapMode: Text.WordWrap
        }

        Flickable {
            id: listFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.preferredHeight: Math.min(listColumn.implicitHeight, 420)
            visible: root.rows.length > 0
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Connections {
                target: root
                function onSelectedIndexChanged() {
                    const item = rep.itemAt(root.selectedIndex);
                    if (!item) return;
                    if (item.y < listFlick.contentY) listFlick.contentY = item.y;
                    else if (item.y + item.height > listFlick.contentY + listFlick.height)
                        listFlick.contentY = item.y + item.height - listFlick.height;
                }
            }

            ColumnLayout {
                id: listColumn
                width: listFlick.width
                spacing: Tokens.spacing.extraSmall

                Repeater {
                    id: rep
                    model: root.rows
                    delegate: AccountRow {
                        Layout.fillWidth: true
                        nowSec: root.nowSec
                        masked: root.shownLocked
                        selected: index === root.selectedIndex
                        copied: root.copiedKey === Model.entryKey(entry)
                        onHovered: root.selectedIndex = index
                        onCopyRequested: root.copyCode(entry, st.code)
                        onPinToggled: root.togglePin(entry)
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: qsTr("↵ copy  ·  ^P pin  ·  esc close")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.small
        }

        TextButton {
            Layout.fillWidth: true
            text: qsTr("Open Proton Authenticator")
            onClicked: root.openApp()
        }
    }

    Item {
        id: lockLayer
        anchors.fill: parent
        visible: root.lockAmt > 0.001
        opacity: root.lockAmt

        Rectangle {
            anchors.fill: parent
            radius: Tokens.rounding.extraLarge
            color: Colours.palette.m3surface
            opacity: 0.35
        }

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: lockColumn
            anchors.centerIn: parent
            width: parent.width - Tokens.padding.extraLarge * 4
            spacing: Tokens.spacing.medium

            MaterialIcon {
                Layout.alignment: Qt.AlignHCenter
                text: "lock"
                fill: 1
                color: Colours.palette.m3primary
                font.pointSize: 28
            }

            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: root.labels.title
                font: Tokens.font.title.small
            }

            StyledTextField {
                id: codeField
                Layout.fillWidth: true
                visible: root.mode !== "checking"
                echoMode: TextInput.Password
                placeholderText: root.labels.placeholder
                leadingIcon: "key"
                focus: root.opened && root.locked
                onAccepted: root.mode === "create" ? confirmField.forceActiveFocus() : root.submitUnlock(text, "")
                Keys.onEscapePressed: root.close()

                Connections {
                    target: root
                    function onLockedChanged() { codeField.text = ""; confirmField.text = ""; if (root.locked) codeField.forceActiveFocus(); }
                    function onOpenedChanged() { if (root.opened) { codeField.text = ""; confirmField.text = ""; codeField.forceActiveFocus(); } }
                    function onModeChanged() { codeField.text = ""; confirmField.text = ""; if (root.opened && root.locked) codeField.forceActiveFocus(); }
                }
            }

            StyledTextField {
                id: confirmField
                Layout.fillWidth: true
                visible: root.mode === "create"
                echoMode: TextInput.Password
                placeholderText: qsTr("Repeat code")
                leadingIcon: "key"
                onAccepted: root.submitUnlock(codeField.text, text)
                Keys.onEscapePressed: root.close()
            }

            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                text: root.unlockError.length > 0 ? root.unlockError : " "
                color: Colours.palette.m3error
                font: Tokens.font.label.small
            }

            TextButton {
                Layout.fillWidth: true
                visible: root.mode !== "checking"
                enabled: !root.unlockBusy
                text: root.labels.action
                onClicked: root.submitUnlock(codeField.text, confirmField.text)
            }

            TextButton {
                Layout.fillWidth: true
                visible: root.labels.toggle.length > 0
                text: root.labels.toggle
                onClicked: { root.mode = root.mode === "reset" ? "unlock" : "reset"; root.unlockError = ""; codeField.text = ""; codeField.forceActiveFocus(); }
            }
        }
    }
}
