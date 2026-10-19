import QtQuick
import QtQuick.Effects
import Caelestia
import Caelestia.Config
import qs.components
import qs.services
import "."

Item {
    id: root

    property var screen
    property var popouts

    readonly property string widgetId: "protonAuthenticator"
    property string _key: ""
    readonly property bool active: popouts ? (popouts.currentName === widgetId && popouts.hasCurrent === true) : false

    implicitWidth: 32
    implicitHeight: 32

    onActiveChanged: if (_key) ProtonBridge.setShown(_key, active)
    Component.onCompleted: {
        _key = ProtonBridge.newId();
        ProtonBridge.setShown(_key, active);
    }
    Component.onDestruction: ProtonBridge.setShown(_key, false)

    function _centerAlongBar(): real {
        var p = root.mapToItem(null, root.width / 2, root.height / 2);
        var vertical = Config.bar.position === "left" || Config.bar.position === "right";
        return vertical ? p.y : p.x;
    }

    function setOpen(open: bool): void {
        if (!popouts) return;
        if (open) popouts.currentCenter = _centerAlongBar();
        popouts.currentName = open ? widgetId : "";
        popouts.hasCurrent = open;
    }

    function handleHover(_pos, _isHorizontal, shellPopouts): void {
        var p = shellPopouts ?? popouts;
        if (!p || p.currentName !== widgetId || p.hasCurrent !== true) return;
        p.currentCenter = _centerAlongBar();
    }

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
