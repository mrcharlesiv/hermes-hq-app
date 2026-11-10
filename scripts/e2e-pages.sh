#!/bin/zsh
# End-to-end UI tests of the Jobs, Kanban and Artifacts pages (UITests/pages/PagesTests.swift) against the stateful
# pages fixture (scripts/pages-fixture-gateway.py). A copy of scripts/e2e.sh for that fixture.
# Usage: scripts/e2e-pages.sh [SIM_UDID]
#   Starts the fixture on 127.0.0.1:${HQN_PAGES_PORT:-9735} (refuses a busy port), writes its invented credentials to
#   build/fixtures/e2e-pages.json (0600, never printed), passes that path as TEST_RUNNER_HQN_UI_CREDENTIALS, runs
#   -only-testing:HermesHQNativeUITests/PagesTests (HQN_PAGES_ONLY="testKB2_SwipeUnblock,…" narrows it), then the
#   --no-kanban variant (PagesNoKanbanTests) against a second fixture on ${HQN_PAGES_NOK_PORT:-9737} unless
#   HQN_PAGES_SKIP_NOK=1, and stops every fixture it started. Screens are written to .build/shots/ (HQN_SHOTS_DIR).
#   Use a clone of the "HQ Native" simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A}}
PORT=${HQN_PAGES_PORT:-9735}
NOK_PORT=${HQN_PAGES_NOK_PORT:-9737}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/.build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

start_fixture() {   # port credentials files-dir extra-flags… → sets FIXTURE_PID
  local port=$1 creds=$2 files=$3; shift 3
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "port $port is already in use; set HQN_PAGES_PORT / HQN_PAGES_NOK_PORT to a free port in 9735-9737"; exit 1
  fi
  rm -f $creds
  python3 scripts/pages-fixture-gateway.py --port $port --credentials $creds --files $files --tick-seconds 0 "$@" > $creds.log 2>&1 &
  FIXTURE_PID=$!
  for i in {1..50}; do
    [[ -s $creds ]] && lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1 && break
    sleep 0.2
  done
  [[ -s $creds ]] || { echo "fixture did not start (see $creds.log)"; exit 1; }
}

PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
start_fixture $PORT $FIX/e2e-pages.json $FIX/pages-files
PIDS+=($FIXTURE_PID)
echo "pages fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_PAGES_ONLY" ]]; then
  for t in ${(s:,:)HQN_PAGES_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/PagesTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/PagesTests)
fi
FAILED=0
# HQN_URL_SCHEME: the build's own link scheme (project.yml HQ_URL_SCHEME_*), so a link a test opens reaches this app,
# not another identity's copy on the same simulator.
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-pages.json TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_URL_SCHEME=${HQ_ORIGINAL:+hermes} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
  > build/last-e2e-pages.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-pages.log | tail -20
echo "pages e2e: xcodebuild exit $STATUS"
[[ $STATUS -eq 0 ]] || FAILED=1

if [[ "$HQN_PAGES_SKIP_NOK" != "1" && -z "$HQN_PAGES_ONLY" ]]; then
  start_fixture $NOK_PORT $FIX/e2e-pages-nok.json $FIX/pages-files-nok --no-kanban
  PIDS+=($FIXTURE_PID)
  echo "no-kanban fixture on 127.0.0.1:$NOK_PORT (pid $FIXTURE_PID)"
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-pages-nok.json TEST_RUNNER_HQN_UI_NO_KANBAN=1 \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet \
    -only-testing:HermesHQNativeUITests/PagesNoKanbanTests > build/last-e2e-pages-nok.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-pages-nok.log | tail -20
  echo "no-kanban e2e: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
fi
exit $FAILED
