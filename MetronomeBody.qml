import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Shared body for both hosts: the fullscreen summon overlay (Metronome.qml)
// and the bar popup (BarWidget.qml). The host sets `active` to gate the
// audio pipeline; everything else — state, process, controls — lives here
// so the two entries behave identically wherever they are opened.
Item {
  id: root

  property bool active: false

  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius

  readonly property string metroPipeline: Qt.resolvedUrl("bin/metro-pipeline").toString().replace(/^file:\/\//, "")
  property bool metroActive: false
  property int bpm: 100
  property int beatsPerBar: 4
  property int currentBeat: 0
  property string subdivision: "1/4"

  // Every value that can reach a process argument or a Repeater model passes
  // through these guards first; anything that fails is rejected, not coerced.
  readonly property var validSubdivisions: ["1/4", "1/8", "1/8t", "1/16", "1/16t", "swing"]

  function clampInt(v, lo, hi, fallback) {
    v = Math.round(Number(v))
    if (!isFinite(v)) return fallback
    return Math.min(hi, Math.max(lo, v))
  }

  implicitHeight: column.implicitHeight

  function applyPayload(payload) {
    if (!payload || typeof payload !== "object") return
    if (payload.metro === false) root.metroActive = false
    else if (payload.metro === true) root.metroActive = true
    if (payload.bpm !== undefined)
      root.bpm = clampInt(payload.bpm, 20, 300, root.bpm)
    if (payload.beats !== undefined)
      root.beatsPerBar = clampInt(payload.beats, 1, 12, root.beatsPerBar)
    if (payload.sub !== undefined && root.validSubdivisions.indexOf(payload.sub) >= 0)
      root.subdivision = payload.sub
    // The process command captured the old settings when it started.
    if (root.metroActive) restartMetro()
  }

  onActiveChanged: if (active) {
    if (root.metroActive) restartMetro()
    root.currentBeat = 0
  }

  // bin/metronome schedules the click track and reports beats on stderr;
  // pw-play turns it into sound. Restarting the pipeline on a bpm/sig change
  // is fine — the next bar starts immediately.
  Timer {
    id: bpmHold
    interval: 250
    onTriggered: restartMetro()
  }

  function restartMetro() {
    if (!root.metroActive) return
    // An imperative running=true would clobber the declarative binding, so
    // the overlay-close stop below would stop working; re-attach it instead.
    metroProc.running = false
    metroProc.running = Qt.binding(function() { return root.active && root.metroActive })
  }

  // Tap tempo: average the last few tap intervals; a pause over 2s starts
  // a fresh run of taps.
  property real lastTap: 0
  property var tapIntervals: []

  function tapTempo() {
    var now = Date.now()
    if (root.lastTap > 0 && now - root.lastTap < 2000)
      root.tapIntervals.push(now - root.lastTap)
    else
      root.tapIntervals = []
    root.lastTap = now
    if (root.tapIntervals.length === 0) return
    var recent = root.tapIntervals.slice(-4)
    var avg = 0
    for (var i = 0; i < recent.length; i++) avg += recent[i]
    avg /= recent.length
    root.bpm = Math.min(300, Math.max(20, Math.round(60000 / avg)))
    bpmHold.restart()
  }

  function stepBpm(d) {
    root.bpm = Math.min(300, Math.max(20, root.bpm + d))
    bpmHold.restart()
  }

  function setSubdivision(sub) {
    if (root.validSubdivisions.indexOf(sub) < 0) return
    if (root.subdivision === sub) return
    root.subdivision = sub
    restartMetro()
  }

  function stepBeats(d) {
    root.beatsPerBar = Math.min(12, Math.max(1, root.beatsPerBar + d))
    root.currentBeat = 0
    restartMetro()
  }

  // bin/metro-pipeline runs the generator into pw-play as a supervised
  // process group: setsid makes the script a group leader and its TERM trap
  // kills the generator and pw-play together, so stopping the Process here
  // always tears down the whole tree.
  Process {
    id: metroProc
    running: root.active && root.metroActive
    command: ["setsid", root.metroPipeline,
              String(clampInt(root.bpm, 20, 300, 100)),
              String(clampInt(root.beatsPerBar, 1, 12, 4)),
              root.validSubdivisions.indexOf(root.subdivision) >= 0 ? root.subdivision : "1/4"]
    stderr: SplitParser {
      onRead: function(line) {
        if (line.length > 256) return
        try {
          var d = JSON.parse(line)
          if (d && typeof d === "object" && typeof d.beat === "number" && isFinite(d.beat))
            root.currentBeat = clampInt(d.beat, 1, root.beatsPerBar, 0)
        } catch (e) {}
      }
    }
  }

  // Small stepper button that auto-repeats while held, for dialing in bpm.
  component MetroStep: Rectangle {
    id: ms
    property string glyph: "+"
    property var action: function() {}
    property int w: 22
    property int h: 20

    width: Style.space(w)
    height: Style.space(h)
    radius: 3
    color: msArea.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.06)
    border.color: root.border
    border.width: 1

    Text {
      anchors.centerIn: parent
      text: ms.glyph
      color: root.foreground
      opacity: 0.7
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, Style.font.body - 4)
      textFormat: Text.PlainText
    }

    MouseArea {
      id: msArea
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: ms.action()
      onPressed: msDelay.start()
      onReleased: { msDelay.stop(); msRepeat.stop() }
      onCanceled: { msDelay.stop(); msRepeat.stop() }
    }

    Timer { id: msDelay; interval: 400; onTriggered: msRepeat.start() }
    Timer { id: msRepeat; interval: 80; repeat: true; onTriggered: ms.action() }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(14)

    // ---------- Hero: icon · title/status · transport ----------
    PanelHero {
      width: parent.width
      foreground: root.foreground
      fontFamily: root.fontFamily
      title: "Metronome"
      detail: root.metroActive ? "PLAYING" : ""
      meta: root.bpm + " BPM · " + root.beatsPerBar + "/4 · " + root.subdivision
      iconComponent: Component {
        Text {
          text: "♫"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.display
        }
      }
    }

    PanelSeparator { foreground: root.foreground }

    // ---------- Transport ----------
    Item {
      width: parent.width
      implicitHeight: Math.max(transportHeader.implicitHeight, transportMeta.implicitHeight)

      PanelSectionHeader {
        id: transportHeader
        text: "TRANSPORT"
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: transportMeta
        text: root.bpm + " BPM · " + root.beatsPerBar + "/4"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: metroPlay.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
      }

      PanelActionButton {
        id: metroPlay
        iconText: root.metroActive ? "■" : "▶"
        foreground: root.metroActive ? "#4ade80" : root.foreground
        size: Style.space(32)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        onClicked: { root.metroActive = !root.metroActive; root.currentBeat = 0 }
      }
    }

    // Beat dots — centered, the eye-anchor of the panel.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)
      Repeater {
        model: root.beatsPerBar
        Rectangle {
          required property int index
          width: height
          height: Style.space(14)
          radius: width / 2
          color: root.metroActive && root.currentBeat === index + 1
            ? (index === 0 ? "#4ade80" : root.foreground)
            : "transparent"
          border.color: index === 0 ? "#4ade80" : root.foreground
          border.width: root.metroActive && root.currentBeat === index + 1 ? 2 : 1
          opacity: root.metroActive && root.currentBeat === index + 1 ? 1 : 0.45
          Behavior on opacity { NumberAnimation { duration: 80 } }
          Behavior on border.width { NumberAnimation { duration: 80 } }
        }
      }
    }

    // Tempo: big number, fine steppers, tap.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)

      MetroStep { glyph: "−"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(-1) } }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.bpm
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.max(28, Style.font.title + 6)
        font.bold: true
        textFormat: Text.PlainText

        Behavior on color { ColorAnimation { duration: 120 } }
      }

      MetroStep { glyph: "+"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(1) } }

      Item { width: Style.space(8); height: 1 }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: tapLabel.implicitWidth + Style.space(16)
        height: Style.space(26)
        radius: height / 2
        color: tapMa.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.06)
        border.color: root.border
        border.width: 1

        Text {
          id: tapLabel
          anchors.centerIn: parent
          text: "TAP"
          color: root.foreground
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Math.max(10, Style.font.body - 3)
          font.bold: true
          font.letterSpacing: 1
          textFormat: Text.PlainText
        }
        MouseArea { id: tapMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tapTempo() }
      }
    }

    // Tempo slider — dial the bpm in directly.
    PanelSlider {
      id: bpmSlider
      width: parent.width
      height: implicitHeight + Style.spacing.controlGap
      minimum: 20
      maximum: 300
      step: 1
      integer: true
      value: root.bpm
      onMoved: function(v) { root.bpm = Math.round(v) }
      onReleased: function(v) { bpmHold.restart() }
    }

    // Subdivisions: a uniform 3-column grid, straight → triplet → swing,
    // each tile showing the rhythm in note glyphs under its label.
    Grid {
      width: parent.width
      columns: 3
      spacing: Style.space(6)

      Repeater {
        model: [
          { label: "1/4",   notes: "\u2669", tuplet: "" },
          { label: "1/8",   notes: "\u266B", tuplet: "" },
          { label: "1/8t",  notes: "\u266A\u266A\u266A", tuplet: "3" },
          { label: "swing", notes: "\u266A.\u266A", tuplet: "" },
          { label: "1/16",  notes: "\u266C\u266C", tuplet: "" },
          { label: "1/16t", notes: "\u266C\u266C\u266C", tuplet: "6" }
        ]

        Item {
          id: subTile
          required property var modelData
          width: (parent.width - Style.space(12)) / 3
          height: Style.space(52)

          Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: root.subdivision === subTile.modelData.label
              ? Qt.rgba(0.29, 0.87, 0.50, 0.22)
              : (tileMa.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.05))
            border.color: root.subdivision === subTile.modelData.label ? "#4ade80" : root.border
            border.width: 1
            Behavior on color { ColorAnimation { duration: 100 } }
          }

          Column {
            anchors.centerIn: parent
            spacing: 2

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: subTile.modelData.label
              color: root.subdivision === subTile.modelData.label ? "#4ade80" : root.foreground
              opacity: root.subdivision === subTile.modelData.label ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, Style.font.body - 2)
              font.bold: true
              textFormat: Text.PlainText
            }

            // Tuplet numeral (3, 6) riding above the beam, the way it is
            // written on a stave; dotted notes spell out the swing feel.
            Text {
              visible: subTile.modelData.tuplet !== ""
              anchors.horizontalCenter: parent.horizontalCenter
              text: subTile.modelData.tuplet
              color: root.subdivision === subTile.modelData.label ? "#4ade80" : root.foreground
              opacity: root.subdivision === subTile.modelData.label ? 0.9 : 0.4
              font.family: root.fontFamily
              font.pixelSize: Math.max(9, Style.font.body - 4)
              font.bold: true
              textFormat: Text.PlainText
            }

            Rectangle {
              visible: subTile.modelData.tuplet !== ""
              anchors.horizontalCenter: parent.horizontalCenter
              width: notesText.width
              height: 1
              color: root.subdivision === subTile.modelData.label ? "#4ade80" : root.foreground
              opacity: root.subdivision === subTile.modelData.label ? 0.7 : 0.3
            }

            Text {
              id: notesText
              anchors.horizontalCenter: parent.horizontalCenter
              text: subTile.modelData.notes
              color: root.subdivision === subTile.modelData.label ? "#4ade80" : root.foreground
              opacity: root.subdivision === subTile.modelData.label ? 0.95 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Math.max(16, Style.font.body + 6)
              textFormat: Text.PlainText
            }
          }

          MouseArea { id: tileMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setSubdivision(subTile.modelData.label) }
        }
      }
    }

    // Time signature, centered under the grid.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(8)

      MetroStep { glyph: "−"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBeats(-1) } }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(40)
        horizontalAlignment: Text.AlignHCenter
        text: root.beatsPerBar + "/4"
        color: root.foreground; opacity: 0.85
        font.family: root.fontFamily; font.pixelSize: Math.max(11, Style.font.body)
        font.bold: true
        textFormat: Text.PlainText
      }
      MetroStep { glyph: "+"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBeats(1) } }
    }
  }
}
