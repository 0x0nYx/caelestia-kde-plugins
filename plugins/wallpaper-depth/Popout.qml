pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import "."

Item {
    id: root

    property var popouts
    property var visibilities

    readonly property bool ready: DepthStore.ready
    readonly property var stateIcon: {
        switch (DepthStore.setupState) {
        case "ready":
            return {
                glyph: "check_circle",
                color: Colours.palette.m3primary
            };
        case "running":
            return {
                glyph: "download",
                color: Colours.palette.m3primary
            };
        case "error":
            return {
                glyph: "error",
                color: Colours.palette.m3error
            };
        default:
            return {
                glyph: "layers_clear",
                color: Colours.palette.m3onSurfaceVariant
            };
        }
    }
    readonly property string stateTitle: {
        switch (DepthStore.setupState) {
        case "ready":
            return qsTr("Depth model ready");
        case "running":
            return qsTr("Installing the model…");
        case "error":
            return qsTr("Something went wrong");
        default:
            return qsTr("Depth model not installed");
        }
    }
    readonly property string stateDetail: {
        if (DepthStore.message !== "")
            return DepthStore.message;
        if (!DepthStore.pythonAvailable)
            return qsTr("python3 with venv support is required.");
        if (!DepthStore.ready)
            return qsTr("Installing downloads about 39 MB from Hugging Face and keeps it on this machine.");
        if (DepthStore.maskPath === "")
            return qsTr("No mask yet. Generate one for the current wallpaper.");
        const seconds = DepthStore.elapsedMs >= 0 ? (DepthStore.elapsedMs / 1000).toFixed(1) : "";
        const cached = DepthStore.cacheHit ? qsTr(" · cached") : "";
        return seconds !== "" ? qsTr("Mask ready in %1s").arg(seconds) + cached : qsTr("Mask ready") + cached;
    }

    function closePanel(): void {
        if (root.popouts)
            root.popouts.hasCurrent = false;
    }

    // The shell has no IPC for opening one plugin's settings popup, so land on the
    // plugin's own row in Nexus and let the gear there open the rest.
    function openSettings(): void {
        root.closePanel();
        Quickshell.execDetached(["caelestia", "shell", "nexus", "openPage", "plugins", ""]);
    }

    implicitWidth: 340
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout

        width: root.implicitWidth
        spacing: Tokens.spacing.large

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            MaterialIcon {
                color: Colours.palette.m3primary
                fontStyle: Tokens.font.icon.builders.small.size(22).build()
                text: "layers"
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    font: Tokens.font.title.small
                    text: qsTr("Wallpaper Depth")
                }
                StyledText {
                    Layout.fillWidth: true
                    Layout.preferredWidth: 0
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                    text: qsTr("Desktop widgets behind the scenery")
                }
            }
        }

        StyledRect {
            Layout.fillWidth: true
            color: Colours.palette.m3surfaceContainerHigh
            implicitHeight: stateLayout.implicitHeight + Tokens.padding.large * 2
            radius: Tokens.rounding.large

            RowLayout {
                id: stateLayout

                anchors.fill: parent
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.medium

                MaterialIcon {
                    Layout.alignment: Qt.AlignTop
                    color: root.stateIcon.color
                    fontStyle: Tokens.font.icon.builders.small.size(20).build()
                    text: root.stateIcon.glyph
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.extraSmall

                    StyledText {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        font: Tokens.font.body.medium
                        text: root.stateTitle
                    }
                    StyledText {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        color: root.stateIcon.color
                        font: Tokens.font.body.small
                        text: root.stateDetail
                        visible: text !== ""
                        wrapMode: Text.WordWrap
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            TextButton {
                enabled: !DepthStore.busy && DepthStore.pythonAvailable
                text: qsTr("Install model")
                visible: !root.ready
                onClicked: DepthStore.setupRequested()
            }
            TextButton {
                enabled: root.ready && !DepthStore.busy
                text: qsTr("Generate now")
                visible: root.ready
                onClicked: DepthStore.generateRequested()
            }
            TextButton {
                enabled: !DepthStore.busy
                text: qsTr("Clear cache")
                onClicked: DepthStore.clearCacheRequested()
            }
            Item {
                Layout.fillWidth: true
            }
            TextButton {
                text: qsTr("Done")
                onClicked: root.closePanel()
            }
        }

        IconTextButton {
            Layout.fillWidth: true
            icon: "settings"
            text: qsTr("Plugin settings")
            type: TextButton.Tonal
            onClicked: root.openSettings()
        }
    }
}
