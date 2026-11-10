#!/bin/zsh
# End-to-end UI tests of the groups stream (UITests/groups/GroupsEndToEndTests*.swift) against the groups fixture
# (scripts/fixtures/groups-gateway.py, docs/spec/3x-groups.md §8).
# HQN_GROUPS_ALLOWANCE=900: seconds one test may take before it is cut off (default 420; raise it on a very busy Mac).
# Usage: scripts/e2e-groups.sh SIM_UDID [RUNS]
#   Starts three instances, refusing busy ports: the main one on 127.0.0.1:$HQN_GROUPS_PORT (default 9960), a second
#   gateway labelled "Studio" on $HQN_GROUPS_B_PORT (default 9961) and an old gateway without revisions on
#   $HQN_GROUPS_OLD_PORT (default 9962). Their invented credentials go to build/fixtures (0600, never printed) and reach
#   the runner as TEST_RUNNER_HQN_UI_CREDENTIALS / _B_CREDENTIALS / _OLD_CREDENTIALS; screenshots land in
#   TEST_RUNNER_HQN_UI_SHOTS (default build/shots). Runs the HermesHQNativeUI scheme with
#   -only-testing:HermesHQNativeUITests/GroupsEndToEndTests and stops only the three fixtures it started.
#   HQN_GROUPS_ONLY="testA1_…,testC2_…" runs only those tests; HQN_GROUPS_DARK=1 runs in dark appearance; HQN_GROUPS_DESKTOP=1 with Desktop Look on;
#   HQN_GROUPS_AX=accessibility-extra-extra-extra-large runs the app at that text size (each test signs in at the
#   standard size, then relaunches the app with the size; the simulator's own setting is not touched).
#   The simulator is always passed by UDID (this stream's: HQN-m9-groups; the stress tester's: HQN-m9-groups-s with
#   HQN_GROUPS_PORT=9965 HQN_GROUPS_B_PORT=9966 HQN_GROUPS_OLD_PORT=9967 HQN_DD=build/dd-stress).
#
# "Critical process HermesHQNative crashed in (null)" is usually NOT this app crashing (see scripts/e2e-menus.sh):
# another stream's app crashing on its own simulator fails this run. Look at how the app exited (printed below after
# such a failure) and rerun before calling it a failure.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-}}
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-groups.sh SIM_UDID [RUNS] (pass your own simulator's UDID)"; exit 2; }
RUNS=${2:-1}
PORT=${HQN_GROUPS_PORT:-9960}
B_PORT=${HQN_GROUPS_B_PORT:-9961}
OLD_PORT=${HQN_GROUPS_OLD_PORT:-9962}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
DD=${HQN_DD:-build/dd}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

python3 scripts/fixtures/groups-gateway.py --self-test > $FIX/groups-self-test.log 2>&1 || { echo "the fixture's self-test failed:"; tail -20 $FIX/groups-self-test.log; exit 1; }
for p in $PORT $B_PORT $OLD_PORT; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use; set HQN_GROUPS_PORT / HQN_GROUPS_B_PORT / HQN_GROUPS_OLD_PORT"; exit 1; fi
done
rm -f $FIX/groups.json $FIX/groups-b.json $FIX/groups-old.json
python3 scripts/fixtures/groups-gateway.py --port $PORT --credentials $FIX/groups.json > $FIX/groups.log 2>&1 &
MAIN_PID=$!
python3 scripts/fixtures/groups-gateway.py --port $B_PORT --credentials $FIX/groups-b.json --label "Studio" > $FIX/groups-b.log 2>&1 &
B_PID=$!
python3 scripts/fixtures/groups-gateway.py --port $OLD_PORT --credentials $FIX/groups-old.json --no-revisions > $FIX/groups-old.log 2>&1 &
OLD_PID=$!
RESTORE=""
trap 'eval "$RESTORE"; kill $MAIN_PID $B_PID $OLD_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/groups.json && -s $FIX/groups-b.json && -s $FIX/groups-old.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$B_PORT -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$OLD_PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/groups.json && -s $FIX/groups-b.json && -s $FIX/groups-old.json ]] || { echo "fixtures did not start (see $FIX/groups*.log)"; exit 1; }
echo "groups fixture on 127.0.0.1:$PORT (pid $MAIN_PID), second gateway on $B_PORT (pid $B_PID), old gateway on $OLD_PORT (pid $OLD_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_GROUPS_ONLY" ]]; then
  for t in ${(s:,:)HQN_GROUPS_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/GroupsEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/GroupsEndToEndTests)
fi
# The appearance below is set on a booted simulator (it is shut down between this stream's runs).
if [[ "$HQN_GROUPS_DARK" == "1" ]]; then xcrun simctl bootstatus $SIM -b > /dev/null 2>&1 || true; fi
# HQN_GROUPS_DARK=1: the simulator itself is dark for the run (and light again after), besides each test asking for it.
if [[ "$HQN_GROUPS_DARK" == "1" ]]; then
  xcrun simctl ui $SIM appearance dark
  RESTORE="$RESTORE xcrun simctl ui $SIM appearance light || true;"
fi
# HQN_GROUPS_AX=<content size>: passed to the tests, which relaunch the app at that size after signing in (the sign-in
# form is not this stream's and cannot be driven at the largest sizes).
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/groups.json TEST_RUNNER_HQN_UI_B_CREDENTIALS=$PWD/$FIX/groups-b.json \
  TEST_RUNNER_HQN_UI_OLD_CREDENTIALS=$PWD/$FIX/groups-old.json TEST_RUNNER_HQN_UI_SHOTS=$SHOTS \
  TEST_RUNNER_HQN_UI_DARK=${HQN_GROUPS_DARK:-0} TEST_RUNNER_HQN_UI_DESKTOP=${HQN_GROUPS_DESKTOP:-0} TEST_RUNNER_HQN_UI_AX=${HQN_GROUPS_AX:-} \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD test -test-timeouts-enabled YES -default-test-execution-time-allowance ${HQN_GROUPS_ALLOWANCE:-420} -maximum-test-execution-time-allowance ${HQN_GROUPS_ALLOWANCE:-420} $ONLY \
    > build/last-e2e-groups-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-groups-$run.log | tail -20
  if grep -q "crashed in (null)" build/last-e2e-groups-$run.log; then
    echo "a 'crashed in (null)' failure: how HermesHQNative processes exited on $SIM (SIGTERM sent by xcodebuild = not our crash):"
    xcrun simctl spawn $SIM log show --last 15m --style compact \
      --predicate 'process == "launchd_sim" AND eventMessage CONTAINS "exited due" AND eventMessage CONTAINS "HermesHQNative"' 2>/dev/null | tail -8
  fi
  echo "e2e-groups run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
