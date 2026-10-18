import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "."

Scope {
    id: root

    property string status: ""

    property string _clipboardCode: ""
    property string _pendingCopy: ""
    property string _pendingCheck: ""
    property int _gen: 0
    property int _checkGen: -1
    property var _queued: null

    function copy(code: string, clearSec: int): void {
        code = String(code || "").replace(/\s+/g, "");
        if (!Model.isCode(code)) return;
        if (copyProcess.running || clearProcess.running) {
            _queued = { code: code, clearSec: clearSec };
            return;
        }
        _start(code, clearSec);
    }

    function clearIfOurs(): void {
        if (!_clipboardCode || clipboardCheck.running || !ProtonPaths.ready) return;
        if (!Model.isCode(_clipboardCode)) { _clipboardCode = ""; return; }
        _pendingCheck = _clipboardCode;
        _checkGen = _gen;
        clipboardCheck.command = ["/bin/sh", ProtonPaths.clipcheck];
        clipboardCheck.stdinEnabled = true;
        clipboardCheck.running = true;
    }

    function _start(code: string, clearSec: int): void {
        _gen += 1;
        _pendingCopy = code;
        copyProcess.command = ["wl-copy", "--sensitive"];
        copyProcess.stdinEnabled = true;
        copyProcess.running = true;
        _clipboardCode = code;
        if (clearSec > 0) {
            clipboardClearTimer.interval = Math.min(clearSec, 600) * 1000;
            clipboardClearTimer.restart();
        } else {
            clipboardClearTimer.stop();
        }
    }

    function _drain(): void {
        if (!_queued || copyProcess.running || clearProcess.running) return;
        var next = _queued;
        _queued = null;
        _start(next.code, next.clearSec);
    }

    Process {
        id: copyProcess
        stdinEnabled: false
        onStarted: {
            write(root._pendingCopy);
            root._pendingCopy = "";
            stdinEnabled = false;
        }
        onExited: {
            root._pendingCopy = "";
            stdinEnabled = false;
            root._drain();
        }
    }

    Timer {
        id: clipboardClearTimer
        interval: 20000
        onTriggered: root.clearIfOurs()
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
            var result = clipboardCheckOut.text.trim();
            var current = root._checkGen === root._gen;
            root.status = result;
            if (current && result === "match") {
                clearProcess.command = ["wl-copy", "--clear"];
                clearProcess.running = true;
            }
            if (current) root._clipboardCode = "";
            root._checkGen = -1;
        }
    }

    Timer { interval: 10000; running: clipboardCheck.running; onTriggered: clipboardCheck.running = false }
    Process { id: clearProcess; onExited: root._drain() }
}
