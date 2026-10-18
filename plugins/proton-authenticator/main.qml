import QtQuick
import Quickshell.Io
import Caelestia
import qs.services.api
import "."

// Plugin-level entry: global shortcut and IPC only. The bar icon is BarWidget.qml
// and the panel is Popout.qml (both registered through barWidgets in metadata.json).
Item {
    id: root

    function requestToggle(): void { ProtonBridge.toggle(); }

    IpcHandler {
        target: "protonAuthenticator"
        function open(): void { ProtonBridge.open(); }
        function close(): void { ProtonBridge.close(); }
        function toggle(): void { ProtonBridge.toggle(); }
        function refresh(): string { ProtonBridge.refreshRequested(); return "ok"; }
        function clearClipboard(): string { ProtonBridge.clearClipboardIfOurs(); return "ok"; }
    }

    Component.onCompleted: {
        CaelestiaApi.shortcuts.register("authenticator", "Open Proton Authenticator codes", "Meta+Ctrl+U", root.requestToggle);
    }
}
