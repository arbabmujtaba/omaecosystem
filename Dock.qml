import QtQuick 6.11
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons

// OmaEcosystem: a phone-shaped card on the right of the screen. The screen in
// the middle of the phone is a hole: the layer surface is transparent and
// click-through there, and bin/omaecosystem pins a borderless scrcpy window
// exactly underneath it. Everything around the screen (bezel, header, nav
// keys, clipboard and file actions) is drawn here.
Item {
  id: root

  // Injected by the shell's panel loader.
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.arbabmujtaba.omaecosystem"
  readonly property string layerNamespace: "omaecosystem"
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }
  readonly property string cli: pluginDir + "/bin/omaecosystem"
  readonly property string cachePath: {
    var state = Quickshell.env("XDG_STATE_HOME")
    return (state && state !== "" ? state : Quickshell.env("HOME") + "/.local/state") + "/omaecosystem/device.json"
  }

  // ---- lifecycle (shell contract: opened / open(payload) / close()) -------

  property bool opened: false
  property var payloadSettings: ({})

  function open(payload) {
    try {
      var p = payload ? JSON.parse(payload) : null
      if (p && typeof p === "object") payloadSettings = p
    } catch (e) {}
    if (opened) return
    targetScreen = pickScreen()
    opened = true
    toast("", false)
    enterAnim.restart()
    connectPhone()
  }

  function close() {
    if (!opened) return
    opened = false
    stopMirror()
  }

  // Close from inside the dock: go through the shell so the bar icon updates.
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  Component.onDestruction: {
    if (mirrorProc.running) mirrorProc.write("quit\n")
  }

  // ---- settings (inline on the plugin's shell.json entry) ----------------

  function findEntry(config) {
    if (!config || typeof config !== "object") return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; layout && s < sections.length; s++) {
      var list = layout[sections[s]]
      for (var i = 0; Array.isArray(list) && i < list.length; i++)
        if (list[i] && list[i].id === pluginId) return list[i]
    }
    var plugins = config.plugins
    for (var j = 0; Array.isArray(plugins) && j < plugins.length; j++)
      if (plugins[j] && plugins[j].id === pluginId) return plugins[j]
    return null
  }
  readonly property var entry: findEntry(shell ? shell.shellConfig : null)
  function setting(name, fallback) {
    var v = entry && entry[name] !== undefined && entry[name] !== null ? entry[name] : payloadSettings[name]
    return v === undefined || v === null ? fallback : v
  }
  readonly property real screenInches: {
    var n = Number(setting("screenInches", 5))
    return isFinite(n) ? Math.max(3, Math.min(9, n)) : 5
  }
  readonly property bool reserveSpace: setting("reserveSpace", false) === true
  readonly property bool phoneScreenOff: setting("phoneScreenOff", false) === true
  // Hotspot overrides; empty means learned from the phone (see bin/omaecosystem).
  readonly property string hotspotBluetooth: String(setting("hotspotBluetooth", "") || "").trim()
  readonly property string hotspotWifi: String(setting("hotspotWifi", "") || "").trim()
  readonly property bool keepWireless: setting("keepWireless", true) !== false

  // ---- phone + mirror state ----------------------------------------------

  property var device: ({ name: "Phone", width: 1080, height: 2340, battery: -1, charging: false, serial: "" })
  // idle | connecting | starting | running | stopped | error
  property string phase: "idle"
  property string phaseMessage: ""
  property string phaseCode: ""
  // First-time setup help instead of a bare error when no phone is set up yet.
  readonly property bool showGuide: phase === "error"
    && (phaseCode === "no-device" || phaseCode === "unauthorized" || phaseCode === "missing-tool")
  property bool restartWanted: false
  readonly property bool mirrorLive: opened && phase === "running"
  readonly property bool busyConnecting: phase === "connecting" || phase === "starting"

  FileView {
    path: root.cachePath
    printErrors: false
    onLoaded: {
      try {
        var d = JSON.parse(text())
        if (d && d.width > 0 && d.height > 0 && root.device.serial === "")
          root.device = Object.assign({}, root.device, { name: d.name || root.device.name, width: d.width, height: d.height })
      } catch (e) {}
    }
  }

  function connectPhone() {
    if (!opened) return
    phase = "connecting"
    phaseMessage = ""
    phaseCode = ""
    if (mirrorProc.running) { restartWanted = true; stopMirror(); return }
    if (!probeProc.running) probeProc.running = true
  }

  function startMirror() {
    if (!opened) return
    if (mirrorProc.running) { restartWanted = true; stopMirror(); return }
    var r = holeRect()
    var cmd = [cli, "mirror", "--namespace", layerNamespace,
      "--x", String(r.x), "--y", String(r.y), "--w", String(r.w), "--h", String(r.h),
      "--max-size", String(Math.round(holeH * dpr))]
    if (device.serial) cmd.push("--serial", device.serial)
    if (phoneScreenOff) cmd.push("--screen-off")
    mirrorProc.command = cmd
    mirrorProc.running = true
  }

  function stopMirror() {
    if (!mirrorProc.running) return
    mirrorProc.write("quit\n")
    killTimer.restart()
  }

  function holeRect() {
    return { x: Math.round(card.x + holeX), y: Math.round(card.y + holeY), w: holeW, h: holeH }
  }

  Process {
    id: probeProc
    command: [root.cli, "probe"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = null
        try { r = JSON.parse(String(text).trim().split("\n").pop()) } catch (e) {}
        if (!root.opened) return
        if (r && r.ok) {
          var keepSerial = root.device.serial
          root.device = r
          if (root.phase === "connecting") Qt.callLater(root.startMirror)
          else if (keepSerial !== r.serial && root.phase === "running") root.connectPhone()
        } else if (root.phase === "connecting") {
          root.phase = "error"
          root.phaseMessage = r && r.message ? r.message : "Could not reach the phone"
          root.phaseCode = r && r.code ? r.code : ""
        }
      }
    }
  }

  Process {
    id: mirrorProc
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        var ev = null
        try { ev = JSON.parse(line) } catch (e) { return }
        if (!ev || ev.event !== "state" || !root.opened) return
        root.phase = ev.state
        root.phaseMessage = ev.message || ""
        root.phaseCode = ev.code || ""
      }
    }
    onExited: function(code) {
      killTimer.stop()
      if (root.restartWanted && root.opened) {
        root.restartWanted = false
        root.phase = "connecting"
        if (!probeProc.running) probeProc.running = true
        return
      }
      root.restartWanted = false
      if (!root.opened) { root.phase = "idle"; return }
      if (root.phase === "running" || root.busyConnecting) {
        root.phase = code === 0 ? "stopped" : "error"
        if (!root.phaseMessage) root.phaseMessage = code === 0 ? "Mirror closed" : "Mirror stopped unexpectedly"
      }
    }
  }

  // The helper normally exits within a second of `quit`; make sure it does.
  Timer {
    id: killTimer
    interval: 5000
    onTriggered: if (mirrorProc.running) mirrorProc.running = false
  }

  // Keep the mirror glued to the hole if the dock is resized while live.
  Timer {
    id: rectTimer
    interval: 120
    onTriggered: {
      if (!mirrorProc.running) return
      var r = root.holeRect()
      mirrorProc.write("rect " + r.x + " " + r.y + " " + r.w + " " + r.h + "\n")
    }
  }
  onHoleWChanged: rectTimer.restart()
  onHoleHChanged: rectTimer.restart()

  // Battery refresh while docked.
  Timer {
    interval: 60000
    repeat: true
    running: root.mirrorLive
    onTriggered: if (!probeProc.running) probeProc.running = true
  }

  // ---- one-click actions --------------------------------------------------

  // The one-click tiles under the phone, two rows of three.
  readonly property var actions: [
    { key: "to", glyph: "󰆏", label: "To phone", hint: "Copy clipboard", args: ["clip-to-phone"] },
    { key: "from", glyph: "󰆒", label: "From phone", hint: "Get clipboard", args: ["clip-from-phone"] },
    { key: "files", glyph: "󰕒", label: "Send files", hint: "To Download", args: ["send-files"] },
    { key: "shot", glyph: "󰄀", label: "Screenshot", hint: "Copy + save", args: ["screenshot"] },
    { key: "link", glyph: "󰏌", label: "Open link", hint: "Clipboard URL", args: ["open-link"] },
    { key: "hotspot", glyph: "󰀃", label: "Hotspot", hint: "Join phone Wi-Fi", args: ["hotspot"] }
  ]

  property string busyAction: ""
  property string flashKey: ""
  property bool flashOk: true
  property int flashSeq: 0
  property string toastText: ""
  property bool toastOk: true

  function toast(text, ok) {
    toastText = text
    toastOk = ok !== false
    if (text) toastTimer.restart()
  }

  Timer {
    id: toastTimer
    interval: 4500
    onTriggered: root.toastText = ""
  }

  function runAction(name, args) {
    if (actionProc.running) return
    busyAction = name
    toast("", true)
    var cmd = [cli].concat(args)
    if (name === "hotspot") {
      if (hotspotBluetooth) cmd.push("--bt-mac", hotspotBluetooth)
      if (hotspotWifi) cmd.push("--wifi", hotspotWifi)
    }
    if (device.serial) cmd.push("--serial", device.serial)
    actionProc.command = cmd
    actionProc.lastResult = null
    actionProc.running = true
  }

  function sendKey(key) { runQuick(["key", key]) }

  // Fire-and-forget phone commands (nav keys, shade, lock): no spinner.
  function runQuick(args) {
    if (keyProc.running) return
    var cmd = [cli].concat(args)
    if (device.serial) cmd.push("--serial", device.serial)
    keyProc.command = cmd
    keyProc.running = true
  }

  Process {
    id: actionProc
    property var lastResult: null
    stdout: SplitParser {
      onRead: function(line) {
        var ev = null
        try { ev = JSON.parse(line) } catch (e) { return }
        if (!ev) return
        if (ev.event === "progress") {
          root.toastText = ev.message ? ev.message
            : (ev.total > 1 ? "Sending " + ev.index + "/" + ev.total + " · " : "Sending ") + ev.name
          root.toastOk = true
          toastTimer.stop()
        } else if (ev.ok !== undefined) {
          actionProc.lastResult = ev
        }
      }
    }
    onExited: function(code) {
      var r = actionProc.lastResult
      var key = root.busyAction
      root.busyAction = ""
      if (!(r && r.cancelled)) {
        root.flashKey = key
        root.flashOk = !!(r && r.ok)
        root.flashSeq++
      }
      if (r && r.cancelled) { root.toast("", true); return }
      if (r) root.toast(r.message || (r.ok ? "Done" : "Failed"), r.ok === true)
      else root.toast("Something went wrong (exit " + code + ")", false)
    }
  }

  Process { id: keyProc }

  // ---- wireless keeper ----------------------------------------------------

  // The panel is keepLoaded, so this runs for as long as the shell does, docked
  // or not: it keeps wireless ADB up and arms it when the phone is plugged in.
  // Closing its stdin (the shell going away) stops it.
  property string keeperState: ""
  Process {
    id: keeperProc
    command: [root.cli, "keeper"]
    stdinEnabled: true
    running: root.keepWireless
    stdout: SplitParser {
      onRead: function(line) {
        var ev = null
        try { ev = JSON.parse(line) } catch (e) { return }
        if (!ev || ev.event !== "keeper") return
        root.keeperState = ev.state
        // Wireless just came back: if the dock is showing "no phone", try again.
        if ((ev.state === "connected" || ev.state === "armed") && root.opened
            && root.phase === "error" && root.phaseCode === "no-device")
          root.connectPhone()
      }
    }
    onExited: function(code) { if (root.keepWireless) keeperRestart.restart() }
  }
  // The restart timers below assign `running`, which drops the binding above,
  // so follow the setting explicitly too.
  onKeepWirelessChanged: {
    if (!keepWireless) keeperRestart.stop()
    keeperProc.running = keepWireless
  }
  Timer {
    id: keeperRestart
    interval: 30000
    onTriggered: if (root.keepWireless && !keeperProc.running) keeperProc.running = true
  }
  // A shell hot reload (plugin install/update) can stop the keeper without an
  // exit signal reaching us; check now and then that it is still up.
  Timer {
    interval: 60000
    repeat: true
    running: root.keepWireless
    onTriggered: if (!keeperProc.running && !keeperRestart.running) keeperProc.running = true
  }

  // ---- geometry -----------------------------------------------------------

  property var targetScreen: null
  function pickScreen() {
    var screens = Quickshell.screens
    var focused = Hyprland.focusedMonitor
    for (var i = 0; focused && i < screens.length; i++)
      if (screens[i].name === focused.name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  readonly property real dpr: targetScreen && targetScreen.devicePixelRatio > 0 ? targetScreen.devicePixelRatio : 1
  // Logical pixels per millimetre of the real panel (falls back to 96 dpi).
  readonly property real ppmm: {
    var d = targetScreen ? Number(targetScreen.physicalPixelDensity) : 0
    return d >= 1.5 && d <= 40 ? d : 96 / 25.4
  }
  readonly property real ratio: {
    var w = Number(device.width), h = Number(device.height)
    if (!(w > 0 && h > 0)) return 2.166
    return Math.max(w, h) / Math.min(w, h)
  }

  readonly property int gap: Math.max(6, Style.gapsOut)
  readonly property int pad: Style.space(14)
  readonly property int headerH: Style.space(30)
  readonly property int bodyGap: Style.space(10)
  readonly property int bezel: Style.space(8)
  readonly property int navH: Style.space(32)
  readonly property int tileH: Style.space(58)
  readonly property int toastH: Style.space(16)
  readonly property int rowGap: Style.space(8)
  // Even vertical rhythm: header, phone, nav keys, tiles, status line.
  readonly property int tileGap: Style.space(7)
  readonly property int tilesH: 2 * tileH + tileGap
  readonly property int chromeH: pad + headerH + bodyGap + 2 * bezel + Style.space(2) + navH
    + rowGap + tilesH + rowGap + toastH + pad
  readonly property int navY: bodyY + bodyH + Style.space(2)
  readonly property int tilesY: navY + navH + rowGap
  readonly property int toastY: tilesY + tilesH + rowGap
  readonly property real availableH: dock.height > 100 ? dock.height
    : (targetScreen ? targetScreen.height - Style.space(60) : 900)

  // The screen at real size, shrunk if the whole dock wouldn't fit.
  readonly property real inchHoleH: screenInches * 25.4 * ratio / Math.sqrt(1 + ratio * ratio) * ppmm
  readonly property int holeH: Math.floor(Math.max(240, Math.min(inchHoleH, availableH - chromeH)))
  readonly property int holeW: Math.round(holeH / ratio)
  readonly property int bodyW: holeW + 2 * bezel
  readonly property int bodyH: holeH + 2 * bezel
  readonly property int bodyY: pad + headerH + bodyGap
  readonly property int holeX: pad + bezel
  readonly property int holeY: bodyY + bezel
  readonly property int cardW: Math.max(bodyW + 2 * pad, Style.space(250))
  readonly property int cardH: chromeH + holeH
  readonly property int screenRadius: Math.round(holeW * 0.085)
  readonly property int bodyRadius: screenRadius + bezel
  readonly property int revealGlow: Style.space(26)

  // Entrance progress for the i-th element (0 header, 1 keys, 2.. tiles, last status).
  function stagger(i) {
    var t = (card.enter - i * 0.09) / 0.55
    return Math.max(0, Math.min(1, t))
  }
  readonly property int cardRadius: Style.cornerRadius
  readonly property int borderW: Math.max(1, Style.space(2))

  // ---- palette ------------------------------------------------------------

  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.07)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.14)
  readonly property color glass: "#060708"
  readonly property string fontFamily: Style.font.family

  function batteryIcon(level, charging) {
    if (charging) return "󰂄"
    if (level < 0) return ""
    var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return icons[Math.max(0, Math.min(10, Math.round(level / 10)))]
  }

  // ---- the dock surface ---------------------------------------------------

  PanelWindow {
    id: dock

    screen: root.targetScreen
    visible: root.opened || card.slide < 1
    color: "transparent"

    WlrLayershell.namespace: root.layerNamespace
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: root.reserveSpace && root.opened ? root.cardW + root.gap : 0

    anchors { top: true; bottom: true; right: true }
    margins { top: root.gap; bottom: root.gap; right: root.gap }
    implicitWidth: root.cardW

    // Clicks land on the card except the live screen, which belongs to the
    // scrcpy window underneath. Everything outside the card is click-through.
    mask: Region {
      item: card
      Region {
        intersection: Intersection.Subtract
        x: Math.round(card.x + root.holeX)
        y: Math.round(card.y + root.holeY)
        width: root.mirrorLive ? root.holeW : 0
        height: root.mirrorLive ? root.holeH : 0
      }
    }

    Item {
      id: card
      property real slide: root.opened ? 0 : 1
      Behavior on slide { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

      // 0 -> 1 after each open; header, keys, tiles and status line ride in on it.
      property real enter: 0
      NumberAnimation on enter {
        id: enterAnim
        running: false
        from: 0; to: 1; duration: 700; easing.type: Easing.OutCubic
      }

      x: Math.round(slide * (width + root.gap + 2))
      y: 0
      width: root.cardW
      height: root.cardH
      opacity: 1 - slide * 0.6

      // Card background with a cut-out for the screen, so nothing ever
      // paints over the mirror. Outer card, inner hole = odd-even fill.
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          fillRule: ShapePath.OddEvenFill
          fillColor: root.bg
          strokeColor: "transparent"
          strokeWidth: 0
          PathRectangle {
            x: 0; y: 0; width: card.width; height: card.height
            radius: root.cardRadius
          }
          PathRectangle {
            x: root.holeX - root.bezel; y: root.holeY - root.bezel
            width: root.bodyW; height: root.bodyH
            radius: root.bodyRadius
          }
        }
        // Theme border around the card.
        ShapePath {
          fillColor: "transparent"
          strokeColor: Color.popups.border
          strokeWidth: root.borderW
          PathRectangle {
            x: root.borderW / 2; y: root.borderW / 2
            width: card.width - root.borderW; height: card.height - root.borderW
            radius: root.cardRadius
          }
        }
        // Phone body: the bezel ring around the screen.
        ShapePath {
          fillRule: ShapePath.OddEvenFill
          fillColor: root.glass
          strokeColor: root.hairline
          strokeWidth: 1
          PathRectangle {
            x: root.holeX - root.bezel; y: root.holeY - root.bezel
            width: root.bodyW; height: root.bodyH
            radius: root.bodyRadius
          }
          PathRectangle {
            x: root.holeX; y: root.holeY
            width: root.holeW; height: root.holeH
            radius: root.screenRadius
          }
        }
      }

      // Side keys, for the silhouette.
      Rectangle {
        x: root.holeX - root.bezel + root.bodyW - 1
        y: root.bodyY + root.bodyH * 0.2
        width: Style.space(3); height: root.bodyH * 0.12; radius: 2
        color: root.hairline
      }
      Rectangle {
        x: root.holeX - root.bezel + root.bodyW - 1
        y: root.bodyY + root.bodyH * 0.36
        width: Style.space(3); height: root.bodyH * 0.07; radius: 2
        color: root.hairline
      }

      // -- header -----------------------------------------------------------
      Item {
        x: root.pad; y: root.pad - (1 - root.stagger(0)) * Style.space(8)
        opacity: root.stagger(0)
        width: card.width - 2 * root.pad
        height: root.headerH

        Rectangle {
          id: statusDot
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(8); height: width; radius: width / 2
          color: root.mirrorLive ? root.accent : (root.phase === "error" ? root.urgent : root.dim)
          Behavior on color { ColorAnimation { duration: 300 } }
          // Blinks while mirroring (slow, like a live light), faster while connecting.
          SequentialAnimation on opacity {
            running: root.opened && (root.mirrorLive || root.busyConnecting)
            loops: Animation.Infinite
            NumberAnimation { to: 0.2; duration: root.mirrorLive ? 700 : 380; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: root.mirrorLive ? 700 : 380; easing.type: Easing.InOutSine }
            onRunningChanged: if (!running) statusDot.opacity = 1
          }

          // A soft halo ripples out of the light while live.
          Rectangle {
            id: halo
            anchors.centerIn: parent
            width: parent.width; height: width; radius: width / 2
            color: "transparent"
            border.width: Math.max(1, Style.space(1.5))
            border.color: root.accent
            opacity: 0
            visible: root.mirrorLive
            ParallelAnimation {
              running: root.opened && root.mirrorLive
              loops: Animation.Infinite
              NumberAnimation { target: halo; property: "scale"; from: 1; to: 2.8; duration: 1400; easing.type: Easing.OutCubic }
              NumberAnimation { target: halo; property: "opacity"; from: 0.7; to: 0; duration: 1400; easing.type: Easing.OutCubic }
            }
          }
        }

        Column {
          anchors.left: statusDot.right
          anchors.leftMargin: Style.space(9)
          anchors.right: headerButtons.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: 0

          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            width: parent.width
            text: root.device.name || "Phone"
            color: root.fg
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            width: parent.width
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              var s = root.mirrorLive ? (root.device.link === "usb" ? "Mirroring · USB" : "Mirroring · Wi-Fi")
                : root.phase === "connecting" ? "Connecting…"
                : root.phase === "starting" ? "Starting mirror…"
                : root.phase === "error" ? "Not connected"
                : root.phase === "stopped" ? "Paused" : ""
              var b = Number(root.device.battery)
              if (b >= 0) s += (s ? "  ·  " : "") + root.batteryIcon(b, root.device.charging) + " " + b + "%"
              return s
            }
          }
        }

        Row {
          id: headerButtons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          IconButton {
            glyph: "󰂚"
            tip: "Notifications"
            onClicked: root.runQuick(["notifications"])
          }
          IconButton {
            glyph: "󰌾"
            tip: "Lock phone"
            onClicked: root.sendKey("power")
          }
          IconButton {
            id: closeButton
            glyph: "󰅖"
            tip: "Undock"
            onClicked: root.requestClose()
          }
        }
      }

      // -- screen placeholder (connecting / error / paused) -------------------
      Item {
        id: placeholder
        x: root.holeX; y: root.holeY
        width: root.holeW; height: root.holeH
        clip: true
        visible: curtain.y > -curtain.height - root.revealGlow

        // When the mirror goes live the curtain lifts off the screen with a
        // glowing edge; it drops back down when the mirror pauses.
        Rectangle {
          id: curtain
          width: parent.width
          height: parent.height
          radius: root.screenRadius
          y: root.mirrorLive ? -height - root.revealGlow : 0
          Behavior on y { NumberAnimation { duration: 620; easing.type: Easing.InOutCubic } }
          gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(root.accent.r * 0.18, root.accent.g * 0.18, root.accent.b * 0.18, 1) }
            GradientStop { position: 1.0; color: "#050506" }
          }

          Rectangle {
            anchors.top: parent.bottom
            width: parent.width
            height: root.revealGlow
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.85) }
              GradientStop { position: 1.0; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0) }
            }
          }

        // camera punch hole
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: Style.space(12)
          width: Style.space(9); height: width; radius: width / 2
          color: "#000000"
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.08)
        }

        // First-time setup guide, shown in place of the error.
        Column {
          id: guide
          visible: root.showGuide
          anchors.centerIn: parent
          width: parent.width - Style.space(30)
          spacing: Style.space(9)

          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            text: "󰄜"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.space(34)
          }
          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.phaseCode === "missing-tool" ? "One thing to install" : "Let's connect your phone"
            color: "#ffffff"
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          // USB is the recommended path, say so up front.
          Rectangle {
            visible: root.phaseCode !== "missing-tool"
            width: parent.width
            height: usbTip.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.14)
            border.width: 1
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.5)
            Text {
              textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
              id: usbTip
              anchors.centerIn: parent
              width: parent.width - Style.space(14)
              wrapMode: Text.WordWrap
              text: "󰕓  USB cable recommended: the fastest, smoothest mirror with the least lag."
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.phaseCode === "missing-tool"
              ? [root.phaseMessage, "Then press Try again."]
              : root.phaseCode === "unauthorized"
              ? ["Unlock the phone.", "Tap Allow on “Allow USB debugging?” (tick Always allow).", "Press Try again."]
              : ["On the phone: Settings › About phone › Software information, tap Build number 7 times.",
                 "Settings › Developer options › turn on USB debugging.",
                 "Plug the phone into the laptop and tap Allow on the phone.",
                 "Wireless instead: turn on Wireless debugging, then run adb pair once."]
            delegate: Row {
              required property var modelData
              required property int index
              width: guide.width
              spacing: Style.space(7)
              Rectangle {
                width: Style.space(17); height: width; radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.35)
                Text {
                  textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
                  anchors.centerIn: parent
                  text: String(index + 1)
                  color: Qt.rgba(1, 1, 1, 0.8)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 1
                }
              }
              Text {
                textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
                width: guide.width - Style.space(24)
                wrapMode: Text.WordWrap
                text: modelData
                color: Qt.rgba(1, 1, 1, 0.75)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle {
            width: guideRetry.implicitWidth + Style.space(30)
            height: Style.space(30)
            radius: height / 2
            color: guideMouse.pressed ? Qt.darker(root.accent, 1.2) : root.accent
            scale: guideMouse.pressed ? 0.96 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }
            Text {
              textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
              id: guideRetry
              anchors.centerIn: parent
              text: "󰑐  Try again"
              color: root.bg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            MouseArea {
              id: guideMouse
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.connectPhone()
            }
          }
        }

        Column {
          visible: !root.showGuide
          anchors.centerIn: parent
          width: parent.width - Style.space(36)
          spacing: Style.space(14)

          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phase === "error" ? "󰀦" : "󰄜"
            property real bob: 0
            transform: Translate { y: parent ? -Style.space(5) * Math.sin(phoneIcon.bob * Math.PI) : 0 }
            id: phoneIcon
            NumberAnimation on bob {
              running: placeholder.visible && root.busyConnecting
              from: 0; to: 1; duration: 1300; loops: Animation.Infinite; easing.type: Easing.InOutSine
            }
            color: root.phase === "error" ? root.urgent : Qt.rgba(1, 1, 1, 0.85)
            font.family: root.fontFamily
            font.pixelSize: Style.space(46)
          }

          // three-dot loader
          Row {
            visible: root.busyConnecting || root.phase === "idle"
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(7)
            Repeater {
              model: 3
              delegate: Rectangle {
                id: dot
                required property int index
                width: Style.space(7); height: width; radius: width / 2
                color: root.accent
                opacity: 0.25
                SequentialAnimation on opacity {
                  running: placeholder.visible && (root.busyConnecting || root.phase === "idle")
                  loops: Animation.Infinite
                  PauseAnimation { duration: dot.index * 160 }
                  NumberAnimation { to: 1; duration: 320 }
                  NumberAnimation { to: 0.25; duration: 320 }
                  PauseAnimation { duration: (2 - dot.index) * 160 }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: Qt.rgba(1, 1, 1, 0.9)
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            text: root.phase === "error" ? "Can't reach the phone"
              : root.phase === "stopped" ? "Mirror paused"
              : root.phase === "starting" ? "Opening screen…" : "Connecting…"
          }

          Text {
            textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
            visible: text !== ""
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: root.phase === "error" ? root.phaseMessage
              : root.phase === "stopped" ? (root.phaseMessage === "Mirror closed" ? "The mirror window was closed" : root.phaseMessage)
              : "Wireless ADB · " + (root.device.serial || "searching")
          }

          Rectangle {
            visible: root.phase === "error" || root.phase === "stopped"
            anchors.horizontalCenter: parent.horizontalCenter
            width: retryLabel.implicitWidth + Style.space(30)
            height: Style.space(32)
            radius: height / 2
            color: retryMouse.pressed ? Qt.darker(root.accent, 1.2) : root.accent
            scale: retryMouse.pressed ? 0.96 : 1
            Behavior on scale { NumberAnimation { duration: 90 } }
            Text {
              textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
              id: retryLabel
              anchors.centerIn: parent
              text: (root.phase === "stopped" ? "󰑐  Reconnect" : "󰑐  Try again")
              color: root.bg
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            MouseArea {
              id: retryMouse
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.connectPhone()
            }
          }
        }
        }
      }

      // -- navigation keys ----------------------------------------------------
      Row {
        id: navRow
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.navY + (1 - root.stagger(1)) * Style.space(10)
        height: root.navH
        spacing: Style.space(34)
        opacity: root.stagger(1) * (root.mirrorLive ? 1 : 0.35)
        Behavior on opacity { NumberAnimation { duration: 200 } }

        NavKey { kind: "back"; onClicked: root.sendKey("back") }
        NavKey { kind: "home"; onClicked: root.sendKey("home") }
        NavKey { kind: "recents"; onClicked: root.sendKey("recents") }
      }

      // -- actions -------------------------------------------------------------
      Grid {
        id: tiles
        x: root.pad
        y: root.tilesY
        width: card.width - 2 * root.pad
        height: root.tilesH
        columns: 3
        spacing: root.tileGap
        readonly property real tileW: (width - 2 * spacing) / 3

        Repeater {
          model: root.actions
          delegate: ActionTile {
            required property var modelData
            required property int index
            width: tiles.tileW; height: root.tileH
            key: modelData.key
            glyph: modelData.glyph; label: modelData.label; hint: modelData.hint
            order: 2 + index * 0.45
            busy: root.busyAction === modelData.key
            enabled: root.busyAction === ""
            onClicked: root.runAction(modelData.key, modelData.args)
          }
        }
      }

      // -- status line ---------------------------------------------------------
      Text {
        textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
        x: root.pad
        id: toastLine
        y: root.toastY + toastNudge
        property real toastNudge: 0
        opacity: root.stagger(5)
        onTextChanged: toastIn.restart()
        ParallelAnimation {
          id: toastIn
          NumberAnimation { target: toastLine; property: "toastNudge"; from: Style.space(5); to: 0; duration: 260; easing.type: Easing.OutCubic }
          NumberAnimation { target: toastLine; property: "scale"; from: 0.97; to: 1; duration: 260; easing.type: Easing.OutCubic }
        }
        width: card.width - 2 * root.pad
        height: root.toastH
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideMiddle
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        color: root.toastText === "" ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.38)
          : (root.toastOk ? root.accent : root.urgent)
        text: root.toastText !== "" ? (root.toastOk ? "󰄬  " : "󰀦  ") + root.toastText
          : "Drop files on the screen to send them too"
      }
    }
  }

  // ---- small components ---------------------------------------------------

  component IconButton: Rectangle {
    id: ib
    property string glyph: ""
    property string tip: ""
    signal clicked()
    width: Style.space(26); height: width; radius: width / 2
    color: ibMouse.pressed ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
      : (ibMouse.containsMouse ? root.faint : "transparent")
    scale: ibMouse.pressed ? 0.9 : 1
    Behavior on scale { NumberAnimation { duration: 90 } }
    Behavior on color { ColorAnimation { duration: 120 } }
    Text {
      textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
      anchors.centerIn: parent
      text: ib.glyph
      color: ibMouse.containsMouse ? root.fg : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
    }
    MouseArea {
      id: ibMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.clicked()
    }
  }

  component NavKey: Item {
    id: nk
    property string kind: "home"
    signal clicked()
    width: Style.space(40); height: parent ? parent.height : Style.space(32)
    readonly property color ink: nkMouse.containsMouse && root.mirrorLive ? root.fg : root.dim

    Rectangle {
      id: ripple
      anchors.centerIn: parent
      width: Style.space(30); height: width; radius: width / 2
      color: root.accent
      opacity: 0
      scale: 0.4
      ParallelAnimation {
        id: rippleAnim
        NumberAnimation { target: ripple; property: "scale"; from: 0.4; to: 1.25; duration: 420; easing.type: Easing.OutCubic }
        NumberAnimation { target: ripple; property: "opacity"; from: 0.35; to: 0; duration: 420; easing.type: Easing.OutCubic }
      }
    }
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(34); height: Style.space(26); radius: height / 2
      color: nkMouse.pressed ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)
        : (nkMouse.containsMouse ? root.faint : "transparent")
    }
    // back: a chevron-like triangle
    Shape {
      visible: nk.kind === "back"
      anchors.centerIn: parent
      width: Style.space(12); height: Style.space(12)
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeColor: nk.ink; strokeWidth: Math.max(1.5, Style.space(1.6)); fillColor: "transparent"
        joinStyle: ShapePath.RoundJoin
        startX: Style.space(10); startY: Style.space(1)
        PathLine { x: Style.space(2); y: Style.space(6) }
        PathLine { x: Style.space(10); y: Style.space(11) }
        PathLine { x: Style.space(10); y: Style.space(1) }
      }
    }
    Rectangle {
      visible: nk.kind === "home"
      anchors.centerIn: parent
      width: Style.space(13); height: width; radius: width / 2
      color: "transparent"
      border.width: Math.max(1.5, Style.space(1.6)); border.color: nk.ink
    }
    Rectangle {
      visible: nk.kind === "recents"
      anchors.centerIn: parent
      width: Style.space(11); height: width; radius: Style.space(2.5)
      color: "transparent"
      border.width: Math.max(1.5, Style.space(1.6)); border.color: nk.ink
    }
    MouseArea {
      id: nkMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: root.mirrorLive
      cursorShape: Qt.PointingHandCursor
      onClicked: { rippleAnim.restart(); nk.clicked() }
    }
  }

  component ActionTile: Rectangle {
    id: tile
    property string key: ""
    property real order: 2
    property real flash: 0
    readonly property real entered: root.stagger(order)
    property string glyph: ""
    property string label: ""
    property string hint: ""
    property bool busy: false
    signal clicked()

    radius: Style.cornerRadius
    color: tileMouse.pressed ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
      : (tileMouse.containsMouse || tile.busy ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12) : root.faint)
    border.width: 1
    border.color: tileMouse.containsMouse || tile.busy ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.7) : root.hairline
    opacity: entered * (tile.enabled || tile.busy ? 1 : 0.45)
    scale: tileMouse.pressed ? 0.95 : 1
    transform: Translate { y: (1 - tile.entered) * Style.space(14) + (tileMouse.containsMouse && !tileMouse.pressed ? -Style.space(1.5) : 0) }

    // Success / failure glow after an action finishes.
    Connections {
      target: root
      function onFlashSeqChanged() { if (root.flashKey === tile.key) flashAnim.restart() }
    }
    NumberAnimation { id: flashAnim; target: tile; property: "flash"; from: 1; to: 0; duration: 1100; easing.type: Easing.OutCubic }
    Rectangle {
      anchors.fill: parent
      radius: parent.radius
      color: "transparent"
      border.width: Math.max(1, Style.space(2))
      border.color: root.flashOk ? root.accent : root.urgent
      opacity: tile.flash
      visible: tile.flash > 0
    }
    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on opacity { NumberAnimation { duration: 140 } }

    Column {
      anchors.centerIn: parent
      width: parent.width - Style.space(8)
      spacing: Style.space(2)

      Item {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(24); height: Style.space(24)
        Text {
          textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
          anchors.centerIn: parent
          visible: !tile.busy
          text: tile.glyph
          color: tileMouse.containsMouse || tile.flash > 0.3 ? root.accent : root.fg
          scale: tileMouse.containsMouse ? 1.14 : 1 + tile.flash * 0.18
          Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge + Style.space(2)
        }
        // spinner
        Shape {
          id: spin
          anchors.fill: parent
          visible: tile.busy
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            strokeColor: root.accent; strokeWidth: Math.max(2, Style.space(2.2)); fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
              centerX: spin.width / 2; centerY: spin.height / 2
              radiusX: spin.width / 2 - Style.space(3); radiusY: radiusX
              startAngle: 0; sweepAngle: 260
            }
          }
          RotationAnimator on rotation {
            running: tile.busy
            from: 0; to: 360; duration: 850
            loops: Animation.Infinite
          }
        }
      }
      Text {
        textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.label
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption + 1
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText  // never parse phone/clipboard text as HTML
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: tile.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: tile.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }
}
