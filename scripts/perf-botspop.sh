#!/bin/zsh
# [perf] Build 297 "Smooth back to Bots": measures the pop from a chat back to the Bots list with the app's own
# FrameMeter, against the back-to-Bots fixture (scripts/fixtures/botspop-gateway.py on 127.0.0.1:10000), and prints
# the `frames` records the app uploads to it.
#
#   scripts/perf-botspop.sh <SIM_UDID> loop [n]   in-app loop (-HQDebugPopLoop, App/Debug/PopLoopDebugHook.swift): Inbox
#                                                 starts a long turn, then n opens and Back pops (default 16) with
#                                                 nothing querying the app from outside. The number to compare.
#   scripts/perf-botspop.sh <SIM_UDID> ui         UITests/perf/BotsPopPerfTests.swift: Back button and edge swipe pops
#                                                 driven by XCUITest (its accessibility queries load the main thread:
#                                                 compare runs with each other only)
#
# HQN_BOTSPOP_TRACE=<path.txt> samples the app's threads (macOS `sample`, 1 ms) through the loop or the Back-button phase
# (HQN_BOTSPOP_SECONDS long, default 40); <path.trace> records a Time Profiler trace instead (timestamped samples). Build first (scripts/build.sh build <SIM_UDID>); `ui` runs
# test-without-building when HQN_BOTSPOP_NOBUILD=1. HQN_BOTSPOP_PORT moves the fixture; HQN_DD picks the derived data;
# HQN_BOTSPOP_APP installs another build for `loop` (a copy of the build before a change, to alternate with it).
set -e
cd "$(dirname "$0")/.."
SIM=${1:?pass your own simulator UDID}
MODE=${2:-loop}
PORT=${HQN_BOTSPOP_PORT:-10000}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
UPLOADS=$FIX/botspop-lines.jsonl
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is busy; stop it first"; exit 1; fi
rm -f $FIX/botspop.json $UPLOADS
BOTSPOP_LOG_OUT=$UPLOADS python3 scripts/fixtures/botspop-gateway.py --port $PORT --hermes-cookies --credentials $FIX/botspop.json \
  > $FIX/botspop.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT INT TERM
for i in {1..60}; do
  [[ -s $FIX/botspop.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
# Booted here so the run leaves it up for the reads after (xcodebuild shuts down a simulator it booted itself).
xcrun simctl boot $SIM 2>/dev/null || true
xcrun simctl bootstatus $SIM -b >/dev/null
BUNDLE=$([[ ${HQ_IDENTITY:-native} == original ]] && echo com.charlesmcdowell.dispatch || echo com.charlesmcdowell.hermeshq.native)
APP_PATH=${HQN_BOTSPOP_APP:-${HQN_DD:-build/dd}/Build/Products/Debug-iphonesimulator/HermesHQNative.app}

# Samples the app once `$1` shows in the uploaded lines.
trace_from() {
  [[ -n "$HQN_BOTSPOP_TRACE" ]] || return 0
  rm -f "$HQN_BOTSPOP_TRACE"
  ( until grep -q "$1" $UPLOADS 2>/dev/null; do sleep 0.2; done
    APP=$(pgrep -f "$SIM/.*/HermesHQNative.app/HermesHQNative" | head -1)
    if [[ $HQN_BOTSPOP_TRACE == *.trace ]]; then
      xcrun xctrace record --template 'Time Profiler' --device $SIM --attach $APP --time-limit ${HQN_BOTSPOP_SECONDS:-40}s \
        --output "$HQN_BOTSPOP_TRACE" > build/last-perf-botspop-trace.log 2>&1
    else
      sample $APP ${HQN_BOTSPOP_SECONDS:-40} 1 -mayDie -file "$HQN_BOTSPOP_TRACE" > build/last-perf-botspop-trace.log 2>&1
    fi ) &
  TRACER=$!
}
TRACER=
STATUS=0
if [[ $MODE == loop ]]; then
  COUNT=${3:-16}
  xcrun simctl install $SIM $APP_PATH
  xcrun simctl terminate $SIM $BUNDLE 2>/dev/null || true
  # The loop's start is uploaded as soon as it is noted (FrameMeter's pre-loop buckets go with it).
  trace_from '"m":"pop loop: '
  CREDS=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["url"], d["username"], d["password"])' $FIX/botspop.json)
  read -r URL USER PASS <<< "$CREDS"
  SIMCTL_CHILD_HQN_SIGNIN_URL=$URL SIMCTL_CHILD_HQN_SIGNIN_USERNAME=$USER SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=$PASS \
    xcrun simctl launch $SIM $BUNDLE -HQDebugResetAccounts YES -HQDebugNoSwipePeek YES \
    -HQDebugOpenBot inbox -HQDebugSend "slow: keep working" -HQDebugPopLoop $COUNT > /dev/null
  for i in {1..400}; do grep -q '"m":"pop loop done"' $UPLOADS 2>/dev/null && break; sleep 0.5; done
  grep -q '"m":"pop loop done"' $UPLOADS || { echo "the loop did not finish (see $UPLOADS)"; STATUS=1; }
  sleep 1
else
  trace_from '"m":"background"'
  ACTION=test
  [[ -n "$HQN_BOTSPOP_NOBUILD" ]] && ACTION=test-without-building
  TEST_RUNNER_HQN_BOTSPOP_PAUSE=${HQN_BOTSPOP_TRACE:+3} TEST_RUNNER_HQN_SETTINGS_A=$PWD/$FIX/botspop.json \
  TEST_RUNNER_HQN_BOTSPOP=1 TEST_RUNNER_HQN_SHOTS=$SHOTS \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never $ACTION -quiet \
    -only-testing:HermesHQNativeUITests/SettingsEndToEndTests/testP01_BackToBotsFrames > build/last-perf-botspop.log 2>&1 || STATUS=$?
  grep -E "error:|failed|passed" build/last-perf-botspop.log | tail -8
  sleep 2   # the last upload lands
fi
[[ -n "$TRACER" ]] && wait $TRACER
[[ -n "$HQN_BOTSPOP_TRACE" ]] && cp "$(xcrun simctl get_app_container $SIM $BUNDLE data)/Documents/Logs/app.log" "${${HQN_BOTSPOP_TRACE%.txt}%.trace}-app.log"
python3 - $UPLOADS $MODE <<'PY'
import json, sys
# ui: FrameMeter sends its buckets as the app resigns, just before the "background" note that closes the phase.
# loop: the buckets sent before "pop loop: …" are the setup's; those after it, the loop's.
names = ["setup", "button", "swipe"] if sys.argv[2] == "ui" else ["setup", "loop"]
phase = 0
for line in open(sys.argv[1]):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("k") == "note.app" and e.get("m") == "background" and sys.argv[2] == "ui": phase += 1
    if e.get("k") == "note.perf" and str(e.get("m", "")).startswith("pop loop:"): phase = 1
    if e.get("k") not in ("frames", "frames.bad"): continue
    name = names[phase] if phase < len(names) else f"phase{phase}"
    total = e.get("dur", 0)
    ratio = float(e.get("hit", 0)) / (total / 1000) if e["k"] == "frames" and total else float(e.get("hr", 0))
    print(f'{name:7} {e["k"]:10} {e.get("kd",""):10} {e.get("scr",""):28} n={e.get("n","-")} ratio={ratio:.1f} '
          f'worst={e.get("wf")}ms missed={e.get("mf")} hz={e.get("hz")} rs={e.get("rs","")}')
PY
echo "perf-botspop $MODE: exit $STATUS"
exit $STATUS
