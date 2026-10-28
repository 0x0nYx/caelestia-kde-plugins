pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services
import "."

Item {
    id: root

    property var screen
    property var popouts

    readonly property string widgetId: "wallpaperDepth"
    readonly property bool active: root.popouts ? (root.popouts.currentName === root.widgetId && root.popouts.hasCurrent === true) : false
    readonly property var kind: {
        if (DepthStore.setupState === "error")
            return {
                glyph: "error",
                color: Colours.palette.m3error
            };
        if (!DepthStore.ready)
            return {
                glyph: "layers_clear",
                color: Colours.palette.m3onSurfaceVariant
            };
        if (DepthStore.busy)
            return {
                glyph: "hourglass_top",
                color: Colours.palette.m3primary
            };
        return {
            glyph: "layers",
            color: DepthStore.maskPath !== "" ? Colours.palette.m3primary : Colours.palette.m3onSurface
        };
    }

    implicitWidth: 32
    implicitHeight: 32

    function centerAlongBar(): real {
        const p = root.mapToItem(null, root.width / 2, root.height / 2);
        return (Config.bar.position === "left" || Config.bar.position === "right") ? p.y : p.x;
    }

    function setOpen(open: bool): void {
        if (!root.popouts)
            return;
        if (open)
            root.popouts.currentCenter = root.centerAlongBar();
        root.popouts.currentName = open ? root.widgetId : "";
        root.popouts.hasCurrent = open;
    }

    function handleHover(_pos, _isHorizontal, shellPopouts): void {
        const target = shellPopouts ?? root.popouts;
        if (!target || target.currentName !== root.widgetId || target.hasCurrent !== true)
            return;
        target.currentCenter = root.centerAlongBar();
    }

    function isCursorScreen(): bool {
        const current = root.screen ?? (root.popouts ? root.popouts.screen : null);
        if (!current)
            return true;
        const name = Kwin.cursorOutputName();
        return !name || name === current.name;
    }

    Connections {
        function onPanelRequested(): void {
            if (root.isCursorScreen())
                root.setOpen(!root.active);
        }

        target: DepthStore
    }

    StyledRect {
        anchors.fill: parent
        color: Colours.palette.m3onSurface
        opacity: root.active ? 0.14 : (mouse.containsMouse ? 0.08 : 0)
        radius: Tokens.rounding.extraLarge

        Behavior on opacity {
            NumberAnimation {
                duration: 120
            }
        }
    }
    MaterialIcon {
        anchors.centerIn: parent
        color: root.kind.color
        fontStyle: Tokens.font.icon.builders.small.size(20).build()
        text: root.kind.glyph
    }
    MouseArea {
        id: mouse

        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        hoverEnabled: true
        onClicked: root.setOpen(!root.active)
    }
}
