pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import "Model.js" as Model

StyledRect {
    id: row

    required property var modelData
    required property int index
    required property real nowSec
    required property bool selected
    required property bool copied
    property bool masked: false

    signal hovered
    signal copyRequested
    signal pinToggled

    readonly property var entry: modelData.entry
    readonly property var st: Model.codeState(entry, nowSec)
    readonly property bool ending: st.remaining <= 5 && !st.stale

    TextMetrics {
        id: codeMetrics
        font.family: Appearance.font.family.mono
        font.pointSize: Tokens.font.title.small.pointSize
        font.weight: Font.Medium
        text: "0000 0000"
    }

    implicitHeight: body.implicitHeight + Tokens.padding.medium * 2
    radius: Tokens.rounding.large
    color: copied ? Colours.palette.m3primaryContainer
        : selected ? Colours.layer(Colours.palette.m3surfaceContainerHigh, 2) : "transparent"

    StateLayer {
        enabled: !row.masked
        radius: row.radius
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: row.hovered()
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                row.pinToggled();
            else
                row.copyRequested();
        }
    }

    RowLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        MaterialIcon {
            visible: row.modelData.pinned
            text: "keep"
            fill: 1
            color: Colours.palette.m3primary
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            StyledText {
                Layout.fillWidth: true

                text: String(row.entry.issuer || "Account")
                font: Tokens.font.title.small
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: String(row.entry.account || "")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
                elide: Text.ElideRight
            }
        }

        ColumnLayout {
            Layout.preferredWidth: Math.ceil(codeMetrics.width)
            Layout.minimumWidth: Math.ceil(codeMetrics.width)
            Layout.maximumWidth: Math.ceil(codeMetrics.width)
            spacing: Tokens.spacing.extraSmall

            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                font.features: { "tnum": 1 }
                text: (row.masked || row.st.stale) ? "··· ···" : Model.formatCode(row.st.code)
                color: row.ending ? Colours.palette.m3error : Colours.palette.m3onSurface
                font.family: Appearance.font.family.mono
                font.pointSize: Tokens.font.title.small.pointSize
                font.weight: Font.Medium
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: Colours.palette.m3surfaceContainerHighest

                Rectangle {
                    anchors.left: parent.left
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * Math.max(0, Math.min(1, row.st.remaining / row.st.period))
                    color: row.ending ? Colours.palette.m3error : Colours.palette.m3primary

                    Behavior on width {
                        Anim { type: Anim.StandardSmall }
                    }
                }
            }
        }
    }
}
