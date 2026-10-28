// Root entry point for the Caelestia plugin loader (PluginLoader falls back to
// main.qml when metadata.json declares no "ui").
//
// Deliberately inert: it loads no UI and starts no process. It only exposes the
// adapter singletons, lazily, for consumers that opt in:
//
//     plugin.commandGate()    -> CommandGate   (confirmation gate for commands)
//     plugin.settingsTools()  -> SettingsTools (settings tool bridge)
//
// The legacy sidebar (opt-in/sidebar-legacy/) is intentionally NOT referenced
// here, so enabling the plugin can never replace the shell's own sidebar.

import QtQuick
import Quickshell
import "." as Adapter

Scope {
    id: root

    function commandGate() {
        return Adapter.CommandGate;
    }

    function settingsTools() {
        return Adapter.SettingsTools;
    }
}
