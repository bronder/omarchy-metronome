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
//
// Layout mirrors the classic circular metronome: a BPM dial with a tick
// ring and numerals (40–208), a progress arc at the current tempo, a center
// disc that starts/stops and shows the big number plus the tempo term
// (Largo … Prestissimo), chevron steppers, and a TAP button.
Item {
  id: root

  property bool active: false

  // Tighter layout for the bar popup, whose card is height-capped; the
  // fullscreen overlay uses the roomier default.
  property bool compact: false

  // When true, a small pin button docks at the hero's trailing edge and
  // emits pinRequested(); the popup host uses it to keep the existing
  // window open in pinned mode. `pinned` reflects host state and tints
  // the icon with the accent color so the affordance reads as "unpin".
  property bool pinnable: false
  property bool pinned: false
  signal pinRequested()

  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property color accent: "#4dbbd3"

  readonly property string metroPipeline: Qt.resolvedUrl("bin/metro-pipeline").toString().replace(/^file:\/\//, "")
  property bool metroActive: false
  property int bpm: 100
  property int beatsPerBar: 4
  property int currentBeat: 0
  property string subdivision: "1/4"

  // Every value that can reach a process argument or a Repeater model passes
  // through these guards first; anything that fails is rejected, not coerced.
  readonly property var validSubdivisions: ["1/4", "1/8", "1/8t", "1/16", "1/16t", "swing"]

  // Dial scale, matching the printed numerals (40–208, step 4 ticks).
  readonly property real dialMinBpm: 40
  readonly property real dialMaxBpm: 208
  readonly property var dialNumerals: [40, 60, 80, 100, 120, 140, 160, 180, 200]

  function clampInt(v, lo, hi, fallback) {
    v = Math.round(Number(v))
    if (!isFinite(v)) return fallback
    return Math.min(hi, Math.max(lo, v))
  }

  function dialAngle(b) { // radians, 0 at 12 o'clock, clockwise
    var frac = (Math.min(dialMaxBpm, Math.max(dialMinBpm, b)) - dialMinBpm) / (dialMaxBpm - dialMinBpm)
    return frac * Math.PI * 2
  }

  function tempoTerm(b) {
    if (b < 60) return "LARGO"
    if (b < 66) return "LARGHETTO"
    if (b < 76) return "ADAGIO"
    if (b < 108) return "ANDANTE"
    if (b < 120) return "MODERATO"
    if (b < 168) return "ALLEGRO"
    if (b < 200) return "PRESTO"
    return "PRESTISSIMO"
  }

  implicitHeight: column.implicitHeight

  Component.onDestruction: if (metroProc.running) stopMetro()

  // Pin control, docked in the hero's trailing slot (PanelHero reserves
  // the space via trailingInset, so the PLAYING pill can never slide
  // underneath it). Material Symbols glyph so it follows the theme; the
  // accent color marks the pinned state.
  Component {
    id: pinControl
    PanelActionButton {
      iconText: "push_pin"
      fontFamily: "Material Symbols Rounded"
      foreground: root.pinned ? root.accent : root.foreground
      opacity: root.pinned ? 1 : 0.75
      tooltipText: root.pinned ? "Unpin" : "Keep open"
      size: Style.space(26)
      onClicked: root.pinRequested()
    }
  }

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

  onActiveChanged: {
    if (active) {
      if (root.metroActive) restartMetro()
      root.currentBeat = 0
    } else {
      stopMetro()
    }
  }

  onMetroActiveChanged: {
    if (root.active && root.metroActive) restartMetro()
    else stopMetro()
  }

  // bin/metronome schedules the click track and reports beats on stderr;
  // pw-play turns it into sound. Restarting the pipeline on a bpm/sig change
  // is fine — the next bar starts immediately.
  Timer {
    id: bpmHold
    interval: 250
    onTriggered: restartMetro()
  }

  // Tap runs settle slower than steppers/sliders: wait for a pause in
  // tapping before adopting the tempo, so the pipeline never restarts
  // mid-run and interrupt the bar being tapped against.
  Timer {
    id: tapHold
    interval: 900
    onTriggered: restartMetro()
  }

  // Settle gap between tearing down the old pipeline and starting the new
  // one: the old pw-play needs a moment to release the sink after SIGTERM,
  // otherwise rapid restarts briefly overlap two click tracks.
  Timer {
    id: metroStartHold
    interval: 120
    onTriggered: doStartMetro()
  }

  // Quickshell's Process.running=false does not reliably stop a running
  // child on this build, so stops are forced with an explicit SIGTERM to
  // the pipeline leader; its trap tears down the whole process group.
  function stopMetro() {
    metroStartHold.stop() // cancel a pending delayed start, if any
    var pid = Number(metroProc.processId)
    if (pid > 0) metroProc.signal(15) // SIGTERM
    metroProc.running = false
  }

  function restartMetro() {
    if (!root.active || !root.metroActive) return
    stopMetro()
    metroStartHold.restart()
  }

  function doStartMetro() {
    if (!root.active || !root.metroActive) return
    metroProc.running = true
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
    tapHold.restart()
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

  // Large thin chevron beside the dial; auto-repeats while held.
  component ChevronStep: Item {
    id: cs
    property string glyph: "‹"
    property var action: function() {}
    width: csText.implicitWidth
    height: csText.implicitHeight

    Text {
      id: csText
      anchors.centerIn: parent
      text: cs.glyph
      color: csArea.pressed ? "#ffffff" : root.accent
      font.family: root.fontFamily
      font.pixelSize: Math.max(30, Style.font.title + 10)
      font.bold: true
      textFormat: Text.PlainText

      Behavior on color { ColorAnimation { duration: 80 } }
    }

    MouseArea {
      id: csArea
      anchors.fill: parent
      anchors.margins: -Style.space(6)
      cursorShape: Qt.PointingHandCursor
      onClicked: cs.action()
      onPressed: csDelay.start()
      onReleased: { csDelay.stop(); csRepeat.stop() }
      onCanceled: { csDelay.stop(); csRepeat.stop() }
    }

    Timer { id: csDelay; interval: 400; onTriggered: csRepeat.start() }
    Timer { id: csRepeat; interval: 80; repeat: true; onTriggered: cs.action() }
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(root.compact ? 10 : 14)

    // ---------- Hero ----------
    PanelHero {
      width: parent.width
      foreground: root.foreground
      fontFamily: root.fontFamily
      title: "Metronome"
      detail: root.metroActive ? "PLAYING" : ""
      trailingControl: root.pinnable ? pinControl : null
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

    // ---------- Dial: ‹ ◐ › ----------
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)

      ChevronStep { glyph: "‹"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(-1) } }

      Item {
        id: dial
        width: Style.space(root.compact ? 185 : 230)
        height: width
        anchors.verticalCenter: parent.verticalCenter

        // Dial face.
        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Qt.rgba(1, 1, 1, 0.03)
          border.color: root.border
          border.width: 1
        }

        // Progress arc at the current tempo, over a dim full-circle track.
        Canvas {
          id: dialArc
          anchors.fill: parent
          anchors.margins: Style.space(8)

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.lineWidth = 3
            var r = width / 2 - ctx.lineWidth
            var cx = width / 2
            var cy = height / 2
            ctx.strokeStyle = "rgba(255,255,255,0.10)"
            ctx.beginPath()
            ctx.arc(cx, cy, r, 0, Math.PI * 2)
            ctx.stroke()
            ctx.strokeStyle = "#4dbbd3"
            ctx.beginPath()
            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + root.dialAngle(root.bpm))
            ctx.stroke()
          }

          Connections {
            target: root
            function onBpmChanged() { dialArc.requestPaint() }
          }
        }

        // Tick ring: one tick per 4 bpm, numerals at the decades.
        Repeater {
          model: 43 // 40..208 step 4

          Rectangle {
            required property int index
            readonly property real val: 40 + index * 4
            readonly property real ang: root.dialAngle(val)
            readonly property bool major: root.dialNumerals.indexOf(val) >= 0
            readonly property real rTick: dial.width / 2 - Style.space(12)

            width: major ? 2 : 1
            height: major ? Style.space(8) : Style.space(5)
            x: dial.width / 2 + Math.sin(ang) * rTick - width / 2
            y: dial.height / 2 - Math.cos(ang) * rTick - height / 2
            rotation: ang * 180 / Math.PI
            radius: width / 2
            color: major ? root.accent : root.foreground
            opacity: major ? 0.9 : 0.35
          }
        }

        // Numerals at the major ticks.
        Repeater {
          model: root.dialNumerals

          Text {
            required property var modelData
            readonly property real ang: root.dialAngle(modelData)
            readonly property real rNum: dial.width / 2 - Style.space(26)
            readonly property real w2: width / 2
            readonly property real h2: height / 2

            x: dial.width / 2 + Math.sin(ang) * rNum - w2
            y: dial.height / 2 - Math.cos(ang) * rNum - h2
            text: String(modelData)
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Math.max(9, Style.font.body - 5)
            font.bold: true
            textFormat: Text.PlainText
          }
        }

        // Center disc: START/STOP control, big tempo number, tempo term.
        Rectangle {
          id: centerDisc
          anchors.centerIn: parent
          width: dial.width * 0.54
          height: width
          radius: width / 2
          color: root.metroActive ? root.accent : Qt.rgba(0.30, 0.73, 0.82, 0.18)
          border.color: root.accent
          border.width: 1

          Behavior on color { ColorAnimation { duration: 150 } }

          Column {
            anchors.centerIn: parent
            spacing: 0

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.metroActive ? "STOP" : "START"
              color: "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Math.max(9, Style.font.body - 4)
              font.bold: true
              font.letterSpacing: 2
              textFormat: Text.PlainText
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.bpm
              color: "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Math.max(28, Style.font.title + (root.compact ? 8 : 16))
              font.bold: true
              textFormat: Text.PlainText
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.tempoTerm(root.bpm)
              color: "#ffffff"
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Math.max(8, Style.font.body - 6)
              font.bold: true
              font.letterSpacing: 1
              textFormat: Text.PlainText
            }
          }

          MouseArea {
            id: discArea
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.metroActive = !root.metroActive; root.currentBeat = 0 }
          }
        }
      }

      ChevronStep { glyph: "›"; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(1) } }
    }

    // Beat dots — the current beat lights up, green-teal accent on the
    // downbeat, matching the accent ring on the dial.
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
            ? (index === 0 ? root.accent : root.foreground)
            : "transparent"
          border.color: index === 0 ? root.accent : root.foreground
          border.width: root.metroActive && root.currentBeat === index + 1 ? 2 : 1
          opacity: root.metroActive && root.currentBeat === index + 1 ? 1 : 0.45
          Behavior on opacity { NumberAnimation { duration: 80 } }
          Behavior on border.width { NumberAnimation { duration: 80 } }
        }
      }
    }

    // TAP button, centered under the dial.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      width: tapLabel.implicitWidth + Style.space(28)
      height: Style.space(30)
      radius: height / 2
      color: tapMa.pressed ? Qt.rgba(0.30, 0.73, 0.82, 0.35) : Qt.rgba(1, 1, 1, 0.06)
      border.color: root.accent
      border.width: 1

      Text {
        id: tapLabel
        anchors.centerIn: parent
        text: "TAP"
        color: root.foreground
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Math.max(11, Style.font.body - 2)
        font.bold: true
        font.letterSpacing: 1
        textFormat: Text.PlainText
      }
      MouseArea { id: tapMa; anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tapTempo() }
    }

    // Tempo slider — dial the bpm in directly (arc and number follow along).
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
          height: Style.space(root.compact ? 46 : 52)

          Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: root.subdivision === subTile.modelData.label
              ? Qt.rgba(0.30, 0.73, 0.82, 0.22)
              : (tileMa.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.05))
            border.color: root.subdivision === subTile.modelData.label ? root.accent : root.border
            border.width: 1
            Behavior on color { ColorAnimation { duration: 100 } }
          }

          Column {
            anchors.centerIn: parent
            spacing: 2

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: subTile.modelData.label
              color: root.subdivision === subTile.modelData.label ? root.accent : root.foreground
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
              color: root.subdivision === subTile.modelData.label ? root.accent : root.foreground
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
              color: root.subdivision === subTile.modelData.label ? root.accent : root.foreground
              opacity: root.subdivision === subTile.modelData.label ? 0.7 : 0.3
            }

            Text {
              id: notesText
              anchors.horizontalCenter: parent.horizontalCenter
              text: subTile.modelData.notes
              color: root.subdivision === subTile.modelData.label ? root.accent : root.foreground
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
