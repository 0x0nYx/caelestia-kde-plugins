pragma Singleton

import QtQuick
import Quickshell

Singleton {
    readonly property string dir: {
        var s = String(Qt.resolvedUrl("."));
        if (s.indexOf("file://") === 0) s = s.substring(7);
        if (s.length && s.charAt(s.length - 1) !== "/") s += "/";
        return s;
    }

    readonly property bool ready: dir.charAt(0) === "/"

    readonly property string list: dir + "bin/protonauth-list"
    readonly property string unlock: dir + "bin/protonauth-unlock"
    readonly property string prefs: dir + "bin/protonauth-prefs"
    readonly property string clipcheck: dir + "bin/protonauth-clipcheck"
}
