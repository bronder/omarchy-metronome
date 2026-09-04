import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Bar widget: a ♫ button that opens the metronome in a popup anchored
// under this icon, the way the first-party panels do. The body is taller
// than the space above the bar, so it flicks/scrolls inside the card
// (same Flickable pattern the tray menu and agents panel use).
Panel {
  id: root
  moduleName: "bronder.metronome"
  ipcTarget: "bronder.metronome"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
        active: root.opened
      }
    }
  }
}
