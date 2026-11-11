import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Rocket icon in the bar, built the same way as the Discord overlay's icon:
// left-click opens or closes Startup Apps, right-click opens any startup app
// that isn't already running (`startup-apps --missing`). The icon is lit when
// apps are set to open at login, and dimmed when nothing is set up.
BarWidget {
  id: root
  moduleName: "ynnad.startup-apps"

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy/startup-apps.json"
  readonly property string runner: decodeURIComponent(Qt.resolvedUrl("startup-apps").toString().replace(/^file:\/\//, ""))

  // How many apps are saved, and on which workspaces.
  property int appCount: 0
  property var usedWorkspaces: []

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: layout
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        const ws = JSON.parse(text()).workspaces || {}
        let count = 0
        const used = []
        Object.keys(ws).sort().forEach(function(k) {
          const n = (ws[k] || []).length
          if (n > 0) { count += n; used.push(k) }
        })
        root.appCount = count
        root.usedWorkspaces = used
      } catch (e) {
        root.appCount = 0
        root.usedWorkspaces = []
      }
    }
    onLoadFailed: { root.appCount = 0; root.usedWorkspaces = [] }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-rocket
    text: ""
    active: root.appCount > 0
    opacity: root.appCount > 0 ? 1 : 0.4
    tooltipText: root.appCount > 0
      ? "Startup Apps: " + root.appCount + (root.appCount === 1 ? " app" : " apps")
        + " on workspace " + root.usedWorkspaces.join(", ")
        + " (click to edit, right-click to open any that aren't running)"
      : "Startup Apps: nothing set up (click to add apps)"
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        if (root.appCount > 0) root.bar.run("'" + root.runner + "' --missing")
      } else {
        root.bar.run("omarchy-shell shell toggle ynnad.startup-apps '{}'")
      }
    }
  }
}
