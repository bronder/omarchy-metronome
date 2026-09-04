import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui
import qs.Commons

// Bar widget: a ♫ button that opens the metronome in a popup anchored
// under this icon, the way the first-party panels do. The body is taller
// than the space above the bar on short screens, so it scrolls.
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
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(720))

    ScrollView {
      id: scroll
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: body.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

      MetronomeBody {
        id: body
        width: scroll.availableWidth
        active: root.opened
      }
    }
  }
}
