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

  // ------------------------------------------------------------ theme

  property var colors: ({})

  function pick(name, fallback) {
    var v = root.colors[name]
    return typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v) ? v : fallback
  }

  readonly property color background: pick("background", "#101315")
  readonly property color foreground: pick("foreground", "#cacccc")
  readonly property color accent: pick("accent", pick("blue", "#5e81ac"))
  readonly property color surface: Qt.tint(background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.06))
  readonly property color border: Qt.tint(background, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18))
  readonly property color muted: Qt.tint(foreground, Qt.rgba(background.r, background.g, background.b, 0.4))
  readonly property color highlight: Qt.tint(background, Qt.rgba(accent.r, accent.g, accent.b, 0.22))
  readonly property string fontFamily: "monospace"

  FileView {
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.colors = root.parseColors(text())
    onFileChanged: reload()
  }

  function parseColors(text) {
    var out = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z_]+)\s*=\s*"([^"]*)"/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

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
        anchors.margins: 24
        spacing: 16

        ColumnLayout {
          spacing: 4
          Text {
            text: "Startup Apps"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 20
            font.bold: true
          }
          Text {
            text: "Drag apps onto a workspace and they open there when you log in. Drag one off, or right-click it, to remove it."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: 13
            Layout.fillWidth: true
            wrapMode: Text.Wrap
          }
        }

        // ---- workspaces
        RowLayout {
          Layout.fillWidth: true
          spacing: 12

          Repeater {
            model: root.workspaceCount

            Rectangle {
              id: square
              required property int index
              readonly property int ws: index + 1

              Layout.fillWidth: true
              Layout.preferredHeight: width
              radius: 12
              color: drop.containsDrag ? root.highlight : root.surface
              border.width: drop.containsDrag ? 2 : 1
              border.color: drop.containsDrag ? root.accent : root.border

              Text {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: 10
                text: square.ws
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: 15
                font.bold: true
              }

              Text {
                anchors.centerIn: parent
                visible: root.appsOn(square.ws).length === 0
                text: "Drop apps here"
                color: root.muted
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: 12
              }

              Flow {
                anchors.fill: parent
                anchors.margins: 10
                anchors.topMargin: 32
                spacing: 6

                Repeater {
                  model: root.appsOn(square.ws)

                  AppTile {
                    required property var modelData
                    app: modelData
                    fromWs: square.ws
                    tileSize: 56
                  }
                }
              }

              DropArea {
                id: drop
                anchors.fill: parent
                keys: ["startup-app"]
                onDropped: (event) => {
                  event.accept()
                  var app = ghost.payload, from = ghost.fromWs, ws = square.ws
                  // Let the dragged tile finish its release before the model
                  // that owns it changes.
                  Qt.callLater(function() { root.addApp(ws, app, from) })
                }
              }
            }
          }
        }

        // ---- app list
        C.TextField {
          id: search
          Layout.fillWidth: true
          placeholderText: "Search apps, or type a terminal command (e.g. btop)"
          text: root.query
          onTextChanged: root.query = text
          color: root.foreground
          placeholderTextColor: root.muted
          font.family: root.fontFamily
          font.pixelSize: 14
          leftPadding: 12
          background: Rectangle {
            radius: 8
            color: root.surface
            border.width: 1
            border.color: search.activeFocus ? root.accent : root.border
          }
        }

        GridView {
          id: grid
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 92)))
          cellHeight: 92
          model: root.filteredApps
          boundsBehavior: Flickable.StopAtBounds
          interactive: !ghost.Drag.active
          C.ScrollBar.vertical: C.ScrollBar {}

          delegate: Item {
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight

            AppTile {
              anchors.centerIn: parent
              app: parent.modelData
              fromWs: 0
              tileSize: 84
            }
          }
        }

        // ---- login status
        RowLayout {
          Layout.fillWidth: true
          visible: root.enabledAtLogin === false
          spacing: 12

          Text {
            Layout.fillWidth: true
            text: "Not set to run at login yet."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 13
          }

          C.Button {
            id: enable
            text: "Run at login"
            onClicked: enableProc.running = true
            contentItem: Text {
              text: enable.text
              color: root.background
              font.family: root.fontFamily
              font.pixelSize: 13
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle { radius: 8; color: root.accent; opacity: enable.hovered ? 1 : 0.9 }
          }
        }
      }

      // What follows the cursor while dragging.
      Rectangle {
        id: ghost
        property var payload: null
        property int fromWs: 0

        width: 56
        height: 56
        radius: 12
        z: 100
        visible: Drag.active
        color: root.highlight
        border.width: 1
        border.color: root.accent
        Drag.keys: ["startup-app"]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        Image {
          anchors.centerIn: parent
          width: 36
          height: 36
          sourceSize: Qt.size(72, 72)
          source: ghost.payload ? root.iconFor(ghost.payload.icon) : ""
        }
      }
    }
  }

  // An app icon with its name. Draggable onto a workspace; on a workspace,
  // dragging it off or right-clicking removes it.
  component AppTile: Item {
    id: tile
    property var app: null
    property int fromWs: 0
    property int tileSize: 56

    width: tileSize
    height: tileSize

    Rectangle {
      anchors.fill: parent
      radius: 10
      color: mouse.containsMouse ? root.highlight : "transparent"
    }

    Image {
      id: icon
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: tile.tileSize > 60 ? 10 : 4
      width: tile.tileSize > 60 ? 40 : 32
      height: width
      sourceSize: Qt.size(width * 2, height * 2)
      source: tile.app ? root.iconFor(tile.app.icon) : ""
      opacity: mouse.drag.active ? 0.3 : 1
    }

    Text {
      anchors.top: icon.bottom
      anchors.topMargin: 4
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - 4
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: tile.app ? (tile.app.tui && tile.fromWs === 0 ? "$ " + tile.app.tui : tile.app.name) : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: tile.tileSize > 60 ? 11 : 10
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
        ghost.x = p.x - ghost.width / 2
        ghost.y = p.y - ghost.height / 2
        ghost.payload = tile.app
        ghost.fromWs = tile.fromWs
      }
      onPositionChanged: if (drag.active && !ghost.Drag.active) ghost.Drag.active = true
      onReleased: (event) => {
        if (!ghost.Drag.active) return
        var accepted = ghost.Drag.drop() !== Qt.IgnoreAction
        ghost.Drag.active = false
        var app = tile.app, from = tile.fromWs
        if (!accepted && from > 0) Qt.callLater(function() { root.removeApp(from, app) })
      }
      onClicked: (event) => {
        if (event.button === Qt.RightButton && tile.fromWs > 0) {
          var app = tile.app, from = tile.fromWs
          Qt.callLater(function() { root.removeApp(from, app) })
        }
      }
    }
  }
}
