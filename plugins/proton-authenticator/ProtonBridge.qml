pragma Singleton

import QtQuick
import Quickshell

Singleton {
    id: root

    signal openStateRequested(bool open)
    signal refreshRequested

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

    function copy(code: string, clearSec: int): void { clipboard.copy(code, clearSec); }
    function clearClipboardIfOurs(): void { clipboard.clearIfOurs(); }

    Clipboard { id: clipboard }
}
