#!/bin/zsh
# End-to-end UI tests of the Sessions tab's row actions and search (UITests/sessions/SessionsTests.swift) against the
# sessions fixture (scripts/fixtures/sessions-gateway.py).
# Usage: scripts/e2e-sessions.sh [SIM_UDID] [PORT]
#   Starts the fixture on 127.0.0.1:PORT (the second argument, else ${HQN_SESSIONS_PORT:-9820}; refuses a busy port;
#   HQN_SESSIONS_SEED=big starts it with 2,000 chats over 12 bots for the load tests; HQN_SESSIONS_DARK=1 runs the app
#   dark and names the screenshots "…-dark.png"; HQN_SESSIONS_DROPS=50 sets how many socket drops the reconnect stress
#   test makes, default 12; HQN_SESSIONS_UNFENCED=1 answers session edits as Hermes 0.22.2, without the revision
#   fence), writes its invented credentials to
#   build/fixtures/e2e-sessions.json (0600, never printed), passes that path as TEST_RUNNER_HQN_UI_CREDENTIALS and the
#   screenshot folder as TEST_RUNNER_HQN_SHOTS_DIR (default .build/shots), runs
#   -only-testing:HermesHQNativeUITests/SessionsTests (HQN_SESSIONS_ONLY="testSwipes,…" narrows it) with derived data
#   in ${HQN_DD:-.build/DerivedData}, and stops the fixture it started.
#   Use this stream's own simulator (HQN-sessions 053BFB07-4BC1-40C3-8FC4-74BD48EC66A0).
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-053BFB07-4BC1-40C3-8FC4-74BD48EC66A0}}
PORT=${2:-${HQN_SESSIONS_PORT:-9820}}
SEED=${HQN_SESSIONS_SEED:-default}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/.build/shots}
DD=${HQN_DD:-.build/DerivedData}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; pass a free port of your own as the second argument"; exit 1
fi
CREDS=$FIX/e2e-sessions.json
rm -f $CREDS
python3 scripts/fixtures/sessions-gateway.py --port $PORT --seed $SEED ${HQN_SESSIONS_UNFENCED:+--unfenced} --credentials $CREDS > $CREDS.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $CREDS ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $CREDS ]] || { echo "fixture did not start (see $CREDS.log)"; exit 1; }
echo "sessions fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
# A test may take this long; the 2,000-chat seed makes every XCUITest query slower (6 minutes seen for one test on a
# busy Mac), and fifty socket drops take their time too.
# The Mac is shared (load averages in the hundreds have been seen, each accessibility query then taking 3-7 s), so the
# allowance is generous: it only stops a test that hangs, it is not a measure of the app.
ALLOWANCE=${HQN_SESSIONS_ALLOWANCE:-900}; [[ $SEED == big || ${HQN_SESSIONS_DROPS:-0} -gt 20 ]] && ALLOWANCE=${HQN_SESSIONS_ALLOWANCE:-1500}
ONLY=()
if [[ -n "$HQN_SESSIONS_ONLY" ]]; then
  for t in ${(s:,:)HQN_SESSIONS_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/SessionsTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/SessionsTests)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$CREDS TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_SESSIONS_SEED=$SEED \
  TEST_RUNNER_HQN_SESSIONS_DARK=${HQN_SESSIONS_DARK:-0} TEST_RUNNER_HQN_SESSIONS_DROPS=${HQN_SESSIONS_DROPS:-} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD test -test-timeouts-enabled YES \
  -collect-test-diagnostics never \
  -default-test-execution-time-allowance $ALLOWANCE -maximum-test-execution-time-allowance $ALLOWANCE $ONLY > build/last-e2e-sessions.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-sessions.log | tail -20
FENCE=$(curl -s -m 5 http://127.0.0.1:$PORT/__fixture/stats | python3 -c "import json,sys; f=json.load(sys.stdin)['fence']; print('on=%s accepted=%s refused=%s' % (f['on'], f['accepted'], f['refused']))" 2>&1)
echo "session edits (revision fence): $FENCE"
echo "sessions e2e: xcodebuild exit $STATUS"
exit $STATUS
