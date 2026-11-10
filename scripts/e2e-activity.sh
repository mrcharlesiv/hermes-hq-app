#!/bin/zsh
# End-to-end UI tests of the activity stream (UITests/activity/ActivityEndToEndTests.swift) against the activity fixture
# (scripts/fixtures/activity-gateway.py, docs/spec/1x-activity.md §15.1).
# Usage: scripts/e2e-activity.sh [SIM_UDID] [RUNS]
#   Starts the fixture on 127.0.0.1:$HQN_E2E_PORT (default 9732; refuses a busy port), with a media folder holding a
#   test PNG for the generated-image check; writes its invented credentials to build/fixtures/e2e-activity.json (0600,
#   never printed); runs ActivityEndToEndTests RUNS times (default 1) in light appearance and, with HQN_E2E_DARK=1, the
#   screenshot tests once more in dark; saves screenshots to .build/shots/ (<name>-light.png, <name>-dark.png); stops
#   the fixture it started. HQN_E2E_ONLY="test11_…,test16_…" runs only those tests.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-E3EC34C7-4986-480D-9896-C6F8E814CF80}}
RUNS=${2:-1}
PORT=${HQN_E2E_PORT:-9732}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
mkdir -p $FIX $FIX/media $SHOTS && chmod 700 $FIX
# HQN_ANY_PORT=1: another range (integration runs every suite on its own ports).
[[ -n "$HQN_ANY_PORT" ]] || case $PORT in 973[2-4]) ;; *) echo "use a port in 9732-9734 (HQN_E2E_PORT)"; exit 1;; esac
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_E2E_PORT to a free port in 9732-9734"; exit 1
fi
# A 512×512 test picture for the generated-image card.
python3 - "$FIX/media/sunrise.png" <<'PY'
import struct, sys, zlib
w = h = 512
rows = b''.join(b'\x00' + b''.join(bytes((255, 120 + y * 100 // h, 60 + x * 120 // w)) for x in range(w)) for y in range(h))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                              + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b''))
PY
rm -f $FIX/e2e-activity.json
HQN_ACTIVITY_MEDIA=$PWD/$FIX/media python3 scripts/fixtures/activity-gateway.py --port $PORT --credentials $FIX/e2e-activity.json > $FIX/e2e-activity.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true; xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true; xcrun simctl spawn $SIM defaults delete com.apple.Preferences AutomaticMinimizationEnabled >/dev/null 2>&1 || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-activity.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-activity.json ]] || { echo "fixture did not start (see $FIX/e2e-activity.log)"; exit 1; }
echo "activity fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
KEYBOARD_TEST=test11b_SteerWithTheKeyboardUp
run_suite() {   # $1 = appearance, $2 = comma-separated tests (empty = all but the software-keyboard test)
  local appearance=$1 only=$2 args=()
  xcrun simctl ui $SIM appearance $appearance >/dev/null 2>&1 || true
  if [[ -n $only ]]; then
    for t in ${(s:,:)only}; do args+=(-only-testing:HermesHQNativeUITests/ActivityEndToEndTests/$t); done
  else
    args=(-only-testing:HermesHQNativeUITests/ActivityEndToEndTests -skip-testing:HermesHQNativeUITests/ActivityEndToEndTests/$KEYBOARD_TEST)
  fi
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-activity.json TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_SHOTS_SUFFIX=$appearance \
  TEST_RUNNER_HQN_ACTIVITY_MEDIA=$PWD/$FIX/media \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $args \
    > build/last-e2e-activity-$appearance.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-activity-$appearance.log | tail -20
  echo "e2e-activity ($appearance): xcodebuild exit $STATUS"
  return $STATUS
}
# The software keyboard (the Steer card's cap with the keyboard up): this simulator only, put back afterwards. Headless
# simulators count as having a hardware keyboard, which keeps the on-screen one minimized.
keyboard_suite() {
  xcrun simctl spawn $SIM defaults write com.apple.Preferences AutomaticMinimizationEnabled -bool NO >/dev/null 2>&1 || true
  run_suite light $KEYBOARD_TEST; local rc=$?
  xcrun simctl spawn $SIM defaults delete com.apple.Preferences AutomaticMinimizationEnabled >/dev/null 2>&1 || true
  return $rc
}
FAILED=0
for run in $(seq 1 $RUNS); do
  if [[ $HQN_E2E_ONLY == $KEYBOARD_TEST ]]; then
    keyboard_suite || FAILED=1
  else
    run_suite ${HQN_E2E_APPEARANCE:-light} "$HQN_E2E_ONLY" || FAILED=1   # integration: a dark pass of a subset
    [[ -z $HQN_E2E_ONLY ]] && { keyboard_suite || FAILED=1; }
  fi
done
if [[ $HQN_E2E_DARK == 1 ]]; then
  run_suite dark "test11_SubagentChipCardSteerAndStop,test16_TasksThenPreviousTasks,test17_GoalChipCardAndActions,test22_DelegationFoldsShowStepsAndDiff,test21_BubblesFoldEarlierStepsAndShowShell,test23_InHeaderStatusAndStepsSheet,test26_GeneratedImageCard,test28_ToolCallsScreen" || FAILED=1
fi
exit $FAILED
