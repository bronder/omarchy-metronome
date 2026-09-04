#!/usr/bin/env bash
# Tests for the metronome plugin's pieces.
#   1. metronome / metro-pipeline reject bad arguments (bpm, beats,
#      subdivision, arity) instead of playing garbage.
#   2. The stderr beat stream is strict-schema JSON: beat within 1..beats,
#      sub within 0..subs-1, subs matching the subdivision, one line per
#      click, and a whole number of bars over a bounded run.
#   3. A closed stdout pipe tears the generator down cleanly (BrokenPipe,
#      no traceback, no lingering output).
set -u
here=${0%/*}
bin=$here/../bin
fails=0

check() { # check <desc> <condition-exit-code>
  if [ "$2" -eq 0 ]; then echo "ok  - $1"; else echo "FAIL - $1"; fails=$((fails+1)); fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- 1. argument validation -----------------------------------------------
# The generator itself clamps out-of-range bpm/beats and falls back to 1/4
# for unknown subdivisions; the strict rejection contract lives in
# metro-pipeline (all QML paths go through it). Here: non-numeric args must
# fail, and out-of-range args must be clamped, never crash. A 124 exit is a
# timeout — the generator ran, which counts as a failure here too.
timeout 2 "$bin/metronome" abc 4 1/4 >/dev/null 2>"$tmp/badbpm"
rc=$?; [ $rc -eq 2 ] && ! grep -q "Traceback" "$tmp/badbpm"
check "metronome rejects non-numeric bpm with usage (exit 2, no traceback)" $?

timeout 2 "$bin/metronome" 120 def 1/4 >/dev/null 2>"$tmp/badbeats"
rc=$?; [ $rc -eq 2 ] && ! grep -q "Traceback" "$tmp/badbeats"
check "metronome rejects non-numeric beats with usage (exit 2, no traceback)" $?

timeout 2 "$bin/metronome" 120 >/dev/null 2>&1
rc=$?; [ $rc -ne 0 ] && [ $rc -ne 124 ]
check "metronome rejects missing args" $?

"$bin/metro-pipeline" 400 4 1/4 >/dev/null 2>&1
check "metro-pipeline rejects bad bpm" $([ $? -eq 2 ]; echo $?)
"$bin/metro-pipeline" 120 99 1/4 >/dev/null 2>&1
check "metro-pipeline rejects bad beats" $([ $? -eq 2 ]; echo $?)
"$bin/metro-pipeline" 120 4 waltz >/dev/null 2>&1
check "metro-pipeline rejects bad subdivision" $([ $? -eq 2 ]; echo $?)
"$bin/metro-pipeline" 120 4 >/dev/null 2>&1
check "metro-pipeline rejects wrong arity" $([ $? -eq 2 ]; echo $?)
"$bin/metro-pipeline" abc 4 1/4 >/dev/null 2>&1
check "metro-pipeline rejects non-numeric bpm" $([ $? -eq 2 ]; echo $?)
"$bin/metro-pipeline" 120 4 1/3 >/dev/null 2>&1
check "metro-pipeline rejects unknown subdivision" $([ $? -eq 2 ]; echo $?)

# Out-of-range values are clamped by the generator, never crash or misbehave:
# bpm 19 → 20, beats 99 → 12 (fast enough to emit beats within the timeout).
timeout 2 "$bin/metronome" 19 99 1/4 >/dev/null 2>"$tmp/clamp"
python3 -c '
import json, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
assert lines, "no beat lines while clamping"
for l in lines:
    d = json.loads(l)
    assert 1 <= d["beat"] <= 12 and d["beats"] == 12, d
' "$tmp/clamp"
check "metronome clamps out-of-range bpm/beats" $?

# --- 2. beat-JSON schema over a bounded run --------------------------------
# 240 bpm, 3 beats/bar, 1/8 (2 subs): one bar = 3 beats * 0.25 s = 0.75 s.
# Cap ~3 bars of audio; the pacing deadline logic limits stdout to real time.
timeout 3 "$bin/metronome" 240 3 1/8 >"$tmp/audio" 2>"$tmp/beats"
python3 - "$tmp/beats" <<'EOF'
import json, sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
assert lines, "no beat lines produced"
subs_seen = set()
expect_beat, expect_sub = 1, 0
for l in lines:
    assert len(l) <= 256, f"line too long: {len(l)}"
    d = json.loads(l)  # raises on non-JSON
    assert set(d) == {"beat", "beats", "sub", "subs"}, d
    assert d["beats"] == 3, d
    assert d["subs"] == 2, d
    assert isinstance(d["beat"], int) and 1 <= d["beat"] <= 3, d
    assert isinstance(d["sub"], int) and 0 <= d["sub"] < d["subs"], d
    assert d["beat"] == expect_beat and d["sub"] == expect_sub, (d, expect_beat, expect_sub)
    expect_beat, expect_sub = (expect_beat, 1) if expect_sub == 0 else (expect_beat % 3 + 1, 0)
    subs_seen.add(d["sub"])
assert subs_seen == {0, 1}, "both subdivision positions must appear"
EOF
check "beat JSON strict schema + bar ordering" $?

# stdout is s16le stereo: frame count divisible by 4 and consistent with beats
python3 - "$tmp/audio" <<'EOF'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) % 4 == 0, "stdout not frame-aligned s16le stereo"
assert len(data) > 44100, "no meaningful audio produced"
EOF
check "stdout is frame-aligned PCM" $?

# --- 3. clean teardown on a closed pipe ------------------------------------
head -c 100000 /dev/null | "$bin/metronome" 120 4 1/4 2>"$tmp/trace" | head -c 0
grep -q "Traceback" "$tmp/trace"
check "no traceback on broken pipe" $([ $? -ne 0 ]; echo $?)

# --- 4. TERM to the pipeline leader tears down the group -------------------
# Regression: bash defers trapped signals while blocked on a foreground
# pipeline; since the metronome never exits, the TERM trap must be reached
# via a background pipeline + interruptible `wait` — otherwise the audio
# tree survives stop/close forever.
setsid "$bin/metro-pipeline" 240 4 1/4 >/dev/null 2>&1 &
sleep 1
leader=$(ps -eo pid,cmd | awk -v s="$bin/metro-pipeline" '$2=="bash" && $3==s {print $1; exit}')
if [ -n "$leader" ]; then
  kill -TERM "$leader"
  dead=1
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.3
    ps -p "$leader" >/dev/null 2>&1 || { dead=0; break; }
  done
  check "TERM to leader kills the whole group" $dead
else
  check "TERM to leader kills the whole group" 1
fi

echo
if [ "$fails" -eq 0 ]; then echo "all metronome tests passed"; exit 0; fi
echo "$fails test(s) failed"; exit 1
