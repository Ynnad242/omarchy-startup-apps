// Startup Apps - drag app icons onto workspaces 1-5 and they open there at
// login.
//
// Saves to ~/.config/omarchy/startup-apps.json. The `startup-apps` script next
// to this file reads it at login (from ~/.config/hypr/autostart.lua), launches
// every app and moves each one's window to its workspace.
//
// Each saved app carries match keys: lowercased fragments of the window class
// it is expected to open (desktop id, StartupWMClass, program name, webapp
// host, Steam game id). The script moves the first new window whose class
// contains one of them.
//
// Shell contract: the shell calls open(payloadJson) on summon and close() on
// hide; `opened` reports state.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null

  property bool opened: false

  readonly property string pluginId: (manifest && manifest.id) || "ynnad.startup-apps"
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy/startup-apps.json"
  readonly property string autostartPath: home + "/.config/hypr/autostart.lua"
  readonly property string runnerLine: 'o.exec_on_start(os.getenv("HOME") .. "/.config/omarchy/plugins/ynnad.startup-apps/startup-apps")'

  readonly property int workspaceCount: 5

  // { "1": [app, ...], ... }. Replaced, never mutated, so bindings re-evaluate.
  property var workspaces: ({})
  property var allApps: []
  property string query: ""
  // null until checked, then whether autostart.lua runs the script.
  property var enabledAtLogin: null

  // ------------------------------------------------------------ look
  //
  // Drawn with the Omarchy menu's own tokens (qs.Commons Color.menu and
  // Style), so it follows the theme, font and rounding exactly as the menu
  // does.

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color rule: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.14)
  readonly property string fontFamily: Style.fontFamily
  readonly property int radius: Style.cornerRadius

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    root.opened = true
    root.query = ""
    loadApps()
    checkProc.running = true
    Qt.callLater(function() { if (root.opened) search.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else close()
  }

  // ------------------------------------------------------------ apps

  function iconFor(icon) {
    var v = String(icon || "")
    if (v.charAt(0) === "/") return "file://" + v
    var found = v ? Quickshell.iconPath(v, true) : ""
    return found || Quickshell.iconPath("application-x-executable", true)
  }

  function loadApps() {
    var values = DesktopEntries.applications.values || []
    var list = []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e || e.noDisplay || !e.id) continue
      list.push({
        name: String(e.name || e.id),
        icon: String(e.icon || ""),
        desktopId: String(e.id).replace(/\.desktop$/, ""),
        keys: matchKeys(e)
      })
    }
    list.sort(function(a, b) { return a.name.toLowerCase().localeCompare(b.name.toLowerCase()) })
    root.allApps = list
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { if (root.opened) root.loadApps() }
  }

  // Launchers that say nothing about the window they open; the program after
  // them, or an argument, does.
  readonly property var wrappers: ["env", "uwsm-app", "uwsm", "app", "--", "setsid", "gtk-launch", "sh", "bash", "-c"]
  // Reverse-DNS segments too generic to match on.
  readonly property var genericSegments: ["com", "org", "net", "io", "app", "desktop", "client", "application"]

  function matchKeys(entry) {
    var keys = []
    function add(value) {
      var k = String(value || "").toLowerCase().trim()
      if (k.length >= 3 && keys.indexOf(k) < 0) keys.push(k)
    }
    function addReverseDns(id) {
      add(id)
      var parts = String(id).split(".")
      if (parts.length < 2) return
      for (var p = 0; p < parts.length; p++) {
        if (root.genericSegments.indexOf(parts[p].toLowerCase()) < 0) add(parts[p])
      }
    }

    add(entry.startupClass)
    var id = String(entry.id || "").replace(/\.desktop$/, "")
    if (id.indexOf(" ") < 0) addReverseDns(id)
    add(String(entry.name || "").replace(/\s+/g, ""))

    var cmd = []
    try { for (var c = 0; c < entry.command.length; c++) cmd.push(String(entry.command[c])) } catch (e) {}
    var i = 0
    while (i < cmd.length && (root.wrappers.indexOf(cmd[i]) >= 0 || /^[A-Za-z_]+=/.test(cmd[i]))) i++
    if (i >= cmd.length) return keys
    var prog = cmd[i].replace(/^.*\//, "")
    var rest = cmd.slice(i + 1)

    if (prog.indexOf("webapp") >= 0) {
      for (var w = 0; w < rest.length; w++) {
        var host = rest[w].match(/^https?:\/\/([^\/:?#]+)/)
        if (host) add(host[1].replace(/^www\./, ""))
      }
    } else if (prog === "steam") {
      for (var s = 0; s < rest.length; s++) {
        var game = rest[s].match(/rungameid\/(\d+)/)
        if (game) add("steam_app_" + game[1])
      }
    } else if (prog === "flatpak") {
      for (var f = 0; f < rest.length; f++) {
        if (rest[f] !== "run" && rest[f].charAt(0) !== "-") { addReverseDns(rest[f]); break }
      }
    } else if (prog === "xdg-terminal-exec" || prog.indexOf("omarchy-launch-tui") === 0) {
      for (var t = 0; t < rest.length; t++) {
        var appId = rest[t].match(/^--app-id=(.+)$/)
        if (appId) add(appId[1])
      }
    } else {
      add(prog)
    }
    return keys
  }

  // A terminal command typed in the search box, opened the way
  // omarchy-launch-tui does (window class org.omarchy.<program>).
  function terminalApp(command) {
    var cmd = String(command || "").trim()
    if (!cmd) return null
    var prog = cmd.split(/\s+/)[0].replace(/^.*\//, "")
    return { name: prog, icon: "utilities-terminal", tui: cmd, keys: ["org.omarchy." + prog.toLowerCase()] }
  }

  readonly property var filteredApps: {
    var q = root.query.trim().toLowerCase()
    var out = []
    var term = terminalApp(root.query)
    if (term) out.push(term)
    for (var i = 0; i < root.allApps.length; i++) {
      var a = root.allApps[i]
      if (!q || a.name.toLowerCase().indexOf(q) >= 0 || a.desktopId.toLowerCase().indexOf(q) >= 0) out.push(a)
    }
    return out
  }

  function sameApp(a, b) {
    return (a.desktopId || "") === (b.desktopId || "") && (a.tui || "") === (b.tui || "")
  }

  function appsOn(ws) {
    return root.workspaces[String(ws)] || []
  }

  // Put `app` on workspace `ws`, taking it off `fromWs` (0 when it came from
  // the app list).
  function addApp(ws, app, fromWs) {
    if (!app || ws === fromWs) return
    var next = cloneWorkspaces()
    if (fromWs > 0) next[String(fromWs)] = next[String(fromWs)].filter(function(a) { return !root.sameApp(a, app) })
    var list = next[String(ws)]
    if (!list.some(function(a) { return root.sameApp(a, app) })) list.push(app)
    save(next)
  }

  function removeApp(ws, app) {
    var next = cloneWorkspaces()
    next[String(ws)] = next[String(ws)].filter(function(a) { return !root.sameApp(a, app) })
    save(next)
  }

  function cloneWorkspaces() {
    var next = JSON.parse(JSON.stringify(root.workspaces || {}))
    for (var i = 1; i <= root.workspaceCount; i++) if (!next[String(i)]) next[String(i)] = []
    return next
  }

  // ------------------------------------------------------------ storage

  function save(next) {
    root.workspaces = next
    configFile.setText(JSON.stringify({ version: 1, workspaces: next }, null, 2) + "\n")
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text() || "{}")
        root.workspaces = (data && data.workspaces) || {}
      } catch (e) {
        root.workspaces = {}
      }
    }
    onLoadFailed: root.workspaces = {}
    onFileChanged: reload()
  }

  // ------------------------------------------------------------ login hook

  Process {
    id: checkProc
    command: ["grep", "-qF", "ynnad.startup-apps/startup-apps", root.autostartPath]
    onExited: (code) => root.enabledAtLogin = code === 0
  }

  Process {
    id: enableProc
    command: ["bash", "-c", 'printf "\\n-- Open the apps set in Startup Apps on their workspaces.\\n%s\\n" "$1" >> "$2"', "_", root.runnerLine, root.autostartPath]
    onExited: checkProc.running = true
  }

  // ------------------------------------------------------------ window

  FloatingWindow {
    id: window
    title: "Startup Apps"
    visible: root.opened
    color: root.background
    implicitWidth: 940
    implicitHeight: 640
    minimumSize: Qt.size(760, 520)

    // Closed from the compositor (SUPER + W): tell the shell so the next
    // toggle opens it again.
    onVisibleChanged: if (!visible && root.opened) root.requestClose()

    FocusScope {
      id: content
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.requestClose()

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.panelPadding

        // ---- heading
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          Label {
            text: "Startup Apps"
            font.pixelSize: Style.font.heading
            font.weight: Font.Medium
          }

          Label {
            Layout.fillWidth: true
            text: "drag apps onto a workspace to open them there at login"
            opacity: 0.52
            elide: Text.ElideRight
          }

          Label {
            visible: root.enabledAtLogin === true
            text: "on at login"
            opacity: 0.52
          }

          // Until autostart.lua runs the script, offer to add it.
          Item {
            visible: root.enabledAtLogin === false
            implicitWidth: enableLabel.implicitWidth + Style.space(20)
            implicitHeight: enableLabel.implicitHeight + Style.space(12)

            Rectangle {
              anchors.fill: parent
              radius: root.radius
              color: enableMouse.containsMouse ? root.selectedBackground : "transparent"
              border.width: 1
              border.color: enableMouse.containsMouse ? root.selectedText : root.rule
            }

            Label {
              id: enableLabel
              anchors.centerIn: parent
              text: "Run at login"
              color: enableMouse.containsMouse ? root.selectedText : root.foreground
            }

            MouseArea {
              id: enableMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: enableProc.running = true
            }
          }
        }

        // ---- workspaces
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: false
          Layout.preferredHeight: Style.space(196)
          spacing: Style.space(10)

          Repeater {
            model: root.workspaceCount

            Rectangle {
              id: column
              required property int index
              readonly property int ws: index + 1
              readonly property var apps: root.appsOn(ws)
              readonly property bool target: drop.containsDrag && ghost.fromWs !== ws

              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: root.radius
              color: target ? root.selectedBackground : "transparent"
              border.width: 1
              border.color: target ? root.selectedText : root.rule

              Label {
                id: columnLabel
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.leftMargin: Style.space(12)
                anchors.topMargin: Style.space(10)
                text: column.ws
                color: column.target ? root.selectedText : root.foreground
                opacity: column.target || column.apps.length > 0 ? 1 : 0.52
                font.weight: Font.Medium
              }

              Label {
                anchors.centerIn: parent
                visible: column.apps.length === 0
                text: column.target ? "drop" : "empty"
                color: column.target ? root.selectedText : root.foreground
                opacity: column.target ? 1 : 0.3
              }

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: columnLabel.bottom
                anchors.margins: Style.space(4)
                anchors.topMargin: Style.space(6)

                Repeater {
                  model: column.apps

                  AppRow {
                    required property var modelData
                    width: parent.width
                    app: modelData
                    fromWs: column.ws
                    compact: true
                  }
                }
              }

              DropArea {
                id: drop
                anchors.fill: parent
                keys: ["startup-app"]
                onDropped: (event) => {
                  event.accept()
                  var app = ghost.payload, from = ghost.fromWs, ws = column.ws
                  // Let the dragged row finish its release before the model
                  // that owns it changes.
                  Qt.callLater(function() { root.addApp(ws, app, from) })
                }
              }
            }
          }
        }

        // ---- app library
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              C.TextField {
                id: search
                Layout.fillWidth: true
                leftPadding: Style.space(12)
                rightPadding: 0
                placeholderText: "Search apps, or type a command…"
                text: root.query
                onTextChanged: root.query = text
                color: root.foreground
                placeholderTextColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.52)
                selectionColor: root.selectedBackground
                selectedTextColor: root.selectedText
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                background: null
              }

              Label {
                text: libraryDrop.containsDrag && ghost.fromWs > 0 ? "drop to remove" : root.allApps.length + " apps"
                color: libraryDrop.containsDrag && ghost.fromWs > 0 ? root.selectedText : root.foreground
                opacity: libraryDrop.containsDrag && ghost.fromWs > 0 ? 1 : 0.52
                rightPadding: Style.space(4)
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 1
              color: root.rule
            }

            GridView {
              id: grid
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              cellWidth: Math.floor(width / Math.max(1, Math.floor(width / Style.space(220))))
              cellHeight: Style.space(42)
              model: root.filteredApps
              boundsBehavior: Flickable.StopAtBounds
              interactive: !ghost.Drag.active
              C.ScrollBar.vertical: C.ScrollBar {
                contentItem: Rectangle {
                  implicitWidth: Style.space(3)
                  radius: root.radius
                  color: root.foreground
                  opacity: 0.2
                }
              }

              delegate: AppRow {
                required property var modelData
                width: grid.cellWidth
                app: modelData
                fromWs: 0
              }

              Label {
                anchors.centerIn: parent
                visible: grid.count === 0
                text: "no matches"
                opacity: 0.52
              }
            }
          }

          // Dropping a workspace's app back on the library removes it.
          DropArea {
            id: libraryDrop
            anchors.fill: parent
            keys: ["startup-app"]
            onDropped: (event) => {
              if (ghost.fromWs === 0) return
              event.accept()
              var app = ghost.payload, from = ghost.fromWs
              Qt.callLater(function() { root.removeApp(from, app) })
            }
          }
        }
      }

      // What follows the cursor while dragging: the row being dragged.
      Rectangle {
        id: ghost
        property var payload: null
        property int fromWs: 0

        width: Style.space(180)
        height: Style.space(36)
        z: 100
        visible: Drag.active
        radius: root.radius
        color: root.background
        border.width: 1
        border.color: root.selectedText
        Drag.keys: ["startup-app"]
        Drag.hotSpot.x: Style.space(20)
        Drag.hotSpot.y: height / 2

        Rectangle {
          anchors.fill: parent
          radius: root.radius
          color: root.selectedBackground
        }

        Image {
          id: ghostIcon
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.font.iconLarge
          height: width
          sourceSize: Qt.size(width * 2, height * 2)
          source: ghost.payload ? root.iconFor(ghost.payload.icon) : ""
        }

        Label {
          anchors.left: ghostIcon.right
          anchors.right: parent.right
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: ghost.payload ? ghost.payload.name : ""
          color: root.selectedText
          elide: Text.ElideRight
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // A menu-style row: icon and name, highlighted under the cursor. Drag it
  // onto a workspace. On a workspace, drag it off, right-click it or click
  // its × to remove it.
  component AppRow: Rectangle {
    id: row
    property var app: null
    property int fromWs: 0
    property bool compact: false
    readonly property bool hot: (mouse.containsMouse || removeMouse.containsMouse) && !ghost.Drag.active

    height: compact ? Style.space(32) : Style.space(42)
    radius: root.radius
    color: hot ? root.selectedBackground : "transparent"
    opacity: mouse.drag.active ? 0.4 : 1

    Image {
      id: rowIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: row.compact ? Style.font.icon : Style.font.iconLarge
      height: width
      fillMode: Image.PreserveAspectFit
      sourceSize: Qt.size(width * Screen.devicePixelRatio, height * Screen.devicePixelRatio)
      source: row.app ? root.iconFor(row.app.icon) : ""
      asynchronous: true
    }

    Label {
      anchors.left: rowIcon.right
      anchors.right: remove.visible ? remove.left : parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: row.app ? (row.app.tui && row.fromWs === 0 ? "$ " + row.app.tui : row.app.name) : ""
      color: row.hot ? root.selectedText : root.foreground
      font.pixelSize: row.compact ? Style.font.body : Style.font.title
      font.weight: Font.Medium
      elide: Text.ElideRight
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      drag.target: ghost
      drag.threshold: 4

      onPressed: (event) => {
        if (event.button !== Qt.LeftButton) return
        var p = mapToItem(content, event.x, event.y)
        ghost.x = p.x - ghost.Drag.hotSpot.x
        ghost.y = p.y - ghost.Drag.hotSpot.y
        ghost.payload = row.app
        ghost.fromWs = row.fromWs
      }
      onPositionChanged: if (drag.active && !ghost.Drag.active) ghost.Drag.active = true
      onReleased: (event) => {
        if (!ghost.Drag.active) return
        var accepted = ghost.Drag.drop() !== Qt.IgnoreAction
        ghost.Drag.active = false
        var app = row.app, from = row.fromWs
        if (!accepted && from > 0) Qt.callLater(function() { root.removeApp(from, app) })
      }
      onClicked: (event) => {
        if (event.button === Qt.RightButton && row.fromWs > 0) {
          var app = row.app, from = row.fromWs
          Qt.callLater(function() { root.removeApp(from, app) })
        }
      }
    }

    // ×, in the menu's chevron slot.
    Label {
      id: remove
      visible: row.fromWs > 0 && row.hot
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "×"
      color: removeMouse.containsMouse ? root.selectedText : root.foreground
      opacity: removeMouse.containsMouse ? 1 : 0.5
      font.pixelSize: Style.font.title

      MouseArea {
        id: removeMouse
        anchors.fill: parent
        anchors.margins: -Style.space(6)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          var app = row.app, from = row.fromWs
          Qt.callLater(function() { root.removeApp(from, app) })
        }
      }
    }
  }
}
