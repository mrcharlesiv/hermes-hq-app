#!/bin/zsh
# End-to-end UI tests of the menus stream (UITests/menus/MenusTests.swift, and the chat actions in
# UITests/menus/MenusTests+ChatActions.swift: test20–test26) against the menus fixture
# (scripts/fixtures/menus-gateway.py, docs/spec/1x-menus.md §12).
# Usage: scripts/e2e-menus.sh [SIM_UDID] [RUNS]
#   Starts the menus fixture on 127.0.0.1:$HQN_MENUS_PORT (default 9729) and an old-gateway instance on
#   $HQN_MENUS_OLD_PORT (default 9730), refusing busy ports; writes their invented credentials to build/fixtures (0600,
#   never printed); passes them to the runner as TEST_RUNNER_HQN_UI_CREDENTIALS / TEST_RUNNER_HQN_UI_OLD_CREDENTIALS and
#   the screenshot folder as TEST_RUNNER_HQN_UI_SHOTS (default .build/shots); runs the HermesHQNativeUI scheme with
#   -only-testing:HermesHQNativeUITests/MenusTests; stops only the fixtures it started.
#   HQN_MENUS_ONLY="test03_…,test10_…" runs only those tests; HQN_MENUS_DARK=1 runs them in dark appearance;
#   HQN_MENUS_AX3=1 sets the simulator's text size to AX3 for the run (test16's large-text screenshots).
#   HQN_MENUS_DESKTOPLOOK=1 launches the app with the Desktop Look on; HQN_MENUS_SKIN=<id> with that skin.
#   Use this stream's own simulator (HQN-menus 58CAE3EE-2061-43F9-91A2-9A1E7C42FB8F).
#
# "Critical process HermesHQNative crashed in (null)" is usually NOT this app crashing: XCTest watches for crashes by
# process name across every simulator ("listening for crashes of extra processes named HermesHQNative"), so another
# stream's app crashing on its own simulator fails this run, and xcodebuild then SIGTERMs our app. Before blaming the
# app, look at how it exited (this script prints it after such a failure):
#   xcrun simctl spawn <udid> log show --last 15m --predicate 'process == "launchd_sim" AND eventMessage CONTAINS "exited due"'
# "exited due to SIGTERM | sent by xcodebuild[…]" = a harness artifact; rerun when no other stream's UI suite runs
# (streams' UI suites run serially, or each with its own PRODUCT_NAME, so crash attribution can't cross simulators).
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A}}
RUNS=${2:-1}
PORT=${HQN_MENUS_PORT:-9729}
OLD_PORT=${HQN_MENUS_OLD_PORT:-9730}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

for p in $PORT $OLD_PORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use; set HQN_MENUS_PORT/HQN_MENUS_OLD_PORT"; exit 1; fi
done
rm -f $FIX/menus.json $FIX/menus-old.json
python3 scripts/fixtures/menus-gateway.py --port $PORT --credentials $FIX/menus.json > $FIX/menus.log 2>&1 &
MAIN_PID=$!
python3 scripts/fixtures/menus-gateway.py --port $OLD_PORT --credentials $FIX/menus-old.json > $FIX/menus-old.log 2>&1 &
OLD_PID=$!
trap 'kill $MAIN_PID $OLD_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/menus.json && -s $FIX/menus-old.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$OLD_PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/menus.json && -s $FIX/menus-old.json ]] || { echo "fixtures did not start (see $FIX/menus*.log)"; exit 1; }
curl -s -X POST http://127.0.0.1:$OLD_PORT/__menus/mode -d '{"oldGateway":true}' > /dev/null
echo "menus fixture on 127.0.0.1:$PORT (pid $MAIN_PID), old-gateway instance on $OLD_PORT (pid $OLD_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_MENUS_ONLY" ]]; then
  for t in ${(s:,:)HQN_MENUS_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/MenusTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/MenusTests)
fi
# HQN_MENUS_DARK=1: the simulator itself is dark for the run (and light again after), besides each test asking for it.
if [[ "$HQN_MENUS_DARK" == "1" ]]; then
  xcrun simctl ui $SIM appearance dark
  trap 'xcrun simctl ui $SIM appearance light; kill $MAIN_PID $OLD_PID 2>/dev/null || true' EXIT INT TERM
fi
# HQN_MENUS_AX3=1: the simulator's text size is AX3 for this run (test16 takes the large-text screenshots), reset after.
if [[ "$HQN_MENUS_AX3" == "1" ]]; then
  xcrun simctl ui $SIM content_size accessibility-extra-extra-extra-large
  trap 'xcrun simctl ui $SIM content_size large; kill $MAIN_PID $OLD_PID 2>/dev/null || true' EXIT INT TERM
fi
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/menus.json TEST_RUNNER_HQN_UI_OLD_CREDENTIALS=$PWD/$FIX/menus-old.json \
  TEST_RUNNER_HQN_UI_SHOTS=$SHOTS TEST_RUNNER_HQN_UI_AX3=${HQN_MENUS_AX3:-0} TEST_RUNNER_HQN_UI_DARK=${HQN_MENUS_DARK:-0} \
  TEST_RUNNER_HQN_UI_DESKTOPLOOK=${HQN_MENUS_DESKTOPLOOK:-0} TEST_RUNNER_HQN_UI_SKIN=${HQN_MENUS_SKIN:-} \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -test-timeouts-enabled YES -default-test-execution-time-allowance 420 $ONLY \
    > build/last-e2e-menus-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-menus-$run.log | tail -20
  if grep -q "crashed in (null)" build/last-e2e-menus-$run.log; then
    echo "a 'crashed in (null)' failure: how HermesHQNative processes exited on $SIM (SIGTERM sent by xcodebuild = not our crash):"
    xcrun simctl spawn $SIM log show --last 15m --style compact \
      --predicate 'process == "launchd_sim" AND eventMessage CONTAINS "exited due" AND eventMessage CONTAINS "HermesHQNative"' 2>/dev/null | tail -8
  fi
  echo "e2e-menus run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
