pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Lives for the whole shell session, so a copied code is still cleared from the
// clipboard after the popout has been closed (and possibly destroyed), and so the
// plugin-level shortcut / IPC handlers in main.qml can reach the bar widget.
Singleton {
    id: root

    // One request, one target state: every bar widget applies the same value, so two
    // monitors can never fight each other (one opening, the other closing).
    signal openStateRequested(bool open)
    signal refreshRequested

    // How many bar widgets currently see our popout as shown (kept by BarWidget.qml).
    property int shownCount: 0
    readonly property bool popoutShown: shownCount > 0

    function toggle(): void { openStateRequested(!popoutShown); }
    function open(): void { openStateRequested(true); }
    function close(): void { openStateRequested(false); }

    readonly property string pluginDir: {
        var s = String(Qt.resolvedUrl("."));
        if (s.indexOf("file://") === 0) s = s.substring(7);
        if (s.length && s.charAt(s.length - 1) !== "/") s += "/";
        return s;
    }

    property string _clipboardCode: ""
    property string _pendingCopy: ""
    property string _pendingCheck: ""
    property string _checkingCode: ""

    function copy(code: string, clearSec: int): void {
        code = String(code || "").replace(/\s+/g, "");
        if (!Model.isCode(code)) return;
        _pendingCopy = code;
        copyProcess.command = ["wl-copy", "--sensitive"];
        copyProcess.stdinEnabled = true;
        copyProcess.running = true;
        _clipboardCode = code;
        if (clearSec > 0) {
            clipboardClearTimer.interval = Math.min(clearSec, 600) * 1000;
            clipboardClearTimer.restart();
        }
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
        interval: 20000
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
}
