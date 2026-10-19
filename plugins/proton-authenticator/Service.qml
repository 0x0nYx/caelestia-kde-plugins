import QtQuick
import Quickshell.Io
import "Model.js" as Model
import "."

Item {
    id: root

    property bool demoMode: false
    property string token: ""

    property int window: 3

    property var result: Model.normalizeList(null)
    property bool refreshing: false

    property real refreshAt: Infinity

    property string _out: ""
    property bool _timedOut: false
    property int _epoch: 0
    property int _runEpoch: 0
    property bool _wantRefresh: false

    function _run(args) {
        if (listProcess.running) {
            if (_runEpoch !== _epoch) _wantRefresh = true
            return
        }

        if (!ProtonPaths.ready) return
        refreshing = true
        _out = ""
        _timedOut = false
        _runEpoch = _epoch
        listProcess.command = [ProtonPaths.list].concat(args)
        listProcess.stdinEnabled = true
        listProcess.running = true
    }

    function refresh() {
        _run(demoMode ? ["--demo", "--window", String(window)] : ["--window", String(window)])
    }

    function tick(nowSec) {
        if (!listProcess.running && nowSec >= refreshAt) refresh()
    }

    function cancel() {
        _epoch += 1
        _wantRefresh = false
        _out = ""
        refreshing = false
        if (listProcess.running) listProcess.running = false
    }

    function forget() {
        cancel()
        result = Model.normalizeList(null)
        refreshAt = Infinity
    }

    function apply(exitCode, exitStatus) {
        if (_runEpoch !== _epoch) {
            _out = ""
            refreshing = false
            if (_wantRefresh) { _wantRefresh = false; refresh() }
            return
        }
        result = Model.listResult(_out, exitCode, exitStatus !== 0, _timedOut)
        _out = ""

        refreshAt = result.ok ? Model.refreshAt(result.entries) : Date.now() / 1000 + 10
        refreshing = false
    }

    Process {
        id: listProcess
        running: false
        command: []
        stdinEnabled: false
        onStarted: { write(root.token + "\n"); stdinEnabled = false; }
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: if (root._runEpoch === root._epoch) root._out = text
        }
        onExited: (exitCode, exitStatus) => root.apply(exitCode, exitStatus)
    }

    Timer {
        interval: 30000
        running: listProcess.running
        onTriggered: { root._timedOut = true; listProcess.running = false }
    }
}
