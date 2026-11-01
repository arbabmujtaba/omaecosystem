import QtQuick 6.11
import Quickshell
import qs.Commons
import qs.Ui

// Phone icon in the bar. One click docks the phone (or undocks it). The dock
// itself is this plugin's panel (Dock.qml): one instance for the whole shell,
// however many bars/monitors there are.
BarWidget {
  id: root
  moduleName: "io.github.arbabmujtaba.omaecosystem"

  readonly property string pluginId: "io.github.arbabmujtaba.omaecosystem"
  readonly property var shellHost: bar && bar.shell ? bar.shell : null
  // openPanelIds is reassigned on every change, so this stays live.
  readonly property bool docked: shellHost && shellHost.openPanelIds
    ? shellHost.openPanelIds[pluginId] === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: barSize

  function toggleDock() {
    if (!shellHost) return
    if (docked) shellHost.hide(pluginId)
    else shellHost.summon(pluginId, JSON.stringify(root.settings || {}))
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄜"
    active: root.docked
    useActiveColor: false
    tooltipText: root.docked ? "Undock phone" : "Dock phone"
    onPressed: function(b) { root.toggleDock() }
  }

  // A small accent pip under the icon while the phone is docked.
  Rectangle {
    visible: root.docked && !root.vertical
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(3)
    width: Style.space(4)
    height: width
    radius: width / 2
    color: Color.accent
  }
}
