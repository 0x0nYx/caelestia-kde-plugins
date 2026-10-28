pragma Singleton

import QtQuick
import Quickshell.Io

// Live state of the depth service. `main.qml` owns the work, but the desktop
// overlay, the bar widget and the panel are separate components, so the results
// are shared here instead of being passed around. The IPC handler lives here too
// so rebuilding the plugin (which happens on every settings change) never
// registers a second handler for the same target.
QtObject {
    id: root

    // checking | missing | running | ready | error
    property string setupState: "checking"
    property string message: ""
    // idle | checking | setup | generating | clearing
    property string phase: "idle"
    property bool pythonAvailable: true
    property bool autoGenerate: true
    property bool autoThreshold: true

    // Current settings, as fractions of 1.
    property real threshold: 0.3
    property real feather: 0.08

    property string maskPath: ""
    property string maskWallpaper: ""
    property int maskWidth: 0
    property int maskHeight: 0
    // Parameters the mask on disk was generated with. Kept apart from the current
    // settings so a change is noticed even though the plugin is rebuilt.
    property bool maskAuto: false
    property real maskThreshold: -1
    property real maskFeather: -1
    // Cut the helper actually used, after the automatic rule or the manual value.
    property real maskCut: -1
    // Share of the wallpaper the mask actually puts in front, measured by the helper.
    property real maskCoverage: -1
    property int elapsedMs: -1
    property bool cacheHit: false

    readonly property bool ready: root.setupState === "ready"
    readonly property bool busy: root.phase === "checking" || root.phase === "setup" || root.phase === "generating" || root.phase === "clearing"

    signal panelRequested()
    signal setupRequested()
    signal generateRequested()
    signal clearCacheRequested()
    signal refreshRequested()

    function clearMask(): void {
        root.maskPath = "";
        root.maskWallpaper = "";
        root.maskWidth = 0;
        root.maskHeight = 0;
        root.maskAuto = false;
        root.maskThreshold = -1;
        root.maskFeather = -1;
        root.maskCut = -1;
        root.maskCoverage = -1;
        root.elapsedMs = -1;
        root.cacheHit = false;
    }

    // QtObject has no default property, so the handler is held as a property.
    readonly property IpcHandler ipc: IpcHandler {
        target: "wallpaper-depth"

        function status(): string {
            return JSON.stringify({
                setupState: root.setupState,
                phase: root.phase,
                message: root.message,
                pythonAvailable: root.pythonAvailable,
                maskPath: root.maskPath,
                maskWallpaper: root.maskWallpaper,
                width: root.maskWidth,
                height: root.maskHeight,
                threshold: root.threshold,
                feather: root.feather,
                autoThreshold: root.autoThreshold,
                maskAuto: root.maskAuto,
                maskThreshold: root.maskThreshold,
                maskFeather: root.maskFeather,
                cut: root.maskCut,
                coverage: root.maskCoverage,
                autoGenerate: root.autoGenerate,
                elapsedMs: root.elapsedMs,
                cacheHit: root.cacheHit
            });
        }

        function setup(): void {
            root.setupRequested();
        }

        function generate(): void {
            root.generateRequested();
        }

        function clearCache(): void {
            root.clearCacheRequested();
        }

        function refresh(): void {
            root.refreshRequested();
        }

        function panel(): void {
            root.panelRequested();
        }
    }
}
