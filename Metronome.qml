import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Fullscreen summon overlay hosting the shared MetronomeBody. The bar icon
// opens the same tool as a popup anchored under itself — see BarWidget.qml.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int cardWidth: Math.min(Style.space(560), (root.targetScreen ? root.targetScreen.width : 2160) - Style.gapsOut * 2)
  property int cardHeight: Math.min(contentMargin * 2 + bodyNatural.implicitHeight, (root.targetScreen ? root.targetScreen.height : 3840) - Style.gapsOut * 2)

  // Which output the overlay shows on. Default is the monitor Hyprland
  // currently has focused, resolved at open() time; a summon payload can
  // override with {"screen":"DP-1"}.
  property var targetScreen: null

  // Payload can only reach the body once the Loader has instantiated it;
  // stash it and hand it over on body load.
  property var pendingPayload: null

  function open(payloadJson) {
    var wanted = null
    try {
      var payload = JSON.parse(payloadJson || "{}") || {}
      wanted = payload.screen
      root.pendingPayload = payload
    } catch (e) {}
    if (wanted) {
      var match = null
      var screens = Quickshell.screens || []
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === wanted) match = screens[i]
      if (match) root.targetScreen = match
    } else {
      screenProc.running = false
      screenProc.running = true
    }
    root.opened = true
  }

  Process {
    id: screenProc
    command: ["bash", "-c", "hyprctl monitors -j | jq -r '.[] | select(.focused) | .name'"]
    stdout: StdioCollector {
      onStreamFinished: {
        var name = text.trim()
        if (name.length === 0 || name.length > 64 || !/^[A-Za-z0-9._-]+$/.test(name))
          return
        var screens = Quickshell.screens || []
        for (var i = 0; i < screens.length; i++)
          if (screens[i].name === name || screens[i].displayName === name)
            root.targetScreen = screens[i]
      }
    }
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "bronder.metronome")
  }

  // Inert measuring instance: drives cardHeight from the content's natural
  // height. active stays false, so no audio pipeline runs here.
  MetronomeBody {
    id: bodyNatural
    width: root.cardWidth - root.contentMargin * 2
    visible: false
    active: false
  }

  // The window is created fresh each open, after the target screen is known —
  // this Quickshell build will not move an existing layer surface.
  Loader {
    active: root.opened && root.targetScreen !== null
    sourceComponent: panelComponent
  }

  Component {
    id: panelComponent

    PanelWindow {
      id: panel
      visible: root.opened
      screen: root.targetScreen
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-metronome"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      Rectangle { anchors.fill: parent; color: root.scrim }

      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

      BorderSurface {
        id: card
        width: root.cardWidth
        height: root.cardHeight
        radius: root.cornerRadius
        anchors.centerIn: parent
        color: root.background
        borderSpec: root.borderSpec
        padding: root.contentMargin

        MouseArea { anchors.fill: parent; onClicked: {} }

        Item {
          id: escCatcher
          anchors.fill: parent
          focus: true
          Component.onCompleted: escCatcher.forceActiveFocus()
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.dismiss()
              event.accepted = true
            }
          }

          MetronomeBody {
            id: body
            anchors.fill: parent
            active: root.opened
            Component.onCompleted: {
              if (root.pendingPayload) applyPayload(root.pendingPayload)
            }
          }
        }
      }
    }
  }
}
