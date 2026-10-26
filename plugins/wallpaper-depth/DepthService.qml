import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.services
import qs.utils
import "."

// Runs depth_helper.py: probes the runtime, installs the model, and generates a
// foreground mask for the current wallpaper. Jobs run one at a time; a newer
// wallpaper or a newer set of parameters replaces anything still queued.
Item {
    id: root

    readonly property string dataDir: `${Quickshell.env("XDG_DATA_HOME") || `${Quickshell.env("HOME")}/.local/share`}/caelestia/plugins/wallpaper-depth`
    readonly property string helperPath: Qt.resolvedUrl("depth_helper.py").toString().replace("file://", "")

    Settings {
        id: cfg

        category: "Plugin_wallpaper-depth"
    }

    function clampInt(value: var, fallback: int, minimum: int, maximum: int): int {
        const number = Number(value);
        if (!isFinite(number))
            return fallback;
        return Math.max(minimum, Math.min(maximum, Math.round(number)));
    }

    readonly property bool autoThreshold: String(cfg.value("auto_threshold", true)) !== "false"
    readonly property int thresholdPercent: root.clampInt(cfg.value("threshold", 30), 30, 0, 100)
    readonly property int featherPercent: root.clampInt(cfg.value("feather", 8), 8, 0, 50)
    readonly property real threshold: root.thresholdPercent / 100
    readonly property real feather: root.featherPercent / 100
    readonly property bool autoGenerate: String(cfg.value("auto_generate", true)) !== "false"

    // Videos and animated images have no stable frame to mask, so they are left alone.
    readonly property string imageWallpaper: {
        const path = Wallpapers.actualCurrent || "";
        if (path === "")
            return "";
        return Images.isVideo(path) || Images.isAnimated(path) ? "" : path;
    }

    property var queue: []
    property var active: null
    property bool timedOut: false

    function parse(text: string): var {
        if (!text)
            return null;
        try {
            const value = JSON.parse(text);
            return value && typeof value === "object" ? value : null;
        } catch (error) {
            return null;
        }
    }

    function lastLine(text: string): string {
        const lines = String(text || "").split("\n").map(line => line.trim()).filter(line => line.length > 0);
        return lines.length > 0 ? lines[lines.length - 1].slice(0, 300) : "";
    }

    function maskIsCurrent(): bool {
        return DepthStore.maskPath !== "" && DepthStore.maskWallpaper === root.imageWallpaper && DepthStore.maskAuto === root.autoThreshold && (root.autoThreshold || Math.abs(DepthStore.maskThreshold - root.threshold) < 0.0001) && Math.abs(DepthStore.maskFeather - root.feather) < 0.0001;
    }

    function enqueue(job: var): void {
        const next = [];
        for (const item of root.queue) {
            if (item.kind === job.kind && job.kind !== "generate")
                continue;
            if (item.kind === "generate" && job.kind === "generate")
                continue;
            next.push(item);
        }
        next.push(job);
        root.queue = next;
        root.pump();
    }

    function pump(): void {
        if (root.active !== null || root.queue.length === 0)
            return;

        const job = root.queue[0];
        root.queue = root.queue.slice(1);
        root.active = job;
        root.timedOut = false;

        switch (job.kind) {
        case "python":
            DepthStore.phase = "checking";
            proc.command = ["python3", "--version"];
            break;
        case "status":
            DepthStore.phase = "checking";
            proc.command = ["python3", root.helperPath, "--data-dir", root.dataDir, "status"];
            break;
        case "setup":
            DepthStore.phase = "setup";
            DepthStore.setupState = "running";
            DepthStore.message = "";
            proc.command = ["python3", root.helperPath, "--data-dir", root.dataDir, "setup"];
            break;
        case "clear":
            DepthStore.phase = "clearing";
            proc.command = ["python3", root.helperPath, "--data-dir", root.dataDir, "clear-cache"];
            break;
        case "generate":
            DepthStore.phase = "generating";
            proc.command = job.auto ? ["python3", root.helperPath, "--data-dir", root.dataDir, "generate", "--wallpaper", job.wallpaper, "--auto-threshold", "--feather", job.feather.toFixed(4)] : ["python3", root.helperPath, "--data-dir", root.dataDir, "generate", "--wallpaper", job.wallpaper, "--threshold", job.threshold.toFixed(4), "--feather", job.feather.toFixed(4)];
            break;
        }

        watchdog.interval = job.timeout ?? 120000;
        watchdog.restart();
        proc.running = true;
    }

    function finish(code: int, output: string, error: string): void {
        watchdog.stop();

        const job = root.active;
        root.active = null;
        if (!job || job.settled)
            return;

        job.settled = true;
        const failure = root.lastLine(error) || root.lastLine(output);
        const exitCode = root.timedOut ? -1 : code;

        switch (job.kind) {
        case "python":
            DepthStore.pythonAvailable = exitCode === 0;
            DepthStore.phase = "idle";
            if (exitCode === 0) {
                root.enqueue({
                    kind: "status",
                    timeout: 60000
                });
            } else {
                DepthStore.setupState = "missing";
                DepthStore.message = qsTr("python3 is required to estimate depth.");
            }
            break;
        case "status": {
            const value = root.parse(output);
            DepthStore.phase = "idle";
            if (exitCode === 0 && value && value.ready === true) {
                DepthStore.setupState = "ready";
                DepthStore.message = "";
                root.autoGenerateNow();
            } else {
                DepthStore.setupState = "missing";
                DepthStore.message = exitCode === 0 ? "" : failure || qsTr("Depth model not installed.");
            }
            break;
        }
        case "setup":
            DepthStore.phase = "idle";
            if (exitCode === 0) {
                root.enqueue({
                    kind: "status",
                    timeout: 60000
                });
            } else {
                DepthStore.setupState = "error";
                DepthStore.message = failure || qsTr("Setup failed.");
            }
            break;
        case "clear":
            DepthStore.phase = "idle";
            DepthStore.clearMask();
            DepthStore.message = exitCode === 0 ? "" : failure || qsTr("Could not clear the cache.");
            root.autoGenerateNow();
            break;
        case "generate": {
            DepthStore.phase = "idle";
            const value = root.parse(output);
            if (exitCode !== 0) {
                if (job.wallpaper === root.imageWallpaper) {
                    DepthStore.clearMask();
                    DepthStore.message = failure || qsTr("Mask generation failed.");
                }
            } else if (value && typeof value.maskPath === "string" && value.maskPath !== "" && value.wallpaperPath === job.wallpaper) {
                DepthStore.maskPath = value.maskPath;
                DepthStore.maskWallpaper = job.wallpaper;
                DepthStore.maskWidth = Number(value.width) || 0;
                DepthStore.maskHeight = Number(value.height) || 0;
                DepthStore.maskAuto = job.auto;
                DepthStore.maskThreshold = job.threshold;
                DepthStore.maskFeather = job.feather;
                DepthStore.maskCut = Number(value.cut) || -1;
                DepthStore.maskCoverage = Number(value.coverage) || 0;
                DepthStore.elapsedMs = Number(value.elapsedMs) || -1;
                DepthStore.cacheHit = value.cacheHit === true;
                DepthStore.message = "";
            }
            root.autoGenerateNow();
            break;
        }
        }

        root.pump();
    }

    // Queues a mask for whatever is on screen now, unless the current one matches.
    function autoGenerateNow(): void {
        if (!DepthStore.ready || !root.autoGenerate || root.imageWallpaper === "" || root.maskIsCurrent())
            return;
        root.enqueue({
            kind: "generate",
            wallpaper: root.imageWallpaper,
            auto: root.autoThreshold,
            threshold: root.threshold,
            feather: root.feather,
            timeout: 300000
        });
    }

    function generateNow(): void {
        if (!DepthStore.ready || root.imageWallpaper === "")
            return;
        root.enqueue({
            kind: "generate",
            wallpaper: root.imageWallpaper,
            auto: root.autoThreshold,
            threshold: root.threshold,
            feather: root.feather,
            timeout: 300000
        });
    }

    function startSetup(): void {
        if (root.active !== null && root.active.kind === "setup")
            return;
        root.enqueue({
            kind: "setup",
            timeout: 1800000
        });
    }

    function clearCache(): void {
        root.enqueue({
            kind: "clear",
            timeout: 60000
        });
    }

    function refreshStatus(): void {
        root.enqueue({
            kind: "python",
            timeout: 15000
        });
    }

    Component.onCompleted: {
        // Record what the settings say; the mask keeps its own parameters so a
        // change here is not mistaken for a mask that is already up to date.
        DepthStore.autoGenerate = root.autoGenerate;
        DepthStore.autoThreshold = root.autoThreshold;
        DepthStore.threshold = root.threshold;
        DepthStore.feather = root.feather;
        root.refreshStatus();
    }

    Connections {
        function onActualCurrentChanged(): void {
            wallpaperDebounce.restart();
        }

        target: Wallpapers
    }

    Connections {
        function onClearCacheRequested(): void {
            root.clearCache();
        }

        function onGenerateRequested(): void {
            root.generateNow();
        }

        function onRefreshRequested(): void {
            root.refreshStatus();
        }

        function onSetupRequested(): void {
            root.startSetup();
        }

        target: DepthStore
    }

    Timer {
        id: wallpaperDebounce

        interval: 900
        onTriggered: root.autoGenerateNow()
    }

    Timer {
        id: watchdog

        onTriggered: {
            if (root.active === null)
                return;
            root.timedOut = true;
            proc.running = false;
            settleTimer.restart();
        }
    }

    // Quickshell does not always emit `exited` for a process we terminated, so a
    // killed job is settled here instead of leaving the queue stalled.
    Timer {
        id: settleTimer

        interval: 1500
        onTriggered: {
            if (root.active !== null)
                root.finish(-1, "", "");
        }
    }

    Process {
        id: proc

        stderr: StdioCollector {
            id: procError
        }
        stdout: StdioCollector {
            id: procOutput
        }

        onExited: (code) => root.finish(code, procOutput.text, procError.text)
    }
}
