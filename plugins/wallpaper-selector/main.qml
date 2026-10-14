pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.services.api
import qs.services
import "qml"

import "qml" as PluginStyle
import "qml/wallpaper" as WallpaperQml

Scope {
    id: root

    property bool showing: false
    property string activeScreen: (Quickshell.screens && Quickshell.screens.length > 0) ? Quickshell.screens[0].name : ""

    property int settingsOpenCount: 0
    signal closeSettingsRequested()

    function registerShortcut() {
        CaelestiaApi.shortcuts.register("wallpaper_selector", "Toggle Wallpaper Selector", Config.shortcut, () => {
            if (!root.showing) {
                var screenName = "";
                if (typeof CaelestiaApi.windows.kwin !== "undefined" && CaelestiaApi.windows.kwin) {
                    screenName = CaelestiaApi.windows.kwin.cursorOutputName() || "";
                } else if (typeof Hypr !== "undefined" && Hypr) {
                    screenName = Hypr.focusedMonitor ? Hypr.focusedMonitor.name : "";
                }
                if (!screenName && Quickshell.screens && Quickshell.screens.length > 0) {
                    screenName = Quickshell.screens[0].name;
                }
                root.activeScreen = screenName;
                root.showing = true;
            } else {
                if (root.settingsOpenCount > 0) {
                    root.closeSettingsRequested()
                } else {
                    root.showing = false;
                }
            }
        });
    }

    Component.onCompleted: registerShortcut()

    Connections {
        target: Config
        function onShortcutChanged() {
            registerShortcut()
        }
    }

    Variants {
        model: Quickshell.screens

        WallpaperQml.WallpaperSelector {
            required property var modelData
            screen: modelData
            showing: root.showing
            isMainScreen: (Quickshell.screens.length <= 1) || (root.activeScreen ? modelData.name === root.activeScreen : modelData === Quickshell.screens[0])
            colors: PluginStyle.Colors {}
            
            Connections {
                target: root
                function onShowingChanged() {
                    if (showing !== root.showing) {
                        showing = root.showing;
                    }
                }
            }
            
            onShowingChanged: {
                if (!showing && root.showing) {
                    root.showing = false;
                }
            }
        }
    }
}
