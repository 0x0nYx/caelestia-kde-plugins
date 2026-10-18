import QtQuick
import Quickshell.Io
import Caelestia
import qs.services.api
import "."

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
