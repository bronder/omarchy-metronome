import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Fullscreen summon overlay hosting the shared MetronomeBody. The bar icon
// opens the same tool as a popup anchored under itself — see BarWidget.qml.
//
// Also owns the pinned corner window (`omarchy-shell bronder.metronome pin`):
// a small always-on-top metronome that keeps playing while you work. The
// window lives at this plugin root because a PanelWindow nested inside the
// bar widget's item tree maps but never renders on this Quickshell build.
// The bar popup's 📌 is independent — it pins the popup itself — and that
// popup yields to this overlay on summon (see BarWidget.qml), so only one
// MetronomeBody, and therefore one audio pipeline, is ever active.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  // Pinned corner window state.
  property bool pinned: false
  property var pendingPin: null

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

  // Set briefly to bounce the Loader when a re-summon changes the target
  // screen — this build will not move a live layer surface, so the window
  // must be torn down and re-mapped (see open()).
  property bool remap: false

  function open(payloadJson) {
    var payload = {}
    try {
      payload = JSON.parse(payloadJson || "{}") || {}
    } catch (e) {}

    // Pin summon: configure and show the corner window; the fullscreen
    // overlay stays closed. Opening the fullscreen overlay while pinned
    // folds the pinned window in, so only one pipeline ever runs.
    if (payload.pin === true) {
      root.pendingPin = payload
      root.pin()
      return
    }
    if (root.pinned) {
      payload.bpm = pinnedBody.bpm
      payload.beats = pinnedBody.beatsPerBar
      payload.sub = pinnedBody.subdivision
      payload.metro = pinnedBody.metroActive
      root.unpin()
    }

    // The shell delivers every summon here, re-summons while the overlay is
    // already on screen included. A window created by this call applies the
    // payload when its component completes; one that already exists has long
    // consumed that hook, so open() delivers to it directly below.
    var livePanel = overlayLoader.item
    var wanted = payload.screen
    root.pendingPayload = payload
    var switchingScreen = false
    if (wanted) {
      var match = null
      var screens = Quickshell.screens || []
      for (var i = 0; i < screens.length; i++)
        if (screens[i].name === wanted) match = screens[i]
      if (match && match !== root.targetScreen) {
        root.targetScreen = match
        switchingScreen = true
      }
    } else {
      screenProc.running = false
      screenProc.running = true
    }
    root.opened = true

    if (livePanel && switchingScreen) {
      root.remap = true
      Qt.callLater(function() { root.remap = false })
    } else if (livePanel) {
      livePanel.applyPending()
    }
  }

  // ----- pinned corner window -----

  IpcHandler {
    target: "bronder.metronome.pin"

    function pin(): void { root.pin() }
    function unpin(): void { root.unpin() }
    function toggle(): void { root.pinned ? root.unpin() : root.pin() }
  }

  function pin() {
    if (root.pinned) return
    var p = root.pendingPin || {}
    // Pinning while the overlay is up: inherit its live settings — keeping
    // the sound running, unless the payload says otherwise — and close the
    // overlay, so the two bodies never play together.
    var livePanel = root.opened ? overlayLoader.item : null
    if (livePanel) {
      var s = livePanel.liveState()
      if (p.bpm === undefined) p.bpm = s.bpm
      if (p.beats === undefined) p.beats = s.beats
      if (p.sub === undefined) p.sub = s.sub
      if (p.metro === undefined) p.metro = s.metro
      root.close()
    }
    if (p.bpm !== undefined) pinnedBody.bpm = clampGuard(p.bpm, 20, 300, pinnedBody.bpm)
    if (p.beats !== undefined) pinnedBody.beatsPerBar = clampGuard(p.beats, 1, 12, pinnedBody.beatsPerBar)
    if (p.sub !== undefined && pinnedBody.validSubdivisions.indexOf(p.sub) >= 0)
      pinnedBody.subdivision = p.sub
    pinnedBody.metroActive = p.metro === true
    root.pinned = true // pinnedBody.active follows and starts the pipeline
  }

  function unpin() {
    pinnedBody.metroActive = false // stops before the window goes away
    root.pinned = false
  }

  function clampGuard(v, lo, hi, fallback) {
    v = Math.round(Number(v))
    if (!isFinite(v)) return fallback
    return Math.min(hi, Math.max(lo, v))
  }

  PanelWindow {
    id: pinnedWindow
    visible: root.pinned
    anchors { top: true; right: true }
    margins { top: Style.gapsOut; right: Style.gapsOut }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-metronome-pinned"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Anchor to the focused/default screen at creation, like the overlay.
    screen: root.targetScreen

    implicitWidth: pinnedCard.width
    implicitHeight: pinnedCard.height

    BorderSurface {
      id: pinnedCard
      readonly property int pad: Style.spacing.panelPadding
      width: Style.space(380)
      height: pinnedBody.height + pad * 2
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: pad

      MetronomeBody {
        id: pinnedBody
        width: pinnedCard.width - pinnedCard.pad * 2
        height: implicitHeight
        compact: true
        active: root.pinned
      }

      PanelActionButton {
        iconText: "✕"
        foreground: root.foreground
        size: Style.space(24)
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Style.space(2)
        anchors.rightMargin: Style.space(2)
        onClicked: root.unpin()
      }
    }
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
    id: overlayLoader
    active: root.opened && root.targetScreen !== null && !root.remap
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

      // Payload hand-off for freshly created windows: children complete
      // before parents, so `body` is ready here. Re-summons while the
      // overlay is already open are delivered straight to this instance
      // by open() instead.
      function applyPending() {
        if (root.pendingPayload) body.applyPayload(root.pendingPayload)
      }

      // Live settings of the overlay body, for hand-off to the pinned
      // corner window (see pin()).
      function liveState() {
        return { bpm: body.bpm, beats: body.beatsPerBar, sub: body.subdivision, metro: body.metroActive }
      }

      Component.onCompleted: applyPending()

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
          }
        }
      }
    }
  }
}
