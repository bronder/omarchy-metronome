import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Bar widget: a ♫ button that opens the metronome in a popup anchored
// under this icon, the way the first-party panels do. The body is taller
// than the space above the bar, so it flicks/scrolls inside the card
// (same Flickable pattern the tray menu and agents panel use).
//
// The 📌 in the popup toggles "pinned" locally — the popup stays put,
// click-outside dismissal is disabled (PopupCard.triggerMode = "hover"),
// and the bar icon / pin button tear it down. The overlay entry still
// owns its own pinned corner window for external IPC (`omarchy-shell
// bronder.metronome pin`); the in-popup pin does not go through it.
//
// The popup and the overlay each run their own MetronomeBody, so both
// active at once would mean two audio pipelines. The shell's openPanelIds
// marks the overlay summoned, and this widget yields to it: the popup
// folds away (and stays closed while the overlay is up).
Panel {
  id: root
  moduleName: "bronder.metronome"
  ipcTarget: "bronder.metronome"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // When true, the popup stays open and ignores outside clicks.
  property bool pinned: false

  // The Bar carries the shell object; openPanelIds[moduleName] is true for
  // exactly as long as the overlay is summoned (set in shell summon(),
  // cleared in hide()).
  readonly property var shellRef: root.bar ? root.bar.shell : null
  readonly property bool overlaySummoned: !!shellRef && !!shellRef.openPanelIds
    && shellRef.openPanelIds[moduleName] === true

  onOverlaySummonedChanged: {
    if (overlaySummoned && (root.opened || root.pinned)) {
      root.pinned = false
      root.close()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "♫"
    onPressed: function(b) { root.toggle() }
  }

  PopupCard {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Pinned popups must not auto-dismiss on outside click; the bar icon
    // or pin button is the only way out.
    triggerMode: root.pinned ? "hover" : "click"
    contentWidth: panel.fittedContentWidth(Style.space(560))

    // The host bar's window spans nearly the whole monitor, so the card's
    // own available-height math (screen − bar) bottoms out at its 120-unit
    // floor. Only trust it when it clears a sane minimum; otherwise cap the
    // card ourselves and let the Flickable handle the rest.
    readonly property real cardHeightCap: panel.availableCardHeight > Style.space(300)
      ? panel.availableCardHeight
      : Style.space(560)
    contentHeight: Math.round(Math.min(body.implicitHeight + panel.verticalContentInset, cardHeightCap))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: body.height
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      MetronomeBody {
        id: body
        width: flick.width
        height: implicitHeight
        compact: true
        pinnable: true
        pinned: root.pinned
        active: root.opened || root.pinned

        onPinRequested: root.togglePinned()
      }
    }
  }

  // The overlay covers the bar, so the icon can't be clicked while it is
  // up — but the panel IPC still could, opening a second playing body.
  function open() {
    if (root.overlaySummoned) return
    root.controller.show()
  }

  function toggle() {
    if (root.pinned) {
      root.unpin()
    } else if (root.opened) {
      root.close()
    } else {
      root.open()
    }
  }

  function togglePinned() {
    if (root.pinned) root.unpin()
    else root.pin()
  }

  function pin() {
    if (root.pinned) return
    root.pinned = true
    if (!root.opened) root.open()
  }

  function unpin() {
    if (!root.pinned) return
    root.pinned = false
    root.close()
  }
}
