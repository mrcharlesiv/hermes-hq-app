#!/bin/zsh
# [offline] The offline screen, the launch screen and reconnect behaviour end to end
# (UITests/offline/OfflineEndToEndTests.swift) against the offline stand-in (scripts/fixtures/offline-gateway.py).
# Usage: scripts/e2e-offline.sh SIM_UDID
#   Starts stand-in A on 127.0.0.1:${HQN_OFFLINE_PORT:-9980} with its control port one above, and B two above with its
#   control port three above (9980-9989 only; refuses a busy port). Credentials go to build/fixtures/e2e-offline.json and
#   e2e-offline-b.json (0600, never printed). Runs -only-testing:HermesHQNativeUITests/OfflineEndToEndTests
#   (HQN_OFFLINE_ONLY="testO1_…,…" narrows it) and stops what it started. Screens go to build/shots (HQN_SHOTS_DIR).
#   Two passes: everything with the simulator light, then testO18_DarkScreens with the simulator dark from before its
#   test session starts (an app a UI test launches keeps the appearance the simulator had when the session began, so
#   the dark screenshots cannot be taken by switching inside the light pass). HQN_OFFLINE_APPEARANCE=light|dark runs
#   one pass only. Following the system live is checked without XCTest by scripts/offline-appearance-check.sh.
#   Derived data: ${HQN_DD:-build/dd}. Use your own simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-offline.sh SIM_UDID}
PORT=${HQN_OFFLINE_PORT:-9980}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots}
DD=${HQN_DD:-build/dd}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if [[ -z "$HQN_ANY_PORT" ]] && (( PORT < 9980 || PORT + 3 > 9989 )); then echo "HQN_OFFLINE_PORT must leave four ports inside 9980-9989"; exit 1; fi
for p in $PORT $((PORT + 1)) $((PORT + 2)) $((PORT + 3)); do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use"; exit 1; fi
done
A=$FIX/e2e-offline.json; B=$FIX/e2e-offline-b.json
rm -f $A $B
python3 scripts/fixtures/offline-gateway.py --port $PORT --control-port $((PORT + 1)) --credentials $A > $FIX/e2e-offline.log 2>&1 &
PID_A=$!
python3 scripts/fixtures/offline-gateway.py --port $((PORT + 2)) --control-port $((PORT + 3)) --credentials $B --label B > $FIX/e2e-offline-b.log 2>&1 &
PID_B=$!
trap 'kill $PID_A $PID_B 2>/dev/null || true; xcrun simctl ui "$SIM" appearance light >/dev/null 2>&1 || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $A && -s $B ]] && lsof -nP -iTCP:$((PORT + 1)) -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$((PORT + 3)) -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $A && -s $B ]] || { echo "the stand-ins did not start (see $FIX/e2e-offline.log)"; exit 1; }
echo "offline stand-ins on 127.0.0.1:$PORT and :$((PORT + 2)) (pids $PID_A $PID_B)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_OFFLINE_ONLY" ]]; then
  for t in ${(s:,:)HQN_OFFLINE_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/OfflineEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/OfflineEndToEndTests)
fi
STATUS=0
pass() {   # light|dark, then the -only-testing arguments
  local mode=$1; shift
  xcrun simctl ui "$SIM" appearance $mode >/dev/null 2>&1 || true
  # The switch is not instant on a loaded Mac: wait until the simulator reports it (30 s at most), then let it settle.
  for i in {1..30}; do
    [[ "$(xcrun simctl ui "$SIM" appearance 2>/dev/null)" == "$mode" ]] && break
    sleep 1
  done
  sleep 4
  local code=0
  TEST_RUNNER_HQN_UI_START_DARK=$([[ $mode == dark ]] && echo 1 || echo 0) TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$A \
    TEST_RUNNER_HQN_UI_CREDENTIALS_B=$PWD/$B TEST_RUNNER_HQN_UI_OFFLINE=1 \
    TEST_RUNNER_HQN_OFFLINE_CONTROL=http://127.0.0.1:$((PORT + 1)) TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD -parallel-testing-enabled NO \
    -collect-test-diagnostics never test -quiet "$@" \
    > build/last-e2e-offline-$mode.log 2>&1 || code=$?
  local result=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  echo "== $mode pass =="
  python3 scripts/e2e-summary.py "$result" || grep -E "error:|failed" build/last-e2e-offline-$mode.log | tail -20
  echo "offline e2e ($mode pass): xcodebuild exit $code"
  (( code == 0 )) || STATUS=$code
}
case "${HQN_OFFLINE_APPEARANCE:-both}" in
  light) pass light $ONLY ;;
  dark)  pass dark $ONLY ;;
  *)     pass light $ONLY
         # The dark pass is the dark-screens test alone (it skips itself in the light pass).
         if [[ -z "$HQN_OFFLINE_ONLY" || "$HQN_OFFLINE_ONLY" == *testO18_DarkScreens* ]]; then
           pass dark -only-testing:HermesHQNativeUITests/OfflineEndToEndTests/testO18_DarkScreens
         fi ;;
esac
echo "offline e2e: exit $STATUS"
exit $STATUS
