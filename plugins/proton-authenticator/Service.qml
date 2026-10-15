import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
    id: root

    property var settings: ({})
    property string pluginDir: ""
    property string token: ""

    property int window: 3

    property bool ok: false
    property var entries: []
    property var error: null

    property string warning: ""
    property var skipped: []
    property bool refreshing: false

    property real refreshAt: Infinity

    readonly property string helperPath: pluginDir + "bin/protonauth-list"

    readonly property bool demoMode: Model.asBool(settings ? settings.demoMode : false)

    property string _out: ""
    property bool _timedOut: false

    function _run(args) {
        if (listProcess.running) return

        if (!helperPath.endsWith("/bin/protonauth-list")) return
        refreshing = true
        _out = ""
        _timedOut = false
        listProcess.command = [helperPath].concat(args)
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
        entries = []
        refreshAt = Infinity
    }

    function apply() {
        var parsed = _timedOut
            ? { ok: false, entries: [], error: { code: "HELPER_TIMEOUT", message: "Helper timed out" } }
            : Model.parseList(_out)
        _out = ""
        ok = parsed.ok === true
        error = parsed.error || null
        warning = parsed.warning ? String(parsed.warning) : ""
        skipped = Array.isArray(parsed.skipped) ? parsed.skipped : []
        entries = parsed.entries || []

        refreshAt = ok ? Model.refreshAt(entries) : Date.now() / 1000 + 10
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
        onExited: root.apply()
    }

    Timer {
        interval: 30000
        running: listProcess.running
        onTriggered: { root._timedOut = true; listProcess.running = false }
    }
}
