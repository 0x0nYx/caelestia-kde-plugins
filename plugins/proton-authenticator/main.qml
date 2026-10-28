import QtQuick
import Quickshell.Io
import Caelestia
import qs.components
import qs.components.controls
import qs.services
import qs.services.api
import "."

Item {
    id: root

    function requestToggle(): void { ProtonBridge.toggle(); }

    Connections {
        target: ProtonBridge

        function onCopyResult(id, ok, reason, label, toast) {
            if (!ok) {
                const why = reason === "WL_COPY_TIMEOUT" ? qsTr("wl-copy did not respond") : qsTr("wl-copy failed. Is wl-clipboard installed?");
                Toaster.toast(qsTr("Copy failed"), why, "error", Toast.Error);
            } else if (toast) {
                Toaster.toast(qsTr("Copied code"), label, "key", Toast.Success);
            }
        }

        function onClearProblem(reason) {
            const why = ({
                WL_PASTE_MISSING: qsTr("wl-paste not found, so the clipboard will not be cleared automatically"),
                CHECK_TIMEOUT: qsTr("Timed out checking the clipboard; the code may still be there"),
                CHECK_FAILED: qsTr("Could not check the clipboard; the code may still be there"),
                CLEAR_FAILED: qsTr("Could not clear the clipboard; the code may still be there")
            })[reason] || qsTr("Could not clear the clipboard");
            Toaster.toast(qsTr("Clipboard not cleared"), why, "warning", Toast.Warning);
        }
    }

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
