import QtQuick
import Quickshell.Hyprland

// Headless half of the workspace carousel.
//
// The plugin owns no navigation keys. While the strip is up it mirrors whatever
// workspace Hyprland has focused, so SUPER+TAB, SUPER+1..9, a click in the bar
// and a window pulling you elsewhere all drive it equally. When the strip is
// closed this does nothing at all.
Item {
  id: root

  property var shell: null

  readonly property string pluginId: "io.github.iryzhkov.omadeck"

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() {
      if (root.shell)
        root.shell.callIfLoaded(root.pluginId, "follow", "")
    }
  }
}
