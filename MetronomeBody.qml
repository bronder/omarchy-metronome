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
  readonly property color accent: Color.accent

  readonly property string metroPipeline: {
    var u = Qt.resolvedUrl("bin/metro-pipeline").toString().replace(/^file:\/\//, "");
    try { return decodeURIComponent(u) } catch (e) { return u }
  }
  property bool metroActive: false
  property int bpm: 100
  property int beatsPerBar: 4
  property int currentBeat: 0
  property string subdivision: "1/4"
  // Click level for the metronome's own stream (0–100). Applied through
  // pw-play's --volume, so it never touches the system sink volume.
  property int volume: 80

  // pw-play buffers ~audioLatencyMs before sound emerges (see the
  // --latency flag in bin/metro-pipeline); beat dots apply on a matching
  // delay so the flash lands on the click, not on the pipe write. Dots
  // change at most once per beat (>=200ms even at 300bpm), so this fixed
  // delay never coalesces across beats.
  readonly property int audioLatencyMs: 50
  property int pendingBeat: 0
  Timer {
    id: beatDelay
    interval: root.audioLatencyMs
    onTriggered: if (root.metroActive && root.active) root.currentBeat = root.pendingBeat
  }

  // Every value that can reach a process argument or a Repeater model passes
  // through these guards first; anything that fails is rejected, not coerced.
  readonly property var validSubdivisions: ["1/4", "1/8", "1/8t", "1/16", "1/16t", "swing"]

  // Dial scale, matching the printed numerals (40–208, step 4 ticks).
  readonly property real dialMinBpm: 40
  readonly property real dialMaxBpm: 208
  readonly property var dialNumerals: [40, 60, 80, 100, 120, 140, 160, 180, 200]

  function clampInt(v, lo, hi, fallback) {
    if (v === null || v === undefined || v === "" || typeof v === "boolean") return fallback
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
    // Apply tempo first, transport last: setting metroActive fires
    // onMetroActiveChanged → restartMetro(), so a single restart at the end
    // covers the whole summon instead of one per field.
    var tempoChanged = payload.bpm !== undefined || payload.beats !== undefined || payload.sub !== undefined
    var volChanged = false
    var oldMetro = root.metroActive
    if (payload.vol !== undefined) {
      var newVol = clampInt(payload.vol, 0, 100, root.volume)
      volChanged = newVol !== root.volume
      root.volume = newVol
    }
    if (payload.bpm !== undefined)
      root.bpm = clampInt(payload.bpm, 20, 300, root.bpm)
    if (payload.beats !== undefined)
      root.beatsPerBar = clampInt(payload.beats, 1, 12, root.beatsPerBar)
    if (payload.sub !== undefined && root.validSubdivisions.indexOf(payload.sub) >= 0)
      root.subdivision = payload.sub
    if (payload.metro === false) root.metroActive = false
    else if (payload.metro === true) root.metroActive = true
    // onMetroActiveChanged already restarted when metro flipped; restart
    // here only when metro stayed true but tempo changed.
    if (root.metroActive && (tempoChanged || volChanged) && root.metroActive === oldMetro) restartMetro()
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

  // Volume rides the same settle path as tempo: sliding produces many
  // values per second, and each applied value restarts the pipeline —
  // so wait for the slider to rest before picking the final level.
  Timer {
    id: volumeHold
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
    interval: 200
    onTriggered: doStartMetro()
  }

  // Pending (re)start while the old pipeline is still tearing down.
  property bool wantStart: false

  // Quickshell's Process.running=false does not reliably stop a running
  // child on this build, so stops are forced with an explicit SIGTERM to
  // the pipeline leader; its trap tears down the whole process group.
  function stopMetro() {
    metroStartHold.stop() // cancel a pending delayed start, if any
    bpmHold.stop()
    tapHold.stop()
    beatDelay.stop()
    wantStart = false
    var pid = Number(metroProc.processId)
    if (pid > 0) metroProc.signal(15) // SIGTERM
    metroProc.running = false
  }

  function restartMetro() {
    if (!root.active || !root.metroActive) return
    var wasRunning = metroProc.running
    stopMetro()
    if (wasRunning) wantStart = true // onRunningChanged fires the delayed start
    else metroStartHold.restart()
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
    if (root.tapIntervals.length > 4) root.tapIntervals = root.tapIntervals.slice(-4)
    root.lastTap = now
    if (root.tapIntervals.length === 0) return
    var recent = root.tapIntervals.slice(-4)
    var avg = 0
    for (var i = 0; i < recent.length; i++) avg += recent[i]
    avg /= recent.length
    root.bpm = Math.min(300, Math.max(20, Math.round(60000 / avg)))
    tapHold.restart()
  }

  // Single settle path for direct tempo edits: clamp, show immediately,
  // restart the pipeline 250ms after the last change. Chevrons, dial drag
  // and the slider all funnel through here (tap tempo keeps its own slower
  // 900ms settle so it never restarts mid-tap).
  function setBpm(v) {
    root.bpm = Math.min(300, Math.max(20, Math.round(v)))
    bpmHold.restart()
  }

  function stepBpm(d) {
    setBpm(root.bpm + d)
  }

  // Same settle path as setBpm: clamp, show immediately, restart the
  // pipeline 250ms after the last move so sliding never thrashes pw-play.
  function setVolume(v) {
    root.volume = clampInt(v, 0, 100, root.volume)
    volumeHold.restart()
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
              root.validSubdivisions.indexOf(root.subdivision) >= 0 ? root.subdivision : "1/4",
              String(clampInt(root.volume, 0, 100, 80))]
    stderr: SplitParser {
      onRead: function(line) {
        if (line.length > 256) return
        try {
          var d = JSON.parse(line)
          if (d && typeof d === "object" && typeof d.beat === "number" && isFinite(d.beat)) {
            root.pendingBeat = clampInt(d.beat, 1, root.beatsPerBar, 0)
            root.pipeFault = ""
            beatDelay.restart()
          } else if (d && typeof d === "object" && typeof d.error === "string") {
            root.pipeFault = d.error.slice(0, 120)
          }
        } catch (e) {}
      }
    }
    onRunningChanged: {
      if (!running && root.wantStart) {
        root.wantStart = false
        metroStartHold.restart()
      }
    }
    // Pipeline death must not leave the UI stuck on PLAYING.
    onExited: function(exitCode) {
      if (root.wantStart) return // a restart is already queued
      if (root.metroActive && root.active && exitCode !== 0 && !root.pipeFault)
        root.pipeFault = "audio failed (" + exitCode + ")"
      if (root.pipeFault) root.metroActive = false
    }
  }

  // Non-empty when the audio pipeline failed (missing pw-play, busy sink…).
  property string pipeFault: ""

  // Small stepper button that auto-repeats while held, for dialing in bpm.
  // Tab-focusable (Space/Return steps), screen-reader named, and dimmed via
  // `enabled` at the range limits. Focus shows as an accent border.
  component MetroStep: Rectangle {
    id: ms
    property string glyph: "+"
    property var action: function() {}
    property string accessName: ""
    property int w: 22
    property int h: 20

    width: Style.space(w)
    height: Style.space(h)
    radius: 3
    color: msArea.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.06)
    border.color: ms.activeFocus ? root.accent : root.border
    border.width: ms.activeFocus ? 2 : 1
    opacity: ms.enabled ? 1 : 0.35

    activeFocusOnTab: ms.enabled
    Accessible.role: Accessible.Button
    Accessible.name: ms.accessName || ms.glyph
    Keys.onReturnPressed: if (ms.enabled) ms.action()
    Keys.onEnterPressed: if (ms.enabled) ms.action()
    Keys.onSpacePressed: if (ms.enabled) ms.action()

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
      cursorShape: ms.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: ms.enabled
      onClicked: ms.action()
      onPressed: msDelay.start()
      onReleased: { msDelay.stop(); msRepeat.stop() }
      onCanceled: { msDelay.stop(); msRepeat.stop() }
    }

    Timer { id: msDelay; interval: 400; onTriggered: msRepeat.start() }
    Timer { id: msRepeat; interval: 80; repeat: true; onTriggered: ms.action() }
  }

  // Large thin chevron beside the dial; auto-repeats while held. A small
  // caption above names the step so each tier reads as −10 … +10.
  // Same keyboard/a11y contract as MetroStep; `enabled` dims tiers that
  // would clamp (already at 20/300 bpm).
  component ChevronStep: Item {
    id: cs
    property string glyph: "‹"
    property string caption: ""
    property string accessName: ""
    property var action: function() {}
    width: stepCol.implicitWidth
    height: stepCol.implicitHeight
    opacity: cs.enabled ? 1 : 0.35

    activeFocusOnTab: cs.enabled
    Accessible.role: Accessible.Button
    Accessible.name: cs.accessName || ("Tempo " + cs.caption)
    Keys.onReturnPressed: if (cs.enabled) cs.action()
    Keys.onEnterPressed: if (cs.enabled) cs.action()
    Keys.onSpacePressed: if (cs.enabled) cs.action()

    Column {
      id: stepCol
      anchors.centerIn: parent
      spacing: 2

      Text {
        id: capText
        anchors.horizontalCenter: parent.horizontalCenter
        text: cs.caption
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Math.max(9, Style.font.body - 4)
        textFormat: Text.PlainText
      }

      Text {
        id: csText
        anchors.horizontalCenter: parent.horizontalCenter
        text: cs.glyph
        color: csArea.pressed ? "#ffffff" : (cs.activeFocus ? "#ffffff" : root.accent)
        font.family: root.fontFamily
        font.pixelSize: Math.max(30, Style.font.title + 10)
        font.bold: true
        textFormat: Text.PlainText

        Behavior on color { ColorAnimation { duration: 80 } }
      }
    }

    MouseArea {
      id: csArea
      anchors.fill: parent
      anchors.margins: -Style.space(6)
      cursorShape: cs.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: cs.enabled
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
      detail: root.pipeFault ? "AUDIO ERROR" : (root.metroActive ? "PLAYING" : "")
      trailingControl: root.pinnable ? pinControl : null
      meta: root.pipeFault ? root.pipeFault : (root.bpm + " BPM · " + root.beatsPerBar + "/4 · " + root.subdivision)
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

    // ---------- Tempo: ‹‹‹ ‹‹ ‹ ◐ › ›› ››› + slider below ----------
    // The one tempo group: chevrons step ±1/±5/±10 outward from the dial
    // (all hold-to-repeat), the dial face itself drags horizontally (±1
    // per 6px), and the slider jumps. All settle through setBpm.
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "TEMPO · STEP, DRAG ◐, OR SLIDE"
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, Style.font.body - 4)
      font.bold: true
      font.letterSpacing: 2
      textFormat: Text.PlainText
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)

      ChevronStep { glyph: "‹‹‹"; caption: "−10"; accessName: "Decrease tempo by 10 BPM"; enabled: root.bpm > 20; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(-10) } }
      ChevronStep { glyph: "‹‹"; caption: "−5"; accessName: "Decrease tempo by 5 BPM"; enabled: root.bpm > 20; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(-5) } }
      ChevronStep { glyph: "‹"; caption: "−1"; accessName: "Decrease tempo by 1 BPM"; enabled: root.bpm > 20; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(-1) } }

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

        // Horizontal drag on the face dials the tempo directly (±1 per
        // 6px, settled via setBpm). Sits below the center disc so START /
        // STOP clicks win; horizontal-only, so the surrounding Flickable
        // keeps vertical scrolls.
        MouseArea {
          id: dialDrag
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          property real lastX: 0
          property real acc: 0
          onPressed: function(mouse) { lastX = mouse.x; acc = 0 }
          onPositionChanged: function(mouse) {
            if (!pressed) return
            acc += mouse.x - lastX
            lastX = mouse.x
            var step = Math.trunc(acc / 6)
            if (step !== 0) {
              acc -= step * 6
              root.setBpm(root.bpm + step)
            }
          }
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
            ctx.strokeStyle = root.accent
            ctx.beginPath()
            ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + root.dialAngle(root.bpm))
            ctx.stroke()
          }

          Connections {
            target: root
            function onBpmChanged() { dialArc.requestPaint() }
            function onCompactChanged() { dialArc.requestPaint() }
          }
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
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
        // Tab-focusable with a focus ring; Space/Return toggles playback.
        Rectangle {
          id: centerDisc
          anchors.centerIn: parent
          width: dial.width * 0.54
          height: width
          radius: width / 2
          color: root.metroActive ? root.accent : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18)
          border.color: root.accent
          border.width: centerDisc.activeFocus ? 3 : 1

          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: root.metroActive ? "Stop metronome" : "Start metronome"
          Keys.onReturnPressed: { root.metroActive = !root.metroActive; root.currentBeat = 0 }
          Keys.onEnterPressed: { root.metroActive = !root.metroActive; root.currentBeat = 0 }
          Keys.onSpacePressed: { root.metroActive = !root.metroActive; root.currentBeat = 0 }

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

      ChevronStep { glyph: "›"; caption: "+1"; accessName: "Increase tempo by 1 BPM"; enabled: root.bpm < 300; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(1) } }
      ChevronStep { glyph: "››"; caption: "+5"; accessName: "Increase tempo by 5 BPM"; enabled: root.bpm < 300; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(5) } }
      ChevronStep { glyph: "›››"; caption: "+10"; accessName: "Increase tempo by 10 BPM"; enabled: root.bpm < 300; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBpm(10) } }
    }

    // Beat dots — the current beat lights up, accent on the downbeat.
    // No animated Behaviors: at high tempi clicks arrive faster than the
    // animation duration and never settle.
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
        }
      }
    }

    // TAP button, centered under the dial. Tab-focusable (Space/Return
    // taps); tap 3+ times — a 2s pause starts a fresh run.
    Rectangle {
      id: tapButton
      anchors.horizontalCenter: parent.horizontalCenter
      width: tapLabel.implicitWidth + Style.space(28)
      height: Style.space(30)
      radius: height / 2
      color: tapMa.pressed ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35) : Qt.rgba(1, 1, 1, 0.06)
      border.color: root.accent
      border.width: tapButton.activeFocus ? 2 : 1

      activeFocusOnTab: true
      Accessible.role: Accessible.Button
      Accessible.name: "Tap tempo. Tap three or more times; a two second pause restarts the count"
      Keys.onReturnPressed: root.tapTempo()
      Keys.onEnterPressed: root.tapTempo()
      Keys.onSpacePressed: root.tapTempo()

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

    // Tempo slider — dial the bpm in directly (arc and number follow
    // along). Settles through the shared setBpm debounce, so sliding and
    // releasing need no separate restart: the pipeline picks up the final
    // value 250ms after the last move. Mouse-driven; keyboard users can
    // step the same range with the chevrons or dial drag above.
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "TEMPO SLIDER · 20–300 BPM"
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, Style.font.body - 4)
      font.bold: true
      font.letterSpacing: 2
      textFormat: Text.PlainText
    }

    PanelSlider {
      id: bpmSlider
      width: parent.width
      height: implicitHeight + Style.spacing.controlGap
      minimum: 20
      maximum: 300
      step: 1
      integer: true
      value: root.bpm
      onMoved: function(v) { root.setBpm(v) }
    }

    // Volume slider — click level for the metronome's own stream (system
    // sink untouched). Settles through the shared setVolume debounce, so
    // the pipeline picks up the final level 250ms after the last move.
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "CLICK VOLUME · " + root.volume + "%"
      color: root.foreground
      opacity: 0.55
      font.family: root.fontFamily
      font.pixelSize: Math.max(9, Style.font.body - 4)
      font.bold: true
      font.letterSpacing: 2
      textFormat: Text.PlainText
    }

    PanelSlider {
      id: volumeSlider
      width: parent.width
      height: implicitHeight + Style.spacing.controlGap
      minimum: 0
      maximum: 100
      step: 1
      integer: true
      value: root.volume
      onMoved: function(v) { root.setVolume(v) }
    }

    // Subdivisions: a compact 3-column grid of single-line chips — label
    // beside its note glyphs — at roughly half the height of the old
    // stacked tiles. Triplet feel reads off the beamed notes (♪♪♪, ♬♬♬)
    // and the "t" labels, so no second line is needed.
    Grid {
      width: parent.width
      columns: 3
      spacing: Style.space(6)

      Repeater {
        model: [
          { label: "1/4",   notes: "\u2669", tuplet: "", name: "Quarter notes" },
          { label: "1/8",   notes: "\u266B", tuplet: "", name: "Eighth notes" },
          { label: "1/8t",  notes: "\u266A\u266A\u266A", tuplet: "3", name: "Eighth note triplets" },
          { label: "swing", notes: "\u266A.\u266A", tuplet: "", name: "Swing eighths" },
          { label: "1/16",  notes: "\u266C\u266C", tuplet: "", name: "Sixteenth notes" },
          { label: "1/16t", notes: "\u266C\u266C\u266C", tuplet: "6", name: "Sixteenth note triplets" }
        ]

        Item {
          id: subTile
          required property var modelData
          readonly property bool selected: root.subdivision === subTile.modelData.label
          width: (parent.width - Style.space(12)) / 3
          // Size to the single-line content, not a magic number, so the
          // chips fit on any font or theme without overflowing.
          height: subRow.implicitHeight + Style.space(10)

          activeFocusOnTab: true
          Accessible.role: Accessible.Button
          Accessible.name: "Subdivision " + subTile.modelData.name + (subTile.selected ? ", selected" : "")
          Keys.onReturnPressed: root.setSubdivision(subTile.modelData.label)
          Keys.onEnterPressed: root.setSubdivision(subTile.modelData.label)
          Keys.onSpacePressed: root.setSubdivision(subTile.modelData.label)

          Rectangle {
            anchors.fill: parent
            radius: root.cornerRadius
            color: subTile.selected
              ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
              : (tileMa.pressed ? Qt.rgba(1,1,1,0.15) : Qt.rgba(1,1,1,0.05))
            border.color: (subTile.selected || subTile.activeFocus) ? root.accent : root.border
            border.width: subTile.activeFocus ? 2 : 1
            Behavior on color { ColorAnimation { duration: 100 } }
          }

          Row {
            id: subRow
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: subTile.modelData.label
              color: subTile.selected ? root.accent : root.foreground
              opacity: subTile.selected ? 1 : 0.75
              font.family: root.fontFamily
              font.pixelSize: Math.max(10, Style.font.body - 2)
              font.bold: true
              textFormat: Text.PlainText
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: subTile.modelData.notes
              color: subTile.selected ? root.accent : root.foreground
              opacity: subTile.selected ? 0.95 : 0.45
              font.family: root.fontFamily
              font.pixelSize: Math.max(14, Style.font.body + 2)
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

      MetroStep { glyph: "−"; accessName: "Fewer beats per bar"; enabled: root.beatsPerBar > 1; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBeats(-1) } }
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
      MetroStep { glyph: "+"; accessName: "More beats per bar"; enabled: root.beatsPerBar < 12; anchors.verticalCenter: parent.verticalCenter; action: function() { root.stepBeats(1) } }
    }
  }
}
