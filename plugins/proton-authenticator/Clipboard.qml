import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "."

Scope {
    id: root

    signal copyResult(int id, bool ok, string reason, string label, bool toast)
    signal clearProblem(string reason)

    property string _clipboardCode: ""
    property string _pendingCopy: ""
    property string _pendingCheck: ""
    property int _gen: 0
    property int _checkGen: -1
    property int _nextId: 0
    property var _queue: []
    property var _request: null
    property bool _copying: false
    property bool _copyTimedOut: false
    property bool _checkTimedOut: false
    property bool _checking: false

    function copy(code: string, clearSec: int, label: string, toast: bool): int {
        code = String(code || "").replace(/\s+/g, "");
        if (!Model.isCode(code)) return 0;
        _nextId += 1;
        var request = { id: _nextId, code: code, clearSec: clearSec, label: label, toast: toast };
        if (copyProcess.running || clearProcess.running || _copying) {
            _queue.push(request);
            return request.id;
        }
        _start(request);
        return request.id;
    }

    function clearIfOurs(): void {
        if (!_clipboardCode || clipboardCheck.running || !ProtonPaths.ready) return;
        if (_copying || copyProcess.running || clearProcess.running || _queue.length > 0) return;
        if (!Model.isCode(_clipboardCode)) { _clipboardCode = ""; return; }
        _pendingCheck = _clipboardCode;
        _checkGen = _gen;
        _checkTimedOut = false;
        _checking = true;
        clipboardCheck.command = ["/bin/sh", ProtonPaths.clipcheck];
        clipboardCheck.stdinEnabled = true;
        clipboardCheck.running = true;
    }

    function _start(request): void {
        _gen += 1;
        _request = request;
        _pendingCopy = request.code;
        _copying = true;
        _copyTimedOut = false;
        copyWatchdog.restart();
        copyProcess.command = ["wl-copy", "--sensitive"];
        copyProcess.stdinEnabled = true;
        copyProcess.running = true;
        _clipboardCode = request.code;
        if (request.clearSec > 0) {
            clipboardClearTimer.interval = Math.min(request.clearSec, 600) * 1000;
            clipboardClearTimer.restart();
        } else {
            clipboardClearTimer.stop();
        }
    }

    function _finishCopy(ok: bool, reason: string): void {
        if (!_copying || !_request) return;
        _copying = false;
        copyWatchdog.stop();
        _pendingCopy = "";
        var request = _request;
        _request = null;
        if (!ok) {
            _clipboardCode = "";
            clipboardClearTimer.stop();
        }
        copyResult(request.id, ok, reason, request.label, request.toast);
        _drain();
    }

    function _checkDone(exitCode: int, exitStatus: int): void {
        if (!_checking) return;
        _checking = false;
        _pendingCheck = "";
        clipboardCheck.stdinEnabled = false;
        var result = clipboardCheckOut.text.trim();
        var current = _checkGen === _gen;
        if (result.indexOf("DEPS_MISSING") === 0) {
            clearProblem("WL_PASTE_MISSING");
        } else if (_checkTimedOut) {
            clearProblem("CHECK_TIMEOUT");
        } else if (exitCode !== 0 || exitStatus !== 0 || (result !== "match" && result !== "nomatch")) {
            clearProblem("CHECK_FAILED");
        } else if (current && result === "match") {
            clearProcess.command = ["wl-copy", "--clear"];
            clearProcess.running = true;
        }
        if (current) _clipboardCode = "";
        _checkGen = -1;
    }

    function _drain(): void {
        if (_queue.length === 0 || _copying || copyProcess.running || clearProcess.running) return;
        _start(_queue.shift());
    }

    Process {
        id: copyProcess
        stdinEnabled: false
        onStarted: {
            write(root._pendingCopy);
            root._pendingCopy = "";
            stdinEnabled = false;
        }
        onExited: (exitCode, exitStatus) => {
            stdinEnabled = false;
            var ok = exitCode === 0 && exitStatus === 0 && !root._copyTimedOut;
            root._finishCopy(ok, root._copyTimedOut ? "WL_COPY_TIMEOUT" : "WL_COPY_FAILED");
        }
    }

    Timer {
        id: copyWatchdog
        interval: 5000
        onTriggered: {
            root._copyTimedOut = true;
            if (copyProcess.running) copyProcess.running = false;
            root._finishCopy(false, "WL_COPY_TIMEOUT");
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
        onExited: (exitCode, exitStatus) => root._checkDone(exitCode, exitStatus)
    }

    Timer {
        interval: 10000
        running: clipboardCheck.running
        onTriggered: {
            root._checkTimedOut = true;
            clipboardCheck.running = false;
            root._checkDone(-1, -1);
        }
    }

    Process {
        id: clearProcess
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 || exitStatus !== 0) root.clearProblem("CLEAR_FAILED");
            root._drain();
        }
    }
}
