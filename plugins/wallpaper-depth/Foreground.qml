pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Caelestia.Config
import qs.services
import "."

// Desktop background widget that re-draws the foreground of the wallpaper on
// top of the other widgets, using the generated depth mask as its alpha. Its z
// value in metadata.json keeps it above every other background widget.
Item {
    id: root

    property var screen
    property var background

    readonly property string wallpaper: Wallpapers.actualCurrent || ""
    // While the wallpaper picker previews another image the desktop shows that
    // image, so a mask for the applied wallpaper would paint the old foreground
    // over it.
    readonly property bool previewing: Wallpapers.previewing
    readonly property bool maskMatches: root.wallpaper !== "" && DepthStore.maskWallpaper === root.wallpaper && DepthStore.maskPath !== ""
    // The wallpaper itself may come from this shell or from an external daemon on
    // the background layer; either way the desktop window sits above it, so only
    // the desktop being disabled or edited keeps the foreground out.
    readonly property bool active: root.maskMatches && !root.previewing && !Config.background.disableQuickshellDesktop && !ContextMenuStore.editMode && root.settled

    // The shell reveals a new wallpaper behind an animated shape mask; waiting
    // for that to finish keeps the foreground from popping in half way through.
    property bool settled: false

    visible: root.active

    onWallpaperChanged: {
        root.settled = false;
        settleTimer.restart();
    }
    Component.onCompleted: settleTimer.restart()

    Timer {
        id: settleTimer

        interval: 2600
        onTriggered: root.settled = true
    }

    Image {
        id: wallpaperLayer

        anchors.fill: parent
        asynchronous: true
        cache: false
        fillMode: Config.background.wallpaperFillMode
        source: root.active ? `file://${root.wallpaper}` : ""
        sourceSize: {
            if (!root.active || width <= 0 || height <= 0)
                return Qt.size(0, 0);
            const dpr = wallpaperLayer.Screen.devicePixelRatio || 1;
            return Qt.size(Math.ceil(Math.max(width, height) * dpr * 1.5), 0);
        }
        layer.enabled: root.active
        layer.effect: MultiEffect {
            // Only mimic the shell's wallpaper tint when the shell draws that
            // wallpaper itself; an external daemon has already rendered it.
            colorization: (Config.background.wallpaperEnabled && Config.background.wallpaperRecolor) ? Config.background.wallpaperRecolorStrength : 0
            colorizationColor: Colours.palette.m3primary
            maskEnabled: true
            maskSource: maskSource
        }
    }
    Image {
        id: maskLayer

        anchors.fill: parent
        asynchronous: true
        cache: false
        fillMode: Config.background.wallpaperFillMode
        source: root.active ? `file://${DepthStore.maskPath}` : ""
    }
    // hideSource keeps the mask image out of the scene, so it must not carry a
    // visible binding of its own. The source is transparent as well, otherwise
    // the shader effect source itself would paint the mask over the desktop.
    ShaderEffectSource {
        id: maskSource

        anchors.fill: parent
        hideSource: true
        live: true
        opacity: 0
        sourceItem: maskLayer
    }
}
