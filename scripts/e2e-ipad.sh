#!/bin/zsh
# [m9/ipad] End-to-end UI tests of the iPad two-pane layout and the hardware keyboard (UITests/ipad) against stand-in
# gateways. Usage: scripts/e2e-ipad.sh <PAD_UDID> [PHONE_UDID]
#   Starts the performance fixture on 127.0.0.1:${HQN_IPAD_PORT:-10110}, the sessions fixture on the next port and
#   the pages fixture on the one after
#   (both refuse a busy port), writes their invented credentials to build/fixtures/e2e-ipad-<port>-*.json (0600, never
#   printed), and runs IPadLayoutTests + KeyboardShortcutTests on the iPad simulator, then KeyboardShortcutTests on
#   the phone simulator when one is given. Screenshots: ${HQN_SHOTS_DIR:-build/shots/e2e}. Derived data: ${HQN_DD:-build/dd}.
#   HQN_IPAD_ONLY="IPadLayoutTests/test1_…,KeyboardShortcutTests" narrows the run. HQN_IPAD_DARK=1 runs in dark.
#   Stops the fixtures it started. Use this stream's own simulators (never the default one).
set -e
cd "$(dirname "$0")/.."
PAD=${1:?usage: scripts/e2e-ipad.sh <PAD_UDID> [PHONE_UDID]}
PHONE=$2
PORT=${HQN_IPAD_PORT:-10110}
PORT2=$((PORT + 1))
PORT3=$((PORT + 2))
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots/e2e}
[[ $SHOTS == /* ]] || SHOTS=$PWD/$SHOTS   # the test runner needs an absolute path
DD=${HQN_DD:-build/dd}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
for p in $PORT $PORT2 $PORT3; do
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use; set HQN_IPAD_PORT"; exit 1; fi
done
# Keyed by port: two runs in this worktree at once (builder and stress tester) used to share these files, so each
# run's app signed in to whichever gateway wrote last and the request counts of the two runs mixed (seen in the
# repair after stress round 1: "one session.create" failed in both runs at the same minute).
PERF=$FIX/e2e-ipad-$PORT-perf.json; SESS=$FIX/e2e-ipad-$PORT-sessions.json; PAGES=$FIX/e2e-ipad-$PORT-pages.json
LOGTAG=$([[ $PORT == 10110 ]] && echo "" || echo "-$PORT")
rm -f $PERF $SESS $PAGES
HQN_REF=$REF python3 scripts/fixtures/ipad-perf-gateway.py --port $PORT --credentials $PERF > $PERF.log 2>&1 &
PID1=$!
python3 scripts/fixtures/sessions-gateway.py --port $PORT2 --credentials $SESS > $SESS.log 2>&1 &
PID2=$!
python3 scripts/pages-fixture-gateway.py --port $PORT3 --credentials $PAGES --files $FIX/ipad-pages-files-$PORT --tick-seconds 0 > $PAGES.log 2>&1 &
PID3=$!
trap 'kill $PID1 $PID2 $PID3 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do [[ -s $PERF && -s $SESS && -s $PAGES ]] && break; sleep 0.2; done
[[ -s $PERF && -s $SESS && -s $PAGES ]] || { echo "a fixture did not start (see $FIX/e2e-ipad-$PORT-*.log)"; exit 1; }
echo "fixtures on 127.0.0.1:$PORT (performance, pid $PID1), :$PORT2 (sessions, pid $PID2) and :$PORT3 (pages, pid $PID3)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
FAILED=0
run() {   # run <udid> <label> <suites…>
  local sim=$1 label=$2; shift 2
  local only=()
  if [[ -n "$HQN_IPAD_ONLY" ]]; then
    for t in ${(s:,:)HQN_IPAD_ONLY}; do only+=(-only-testing:HermesHQNativeUITests/$t); done
  else
    for t in $@; do only+=(-only-testing:HermesHQNativeUITests/$t); done
  fi
  xcrun simctl bootstatus $sim -b >/dev/null 2>&1 || true
  xcrun simctl ui $sim appearance ${${HQN_IPAD_DARK:+dark}:-light} >/dev/null 2>&1 || true
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$PERF TEST_RUNNER_HQN_UI_SESSIONS_CREDENTIALS=$PWD/$SESS TEST_RUNNER_HQN_UI_PAGES_CREDENTIALS=$PWD/$PAGES TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS/$label \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$sim" -derivedDataPath $DD test -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 ${HQN_IPAD_ITERATIONS:+-test-iterations} ${HQN_IPAD_ITERATIONS:+$HQN_IPAD_ITERATIONS} $only > build/last-e2e-ipad-$label$LOGTAG.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-ipad-$label$LOGTAG.log | tail -20
  echo "ipad e2e ($label): xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
}
run $PAD pad IPadLayoutTests IPadAuditTests KeyboardShortcutTests
[[ -z "$PHONE" ]] || run $PHONE phone KeyboardShortcutTests
exit $FAILED
