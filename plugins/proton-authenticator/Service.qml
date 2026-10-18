import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "."

Item {
    id: root

    property var settings: ({})
    property string token: ""

    property int window: 3

    property var result: Model.normalizeList(null)
    property bool refreshing: false

    property real refreshAt: Infinity

    readonly property bool demoMode: Model.asBool(settings ? settings.demoMode : false)

    property string _out: ""
    property bool _timedOut: false

    function _run(args) {
        if (listProcess.running) return

        if (!ProtonPaths.ready) return
        refreshing = true
        _out = ""
        _timedOut = false
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

    function forget() {
        result = Model.normalizeList(null)
        refreshAt = Infinity
    }

    function apply(exitCode, exitStatus) {
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
            onStreamFinished: root._out = text
        }
        onExited: (exitCode, exitStatus) => root.apply(exitCode, exitStatus)
    }

    Timer {
        interval: 30000
        running: listProcess.running
        onTriggered: { root._timedOut = true; listProcess.running = false }
    }
}
