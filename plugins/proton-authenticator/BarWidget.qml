import QtQuick
import QtQuick.Effects
import Caelestia
import Caelestia.Config
import qs.components
import qs.services
import "."

// Taskbar button. Clicking it (or the global shortcut) reveals Popout.qml in the
// shell's sliding popout container by setting popouts.currentName to this widget's id.
Item {
    id: root

    // ambient values the shell hands to widgets that declare them
    property var screen
    property var popouts

    readonly property string widgetId: "protonAuthenticator"   // must match barWidgets[].id
    // The shell closes a popout by clearing hasCurrent and leaves currentName set,
    // so "shown" needs both.
    readonly property bool active: popouts ? (popouts.currentName === widgetId && popouts.hasCurrent === true) : false

    implicitWidth: 32
    implicitHeight: 32

    onActiveChanged: ProtonBridge.shownCount += active ? 1 : -1
    Component.onDestruction: if (active) ProtonBridge.shownCount -= 1

    // Centre of this icon along the bar, measured in the window's own coordinates
    // (not the popout container's parent, which moves with the popout).
    function _centerAlongBar(): real {
        var p = root.mapToItem(null, root.width / 2, root.height / 2);
        var vertical = Config.bar.position === "left" || Config.bar.position === "right";
        return vertical ? p.y : p.x;
    }

    function setOpen(open: bool): void {
        if (!popouts) return;
        console.log("PA-BAR click open=" + open + " name=" + popouts.currentName + " has=" + popouts.hasCurrent + " active=" + active);
        if (open) popouts.currentCenter = _centerAlongBar();
        popouts.currentName = open ? widgetId : "";
        popouts.hasCurrent = open;
    }

    // The shell calls this while the pointer is over the icon. We only keep an
    // already-open popout in place (so moving the mouse doesn't close it); opening stays click-only.
    function handleHover(pos, isHorizontal, shellPopouts): void {
        var p = shellPopouts ?? popouts;
        if (!p || p.currentName !== widgetId || p.hasCurrent !== true) return;
        p.currentCenter = _centerAlongBar();
    }

    // Shortcut / IPC: act only on the bar of the screen the cursor is on.
    // The shell does not pass `screen` to widgets, but its popout container has one.
    function _isActiveScreen(): bool {
        var s = screen ?? (popouts ? popouts.screen : null);
        if (!s) return true;
        var name = Kwin.cursorOutputName();
        return !name || name === s.name;
    }

    Connections {
        target: ProtonBridge
        function onOpenStateRequested(open) { if (!open || root._isActiveScreen()) root.setOpen(open); }
    }

    StyledRect {
        anchors.fill: parent
        radius: Tokens.rounding.extraLarge
        color: Colours.palette.m3onSurface
        opacity: root.active ? 0.14 : (mouse.containsMouse ? 0.08 : 0)
        Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Image {
        id: glyph
        anchors.centerIn: parent
        width: 22
        height: 22
        source: Qt.resolvedUrl("icon.svg")
        sourceSize: Qt.size(64, 64)
        fillMode: Image.PreserveAspectFit
        smooth: true
        layer.enabled: true
        layer.effect: MultiEffect {
            brightness: 1
            colorization: 1
            colorizationColor: root.active ? Colours.palette.m3primary : Colours.palette.m3onSurface
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.setOpen(!root.active)
    }
}
