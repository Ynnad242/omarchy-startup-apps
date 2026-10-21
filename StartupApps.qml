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
import QtQuick.Shapes
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
  //
  // Colours come from the active Omarchy theme (colors.toml, the file the
  // shell itself reads) and follow `omarchy theme set` live. Text uses the
  // `monospace` alias that `omarchy font set` points at. Corners follow
  // Hyprland's decoration:rounding, with a small floor so cards still read
  // as cards on square themes.

  property var colors: ({})
  property int rounding: 0

  function pick(name, fallback) {
    var v = root.colors[name]
    return typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v) ? v : fallback
  }

  function mix(a, b, amount) {
    return Qt.tint(a, Qt.rgba(b.r, b.g, b.b, amount))
  }

  readonly property bool dark: String(colors.mode || "dark") !== "light"
  readonly property color background: pick("background", dark ? "#1a1b26" : "#f5f5f5")
  readonly property color foreground: pick("foreground", dark ? "#c0caf5" : "#1d1d1d")
  readonly property color accent: pick("accent", pick("blue", "#7aa2f7"))
  readonly property color title: pick("bright_foreground", foreground)
  readonly property color subtle: pick("dark_foreground", mix(foreground, background, 0.45))
  readonly property color base: pick("dark_background", dark ? Qt.darker(background, 1.15) : Qt.darker(background, 1.03))
  readonly property color card: pick("lighter_background", dark ? Qt.lighter(background, 1.3) : Qt.darker(background, 1.04))
  readonly property color hover: mix(card, foreground, 0.08)
  readonly property color line: mix(card, foreground, 0.12)
  readonly property color selection: mix(card, accent, 0.18)
  readonly property color success: pick("green", "#9ece6a")
  readonly property color danger: pick("red", "#f7768e")
  readonly property color onAccent: {
    var l = 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b
    return l > 0.55 ? Qt.darker(background, 1.6) : "#ffffff"
  }

  readonly property string fontFamily: "monospace"
  readonly property string iconFont: "JetBrainsMono Nerd Font"
  readonly property int radius: Math.max(8, rounding)
  readonly property int radiusSmall: Math.max(6, Math.round(radius * 0.7))
  readonly property int ease: 140

  FileView {
    id: colorsFile
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.colors = root.parseColors(text())
    onFileChanged: reload()
  }

  Process {
    id: roundingProc
    command: ["hyprctl", "getoption", "decoration:rounding", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.rounding = Number(JSON.parse(text).int) || 0 } catch (e) {}
      }
    }
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
    colorsFile.reload()
    roundingProc.running = true
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

    Behavior on color { ColorAnimation { duration: root.ease } }

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
        anchors.margins: 28
        spacing: 20

        // ---- header
        RowLayout {
          Layout.fillWidth: true
          spacing: 14

          Rectangle {
            Layout.preferredWidth: 44
            Layout.preferredHeight: 44
            radius: root.radius
            color: root.selection

            Glyph {
              anchors.centerIn: parent
              code: 0xf135
              size: 20
              color: root.accent
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Label {
              text: "Startup Apps"
              color: root.title
              font.pixelSize: 20
              font.weight: Font.DemiBold
            }
            Label {
              Layout.fillWidth: true
              text: "Drag apps onto a workspace. They open there when you log in."
              color: root.subtle
              font.pixelSize: 13
              elide: Text.ElideRight
            }
          }

          // Login status: a quiet pill once it's set up, a button until then.
          Rectangle {
            visible: root.enabledAtLogin === true
            Layout.preferredHeight: 32
            Layout.preferredWidth: loginOn.implicitWidth + 28
            radius: height / 2
            color: root.mix(root.card, root.success, 0.14)

            RowLayout {
              id: loginOn
              anchors.centerIn: parent
              spacing: 8
              Rectangle { width: 8; height: 8; radius: 4; color: root.success }
              Label { text: "Opens at login"; color: root.success; font.pixelSize: 12 }
            }
          }

          PillButton {
            visible: root.enabledAtLogin === false
            text: "Run at login"
            glyph: 0xf011
            primary: true
            onClicked: enableProc.running = true
          }

          IconButton {
            code: 0xf00d
            tip: "Close (Esc)"
            onClicked: root.requestClose()
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
              readonly property var apps: root.appsOn(ws)
              readonly property bool target: drop.containsDrag && ghost.fromWs !== ws

              Layout.fillWidth: true
              Layout.preferredHeight: Math.min(width * 1.05, 200)
              radius: root.radius
              color: target ? root.selection : root.card
              border.width: target ? 2 : 1
              border.color: target ? root.accent : root.line
              scale: target ? 1.03 : 1

              Behavior on color { ColorAnimation { duration: root.ease } }
              Behavior on border.color { ColorAnimation { duration: root.ease } }
              Behavior on scale { NumberAnimation { duration: root.ease; easing.type: Easing.OutCubic } }

              RowLayout {
                id: squareHead
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 12
                spacing: 8

                Rectangle {
                  Layout.preferredWidth: 24
                  Layout.preferredHeight: 24
                  radius: root.radiusSmall
                  color: square.apps.length > 0 || square.target ? root.accent : root.hover

                  Behavior on color { ColorAnimation { duration: root.ease } }

                  Label {
                    anchors.centerIn: parent
                    text: square.ws
                    color: square.apps.length > 0 || square.target ? root.onAccent : root.subtle
                    font.pixelSize: 12
                    font.weight: Font.Bold
                  }
                }

                Label {
                  Layout.fillWidth: true
                  text: "Workspace"
                  color: root.subtle
                  font.pixelSize: 11
                  elide: Text.ElideRight
                }
              }

              // Empty: a dashed drop zone.
              Item {
                anchors.fill: parent
                anchors.margins: 12
                anchors.topMargin: 46
                visible: square.apps.length === 0

                DashedFrame {
                  anchors.fill: parent
                  stroke: square.target ? root.accent : root.line
                  frameRadius: root.radiusSmall
                }

                ColumnLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Glyph {
                    Layout.alignment: Qt.AlignHCenter
                    code: 0xf067
                    size: 14
                    color: square.target ? root.accent : root.subtle
                  }
                  Label {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Drop here"
                    color: square.target ? root.accent : root.subtle
                    font.pixelSize: 11
                  }
                }
              }

              Flow {
                anchors.fill: parent
                anchors.margins: 8
                anchors.topMargin: 44
                spacing: 2

                Repeater {
                  model: square.apps

                  AppTile {
                    required property var modelData
                    app: modelData
                    fromWs: square.ws
                    tileSize: 60
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

        // ---- app library
        Rectangle {
          Layout.fillWidth: true
          Layout.fillHeight: true
          radius: root.radius
          color: root.base
          border.width: 1
          border.color: libraryDrop.containsDrag && ghost.fromWs > 0 ? root.danger : "transparent"

          Behavior on color { ColorAnimation { duration: root.ease } }

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 12

            RowLayout {
              Layout.fillWidth: true
              spacing: 12

              // Search
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                radius: root.radiusSmall
                color: root.card
                border.width: 1
                border.color: search.activeFocus ? root.accent : root.line

                Behavior on border.color { ColorAnimation { duration: root.ease } }

                Glyph {
                  id: searchIcon
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  code: 0xf002
                  size: 13
                  color: search.activeFocus ? root.accent : root.subtle
                }

                C.TextField {
                  id: search
                  anchors.left: searchIcon.right
                  anchors.right: clearSearch.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  leftPadding: 10
                  rightPadding: 6
                  placeholderText: "Search apps, or type a command like btop"
                  text: root.query
                  onTextChanged: root.query = text
                  color: root.foreground
                  placeholderTextColor: root.subtle
                  selectionColor: root.selection
                  selectedTextColor: root.title
                  font.family: root.fontFamily
                  font.pixelSize: 13
                  verticalAlignment: TextInput.AlignVCenter
                  background: null
                }

                IconButton {
                  id: clearSearch
                  anchors.right: parent.right
                  anchors.rightMargin: 4
                  anchors.verticalCenter: parent.verticalCenter
                  visible: search.text.length > 0
                  width: visible ? 30 : 0
                  code: 0xf00d
                  size: 11
                  onClicked: { search.text = ""; search.forceActiveFocus() }
                }
              }

              Label {
                text: libraryDrop.containsDrag && ghost.fromWs > 0
                  ? "Drop to remove"
                  : root.allApps.length + " apps"
                color: libraryDrop.containsDrag && ghost.fromWs > 0 ? root.danger : root.subtle
                font.pixelSize: 12
              }
            }

            GridView {
              id: grid
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 100)))
              cellHeight: 96
              model: root.filteredApps
              boundsBehavior: Flickable.StopAtBounds
              interactive: !ghost.Drag.active
              C.ScrollBar.vertical: C.ScrollBar {
                contentItem: Rectangle {
                  implicitWidth: 4
                  radius: 2
                  color: root.line
                  opacity: parent.active ? 1 : 0.6
                }
              }

              delegate: Item {
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight

                AppTile {
                  anchors.centerIn: parent
                  app: parent.modelData
                  fromWs: 0
                  tileSize: 88
                }
              }

              Label {
                anchors.centerIn: parent
                visible: grid.count === 0
                text: "No apps found"
                color: root.subtle
                font.pixelSize: 13
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

      // What follows the cursor while dragging.
      Rectangle {
        id: ghost
        property var payload: null
        property int fromWs: 0

        width: 60
        height: 60
        radius: root.radius
        z: 100
        visible: Drag.active
        color: root.card
        border.width: 2
        border.color: root.accent
        scale: Drag.active ? 1.08 : 0.8
        Drag.keys: ["startup-app"]
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        Behavior on scale { NumberAnimation { duration: root.ease; easing.type: Easing.OutBack } }

        // A soft drop shadow.
        Rectangle {
          anchors.fill: parent
          anchors.topMargin: 6
          anchors.leftMargin: 2
          anchors.rightMargin: -2
          anchors.bottomMargin: -8
          z: -1
          radius: parent.radius
          color: "#000000"
          opacity: 0.25
        }

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

  // ------------------------------------------------------------ components

  component Label: Text {
    font.family: root.fontFamily
    Behavior on color { ColorAnimation { duration: root.ease } }
  }

  // A Nerd Font icon by code point.
  component Glyph: Text {
    property int code: 0
    property int size: 14
    text: String.fromCodePoint(code)
    font.family: root.iconFont
    font.pixelSize: size
    Behavior on color { ColorAnimation { duration: root.ease } }
  }

  component IconButton: Rectangle {
    id: iconButton
    property int code: 0
    property int size: 14
    property string tip: ""
    signal clicked()

    width: 34
    height: 34
    radius: root.radiusSmall
    color: iconMouse.containsMouse ? root.hover : "transparent"

    Behavior on color { ColorAnimation { duration: root.ease } }

    Glyph {
      anchors.centerIn: parent
      code: iconButton.code
      size: iconButton.size
      color: iconMouse.containsMouse ? root.title : root.subtle
    }

    MouseArea {
      id: iconMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: iconButton.clicked()
    }
  }

  component PillButton: Rectangle {
    id: pill
    property string text: ""
    property int glyph: 0
    property bool primary: false
    signal clicked()

    implicitWidth: pillRow.implicitWidth + 28
    implicitHeight: 32
    radius: height / 2
    color: primary ? (pillMouse.containsMouse ? Qt.lighter(root.accent, 1.1) : root.accent)
                   : (pillMouse.containsMouse ? root.hover : root.card)

    Behavior on color { ColorAnimation { duration: root.ease } }

    RowLayout {
      id: pillRow
      anchors.centerIn: parent
      spacing: 8
      Glyph {
        visible: pill.glyph > 0
        code: pill.glyph
        size: 12
        color: pill.primary ? root.onAccent : root.foreground
      }
      Label {
        text: pill.text
        color: pill.primary ? root.onAccent : root.foreground
        font.pixelSize: 12
        font.weight: Font.DemiBold
      }
    }

    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.clicked()
    }
  }

  // A rounded dashed outline.
  component DashedFrame: Shape {
    id: frame
    property color stroke: "white"
    property real frameRadius: 6
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeColor: frame.stroke
      strokeWidth: 1.5
      strokeStyle: ShapePath.DashLine
      dashPattern: [4, 3]
      fillColor: "transparent"
      startX: frame.frameRadius
      startY: 0
      PathLine { x: frame.width - frame.frameRadius; y: 0 }
      PathArc { x: frame.width; y: frame.frameRadius; radiusX: frame.frameRadius; radiusY: frame.frameRadius }
      PathLine { x: frame.width; y: frame.height - frame.frameRadius }
      PathArc { x: frame.width - frame.frameRadius; y: frame.height; radiusX: frame.frameRadius; radiusY: frame.frameRadius }
      PathLine { x: frame.frameRadius; y: frame.height }
      PathArc { x: 0; y: frame.height - frame.frameRadius; radiusX: frame.frameRadius; radiusY: frame.frameRadius }
      PathLine { x: 0; y: frame.frameRadius }
      PathArc { x: frame.frameRadius; y: 0; radiusX: frame.frameRadius; radiusY: frame.frameRadius }
    }
  }

  // An app icon with its name. Draggable onto a workspace; on a workspace,
  // dragging it off, right-clicking it or pressing its × removes it.
  component AppTile: Item {
    id: tile
    property var app: null
    property int fromWs: 0
    property int tileSize: 60
    readonly property bool large: tileSize > 70
    readonly property bool hovered: mouse.containsMouse || removeMouse.containsMouse

    width: tileSize
    height: large ? 88 : 64

    Rectangle {
      anchors.fill: parent
      radius: root.radiusSmall
      color: tile.hovered && !mouse.drag.active ? root.hover : "transparent"
      Behavior on color { ColorAnimation { duration: root.ease } }
    }

    // A soft plate behind the icon, so icons of every shape line up.
    Rectangle {
      id: plate
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: tile.large ? 10 : 4
      width: tile.large ? 48 : 38
      height: width
      radius: root.radiusSmall
      color: tile.large ? "transparent" : root.mix(root.card, root.foreground, 0.05)
      scale: tile.hovered && !mouse.drag.active ? 1.08 : 1
      opacity: mouse.drag.active ? 0.3 : 1

      Behavior on scale { NumberAnimation { duration: root.ease; easing.type: Easing.OutCubic } }

      Image {
        anchors.centerIn: parent
        width: tile.large ? 40 : 28
        height: width
        sourceSize: Qt.size(width * 2, height * 2)
        source: tile.app ? root.iconFor(tile.app.icon) : ""
        asynchronous: true
      }
    }

    Label {
      anchors.top: plate.bottom
      anchors.topMargin: tile.large ? 6 : 3
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - 6
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: tile.app ? (tile.app.tui && tile.fromWs === 0 ? "$ " + tile.app.tui : tile.app.name) : ""
      color: tile.hovered ? root.title : root.foreground
      font.pixelSize: tile.large ? 11 : 10
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

    // × badge on hover, for workspace tiles.
    Rectangle {
      visible: tile.fromWs > 0 && tile.hovered && !mouse.drag.active
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 2
      anchors.topMargin: 0
      width: 18
      height: 18
      radius: 9
      color: removeMouse.containsMouse ? root.danger : root.mix(root.card, root.danger, 0.6)

      Glyph {
        anchors.centerIn: parent
        code: 0xf00d
        size: 9
        color: root.background
      }

      MouseArea {
        id: removeMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          var app = tile.app, from = tile.fromWs
          Qt.callLater(function() { root.removeApp(from, app) })
        }
      }
    }
  }
}
