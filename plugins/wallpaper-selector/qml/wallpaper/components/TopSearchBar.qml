import QtQuick
import QtQuick.Controls
import Caelestia
import Caelestia.Config as ShellConfig
import qs.components.controls
import qs.services.api
import qs.components

StyledRect {
    id: root

    property var colors
    property alias text: searchInput.text

    signal escapePressed()
    signal accepted()
    signal settingsClicked()
    signal searchInteracted()

    color: colors && colors.secondaryContainer ? Qt.rgba(colors.secondaryContainer.r, colors.secondaryContainer.g, colors.secondaryContainer.b, 0.95) : Qt.rgba(0.2, 0.2, 0.2, 0.95)
    radius: ShellConfig.Tokens.rounding.large
    implicitWidth: 310
    implicitHeight: 42
    height: implicitHeight

    Text {
        id: searchIcon
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: ShellConfig.Tokens.padding.medium
        text: "\uF002"
        color: colors && colors.surfaceText ? colors.surfaceText : "white"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 16
    }

    TextField {
        id: searchInput
        anchors.left: searchIcon.right
        anchors.leftMargin: ShellConfig.Tokens.spacing.small
        anchors.right: clearBtn.visible ? clearBtn.left : parent.right
        anchors.rightMargin: clearBtn.visible ? ShellConfig.Tokens.spacing.small : ShellConfig.Tokens.padding.medium
        anchors.verticalCenter: parent.verticalCenter
        placeholderText: qsTr("Search wallpapers...")
        color: colors && colors.surfaceText ? colors.surfaceText : "white"
        placeholderTextColor: colors && colors.surfaceText ? Qt.rgba(colors.surfaceText.r, colors.surfaceText.g, colors.surfaceText.b, 0.6) : Qt.rgba(1, 1, 1, 0.6)
        background: null
        font: ShellConfig.Tokens.font.body.medium
        topPadding: 0
        bottomPadding: 0
        leftPadding: 0
        rightPadding: 0

        onTextChanged: CaelestiaApi.visuals.wallpaper.searchText = text
        onAccepted: root.accepted()
        Keys.onEscapePressed: {
            if (searchInput.text !== "") {
                searchInput.text = ""
            } else {
                root.escapePressed()
            }
        }
        Keys.onPressed: function(event) {
            root.searchInteracted()
            if ((event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) ||
                (event.key === Qt.Key_Backspace && (event.modifiers & Qt.ControlModifier))) {
                searchInput.text = ""
                event.accepted = true
            }
        }
    }

    Text {
        id: clearBtn
        visible: searchInput.text.length > 0
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: ShellConfig.Tokens.padding.medium
        text: "\uF00D" // nf-fa-times
        font.family: "Symbols Nerd Font"
        font.pixelSize: 14
        color: clearMouse.containsMouse ? (colors && colors.primary ? colors.primary : "white") : (colors && colors.surfaceText ? Qt.rgba(colors.surfaceText.r, colors.surfaceText.g, colors.surfaceText.b, 0.7) : Qt.rgba(1, 1, 1, 0.7))

        MouseArea {
            id: clearMouse
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                searchInput.text = ""
                searchInput.forceActiveFocus()
            }
        }
    }

    function clearSearch() {
        searchInput.text = ""
    }

    function forceSearchFocus() {
        searchInput.forceActiveFocus()
    }
    
    function appendSearchText(newText) {
        searchInput.text += newText
        forceSearchFocus()
    }
    
    function backspaceSearchText() {
        if (searchInput.text.length > 0) {
            searchInput.text = searchInput.text.slice(0, -1)
        }
    }
}
