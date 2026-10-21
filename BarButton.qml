// The rocket on the bar. Click opens or closes Startup Apps.

import QtQuick

Item {
  id: root

  // Injected by the bar after load.
  property var bar: null
  property string moduleName: "ynnad.startup-apps"
  property var settings: ({})

  readonly property bool vertical: bar ? bar.vertical === true : false
  readonly property int barSize: bar ? bar.barSize : 26
  readonly property color foreground: bar ? (bar.barForeground || bar.foreground) : "#ffffff"

  implicitWidth: vertical ? barSize : barSize + 2
  implicitHeight: vertical ? barSize + 2 : barSize

  Text {
    anchors.centerIn: parent
    // nf-fa-rocket
    text: String.fromCharCode(0xf135)
    font.family: "JetBrainsMono Nerd Font"
    font.pixelSize: Math.round(root.barSize * 0.5)
    color: root.foreground
    opacity: mouse.containsMouse ? 1 : 0.85
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (root.bar) root.bar.run("omarchy-shell shell toggle ynnad.startup-apps '{}'")
    onEntered: if (root.bar && root.bar.showTooltip) root.bar.showTooltip(root, "Startup Apps")
    onExited: if (root.bar && root.bar.hideTooltip) root.bar.hideTooltip(root)
  }
}
