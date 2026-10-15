pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import QtCore
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.services.api
import "Model.js" as Model

Item {
    id: root

    readonly property string pluginId: "proton-authenticator"

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
    readonly property bool closeOnCopy: Model.asBool(cfg.closeOnCopy)
    readonly property bool toastOnCopy: Model.asBool(cfg.toastOnCopy)
    readonly property int clipboardClearSec: {
        var n = parseInt(String(cfg.clipboardClearSec), 10);
        return (isFinite(n) && n >= 0) ? Math.min(n, 600) : 20;
    }

    property bool opened: false
    property string searchText: ""
    property int selectedIndex: 0
    property string copiedKey: ""
    property real nowSec: Date.now() / 1000

    property string _clipboardCode: ""
    property string _pendingCopy: ""
    property string _pendingCheck: ""
    property string _checkingCode: ""

    readonly property string pluginDir: {
        var s = String(Qt.resolvedUrl("."));
        if (s.indexOf("file://") === 0) s = s.substring(7);
        if (s.length && s.charAt(s.length - 1) !== "/") s += "/";
        return s;
    }

    // unlock code
    property bool locked: true
    property string unlockMode: "loading"
    property string unlockError: ""
    property bool unlockBusy: false
    property string _unlockSecret: ""
    property string _token: ""
    property bool forgotMode: false
    property string _unlockOp: ""
    readonly property string unlockToolPath: pluginDir + "bin/protonauth-unlock"
    readonly property bool unlockReady: unlockToolPath.endsWith("/bin/protonauth-unlock")

    function lock(): void {
        if (_token.length > 0 && unlockReady) Quickshell.execDetached([unlockToolPath, "lock"]);
        _token = "";
        forgotMode = false;
        locked = true;
        unlockError = "";
        if (unlockMode === "enter" || unlockMode === "create") return;
        unlockStatus();
    }

    function unlockStatus(): void {
        if (!unlockReady || unlockProc.running) return;
        _unlockOp = "status";
        unlockProc.command = [unlockToolPath, "status"];
        unlockProc.stdinEnabled = false;
        unlockProc.running = true;
    }

    function submitUnlock(code: string, confirm: string): void {
        if (unlockBusy || !unlockReady || unlockProc.running) return;
        if (unlockMode === "create" && !forgotMode) {
            if (code.length < 6) { unlockError = qsTr("Use at least 6 characters"); return; }
            if (code !== confirm) { unlockError = qsTr("Codes don't match"); return; }
        } else if (code.length === 0) return;
        unlockError = "";
        unlockBusy = true;
        _unlockSecret = code;
        _unlockOp = forgotMode ? "reset" : (unlockMode === "create" ? "create" : "verify");
        unlockProc.command = [unlockToolPath, _unlockOp];
        unlockProc.stdinEnabled = true;
        unlockProc.running = true;
    }

    function _unlockDone(out: string): void {
        unlockBusy = false;
        out = out.trim();
        if (_unlockOp === "status") {
            unlockMode = out === "set" ? "enter" : "create";
            return;
        }
        if (out === "reset") {
            forgotMode = false;
            unlockMode = "create";
            unlockError = "";
        } else if (out.indexOf("ok ") === 0 && out.length === 67) {
            _token = out.substring(3);
            unlockMode = "enter";
            locked = false;
            nowSec = Date.now() / 1000;
            svc.refresh();
            idleTimer.restart();
        } else if (out.indexOf("wait ") === 0) {
            unlockError = qsTr("Too many attempts. Try again in %1 s").arg(parseInt(out.substring(5), 10) || 30);
        } else if (out === "bad") {
            unlockError = forgotMode ? qsTr("Wrong password") : qsTr("Wrong code");
        } else {
            unlockError = qsTr("Could not unlock");
        }
    }

    Process {
        id: unlockProc
        stdinEnabled: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._unlockDone(text.length <= 256 ? text : "")
        }
        onStarted: {
            if (root._unlockOp !== "status") write(root._unlockSecret + "\n");
            root._unlockSecret = "";
            stdinEnabled = false;
        }
    }

    // Relpck after inactivity
    Timer { id: idleTimer; interval: 45000; onTriggered: root.lock() }

    function open(): void { opened = true; }
    function close(): void { opened = false; }
    function toggle(): void { opened = !opened; }

    IpcHandler {
        target: "protonAuthenticator"
        function open(): void { root.open(); }
        function close(): void { root.close(); }
        function toggle(): void { root.toggle(); }
        function refresh(): string { svc.refresh(); return "ok"; }
        function clearClipboard(): string { root.clearClipboardIfOurs(); return "ok"; }
    }

    Component.onCompleted: {
        loadPrefs();
        CaelestiaApi.shortcuts.register("authenticator", "Open Proton Authenticator codes", "Meta+Ctrl+U", root.toggle);
    }

    property var pins: ({})
    property var used: ({})
    property bool _prefsDirty: false
    property bool _prefsTouched: false
    readonly property string prefsToolPath: pluginDir + "bin/protonauth-prefs"

    readonly property bool prefsReady: prefsToolPath.endsWith("/bin/protonauth-prefs")

    function loadPrefs(): void {
        if (prefsRead.running || !prefsReady) return;
        prefsRead.command = [prefsToolPath, "read"];
        prefsRead.running = true;
    }

    function savePrefs(): void {
        if (!prefsReady) return;
        _prefsTouched = true;
        if (prefsWrite.running) { _prefsDirty = true; return; }
        _prefsDirty = false;
        prefsWrite.command = [prefsToolPath, "write"];
        prefsWrite.stdinEnabled = true;
        prefsWrite.running = true;
    }

    Process {
        id: prefsRead
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (root._prefsTouched) return;
                try {
                    var d = JSON.parse(text.length <= 262144 ? text : "");
                    root.pins = (d && typeof d.pins === "object" && d.pins) ? d.pins : {};
                    root.used = (d && typeof d.used === "object" && d.used) ? d.used : {};
                } catch (e) {
                    root.pins = {};
                    root.used = {};
                }
            }
        }
    }

    Process {
        id: prefsWrite
        stdinEnabled: false
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

    readonly property var rows: Model.rankEntries(svc.entries, searchText, pins, used, sortMode)
    readonly property var selectedRow: rows.length ? rows[Math.min(selectedIndex, rows.length - 1)] : null

    readonly property string statusLine: {
        if (svc.refreshing && svc.entries.length === 0) return qsTr("Loading…");
        if (!svc.ok && svc.error) return Model.errorHint(svc.error);
        if (rows.length === 0) return searchText.length ? qsTr("No matches") : qsTr("No accounts");
        if (svc.skipped.length > 0)
            return qsTr("%n account(s) could not be read: %1", "", svc.skipped.length).arg(svc.skipped.slice(0, 3).join(", "));
        if (svc.warning === "FALLBACK_KEY")
            return qsTr("Proton Authenticator is using its unprotected fallback key. Open it and choose “Secure now”.");
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
        copiedKey = Model.entryKey(entry);
        markUsed(entry);

        _pendingCopy = code;
        copyProcess.command = ["wl-copy", "--sensitive"];
        copyProcess.stdinEnabled = true;
        copyProcess.running = true;
        _clipboardCode = code;
        if (clipboardClearSec > 0) clipboardClearTimer.restart();
        if (toastOnCopy) {
            var label = String(entry.issuer || qsTr("Account"));
            Toaster.toast(qsTr("Copied code"), label, "key", Toast.Success);
        }
        if (closeOnCopy) closeAfterCopy.restart(); else copiedTimer.restart();
    }

    function clearClipboardIfOurs(): void {
        if (!_clipboardCode || clipboardCheck.running) return;
        if (!Model.isCode(_clipboardCode)) { _clipboardCode = ""; return; }
        _pendingCheck = _clipboardCode;
        _checkingCode = _clipboardCode;
        clipboardCheck.command = ["/bin/sh", pluginDir + "bin/protonauth-clipcheck"];
        clipboardCheck.stdinEnabled = true;
        clipboardCheck.running = true;
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
        settings: ({ demoMode: cfg.demoMode })
        pluginDir: root.pluginDir
        token: root._token
    }

    Connections {
        target: svc
        function onErrorChanged() { if (svc.error && svc.error.code === "LOCKED" && root.opened && !root.locked) root.lock(); }
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

    Process {
        id: copyProcess
        stdinEnabled: false
        onStarted: {
            write(root._pendingCopy);
            root._pendingCopy = "";
            stdinEnabled = false;
        }
        onExited: { root._pendingCopy = ""; stdinEnabled = false; }
    }

    Timer {
        id: clipboardClearTimer
        interval: Math.max(1, root.clipboardClearSec) * 1000
        onTriggered: root.clearClipboardIfOurs()
    }

    Process {
        id: clipboardCheck
        stdinEnabled: false
        stdout: StdioCollector { id: clipboardCheckOut; waitForEnd: true }
        onStarted: {
            write(root._pendingCheck);
            root._pendingCheck = "";
            stdinEnabled = false;
        }
        onExited: {
            root._pendingCheck = "";
            stdinEnabled = false;
            var current = root._clipboardCode === root._checkingCode;
            if (current && clipboardCheckOut.text === "match\n") {
                clearProcess.command = ["wl-copy", "--clear"];
                clearProcess.running = true;
            }
            if (current) root._clipboardCode = "";
            root._checkingCode = "";
        }
    }

    Timer { interval: 10000; running: clipboardCheck.running; onTriggered: clipboardCheck.running = false }
    Process { id: clearProcess }

    PanelWindow {
        id: win

        readonly property string activeName: Kwin.cursorOutputName()
        screen: Quickshell.screens.find(s => s.name === activeName) ?? Quickshell.screens[0]

        visible: root.opened || card.slide > 0.001
        color: "transparent"
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "caelestia-authenticator"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        BackgroundEffect.blurRegion: Region {
            item: card
            radius: card.radius
        }

        readonly property var barWrapper: win.screen ? Visibilities.bars.get(win.screen.name) : null
        readonly property int barThickness: barWrapper ? barWrapper.visualThickness : 0
        readonly property string barPos: Config.bar.position
        readonly property int gap: Tokens.padding.large

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        StyledRect {
            id: card

            width: 380
            height: Math.min((shownLocked ? Math.max(content.implicitHeight, lockColumn.implicitHeight) : content.implicitHeight) + Tokens.padding.extraLarge * 2, win.height - win.barThickness - win.gap * 2)

            property real slide: root.opened ? 1 : 0
            Behavior on slide {
                NumberAnimation {
                    duration: root.opened ? 260 : 160
                    easing.type: root.opened ? Easing.OutCubic : Easing.InCubic
                }
            }
            readonly property real riseDistance: 32

            property bool shownLocked: true
            Binding {
                target: card
                property: "shownLocked"
                value: root.locked
                when: root.opened || card.slide <= 0.001
            }

            property real lockAmt: shownLocked ? 1 : 0
            Behavior on lockAmt { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            x: win.barPos === "left" ? win.barThickness + win.gap
                : win.barPos === "right" ? win.width - win.barThickness - win.gap - width
                : Math.round((win.width - width) / 2)
            readonly property real restY: win.barPos === "top" ? win.barThickness + win.gap
                : win.barPos === "bottom" ? win.height - win.barThickness - win.gap - height
                : Math.round((win.height - height) / 2)
            y: restY + (1 - slide) * riseDistance
            opacity: slide

            radius: Tokens.rounding.extraLarge

            color: Colours.tPalette ? Colours.tPalette.m3surface : Colours.palette.m3surface
            border.width: 1
            border.color: Colours.palette.m3outlineVariant
            clip: true

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: content
                anchors.fill: parent
                anchors.margins: Tokens.padding.extraLarge
                spacing: Tokens.spacing.large

                enabled: !root.locked
                layer.enabled: card.lockAmt > 0.001
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blurMax: 64
                    blur: card.lockAmt
                    saturation: -0.3 * card.lockAmt
                    brightness: -0.08 * card.lockAmt
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
                    color: (!svc.ok && svc.error) ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
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
                                masked: card.shownLocked
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
                visible: card.lockAmt > 0.001
                opacity: card.lockAmt

                Rectangle {
                    anchors.fill: parent
                    radius: card.radius
                    color: card.color
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
                        text: root.forgotMode ? qsTr("Reset unlock code")
                            : root.unlockMode === "create" ? qsTr("Create unlock code") : qsTr("Enter unlock code")
                        font: Tokens.font.title.small
                    }

                    StyledTextField {
                        id: codeField
                        Layout.fillWidth: true
                        visible: root.unlockMode !== "loading"
                        echoMode: TextInput.Password
                        placeholderText: root.forgotMode ? qsTr("root password")
                            : root.unlockMode === "create" ? qsTr("New code (6+ characters)") : qsTr("Unlock code")
                        leadingIcon: "key"
                        focus: root.opened && root.locked
                        onAccepted: (root.unlockMode === "create" && !root.forgotMode) ? confirmField.forceActiveFocus() : root.submitUnlock(text, "")
                        Keys.onEscapePressed: root.close()

                        Connections {
                            target: root
                            function onLockedChanged() { codeField.text = ""; confirmField.text = ""; if (root.locked) codeField.forceActiveFocus(); }
                            function onOpenedChanged() { if (root.opened) { codeField.text = ""; confirmField.text = ""; codeField.forceActiveFocus(); } }
                            function onForgotModeChanged() { codeField.text = ""; confirmField.text = ""; }
                            function onUnlockModeChanged() { codeField.text = ""; confirmField.text = ""; if (root.opened && root.locked) codeField.forceActiveFocus(); }
                        }
                    }

                    StyledTextField {
                        id: confirmField
                        Layout.fillWidth: true
                        visible: root.unlockMode === "create" && !root.forgotMode
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
                        visible: root.unlockMode !== "loading"
                        enabled: !root.unlockBusy
                        text: root.forgotMode ? qsTr("Reset code") : root.unlockMode === "create" ? qsTr("Set code") : qsTr("Unlock")
                        onClicked: root.submitUnlock(codeField.text, confirmField.text)
                    }

                    TextButton {
                        Layout.fillWidth: true
                        visible: root.unlockMode === "enter"
                        text: root.forgotMode ? qsTr("Back") : qsTr("Forgot code?")
                        onClicked: { root.forgotMode = !root.forgotMode; root.unlockError = ""; codeField.text = ""; codeField.forceActiveFocus(); }
                    }
                }
            }
        }
    }
}
