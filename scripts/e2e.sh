#!/bin/zsh
# End-to-end UI tests (UITests/EndToEndTests.swift) against the performance fixture from the reference web repo.
# Usage: scripts/e2e.sh [SIM_UDID] [RUNS]
#   Starts performance-fixture-gateway.py on 127.0.0.1:$HQN_E2E_PORT (default 9712; refuses a busy port), writes its
#   invented credentials to build/fixtures/e2e-perf.json (0600, never printed), passes that path to the test runner as
#   TEST_RUNNER_HQN_UI_CREDENTIALS, runs the HermesHQNativeUI scheme RUNS times (default 1), and stops the fixture it
#   started. Logs: build/last-e2e-<run>.log and build/fixtures/e2e-perf.log.
# HQN_E2E_FIXTURE=questions: starts scripts/fixtures/questions-gateway.py instead (stream "questions", spec 1x §6) and runs
#   UITests/questions (QuestionsEndToEndTests), e.g. HQN_E2E_FIXTURE=questions HQN_E2E_PORT=9721 scripts/e2e.sh <udid>.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A}}
RUNS=${2:-1}
PORT=${HQN_E2E_PORT:-9712}
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
KIND=${HQN_E2E_FIXTURE:-perf}
SCRIPT=$REF/scripts/performance-fixture-gateway.py
SUITE=EndToEndTests
if [[ $KIND == questions ]]; then
  SCRIPT=scripts/fixtures/questions-gateway.py
  SUITE=QuestionsEndToEndTests
  export TEST_RUNNER_HQN_UI_QUESTIONS=1
elif [[ $KIND == */* || $KIND == *.py ]]; then
  # [activity] HQN_E2E_FIXTURE=<script path>: another fixture script for the M1 suite.
  SCRIPT=$KIND
  KIND=custom
fi

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_E2E_PORT to a free port"; exit 1
fi
rm -f $FIX/e2e-$KIND.json
python3 $SCRIPT --port $PORT --credentials $FIX/e2e-$KIND.json > $FIX/e2e-$KIND.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-$KIND.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-$KIND.json ]] || { echo "fixture did not start (see $FIX/e2e-$KIND.log)"; exit 1; }
echo "$KIND fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
# HQN_E2E_ONLY="test6_…,test7_…": run only those tests (EndToEndTests).
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/$SUITE/$t); done
# Integration: the UI target holds every stream's suite; run only this script's suite unless told otherwise.
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/$SUITE)
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-$KIND.json \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
    > build/last-e2e-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-$run.log | tail -20
  echo "e2e run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
