pragma Singleton

import QtQuick
import Quickshell

Singleton {
    id: root

    signal openStateRequested(bool open)
    signal refreshRequested
    signal copyResult(bool ok, string reason, string label, bool toast)
    signal clearProblem(string reason)

    property int _seq: 0
    function newId(): string { _seq += 1; return "widget-" + _seq; }

    property int shownCount: 0
    readonly property bool popoutShown: shownCount > 0
    property var _shown: new Set()

    function setShown(id: string, shown: bool): void {
        if (shown) _shown.add(id); else _shown.delete(id);
        shownCount = _shown.size;
    }

    function toggle(): void { openStateRequested(!popoutShown); }
    function open(): void { openStateRequested(true); }
    function close(): void { openStateRequested(false); }

    function copy(code: string, clearSec: int, label: string, toast: bool): void { clipboard.copy(code, clearSec, label, toast); }
    function clearClipboardIfOurs(): void { clipboard.clearIfOurs(); }

    Clipboard {
        id: clipboard
        onCopyResult: (ok, reason, label, toast) => root.copyResult(ok, reason, label, toast)
        onClearProblem: reason => root.clearProblem(reason)
    }
}
