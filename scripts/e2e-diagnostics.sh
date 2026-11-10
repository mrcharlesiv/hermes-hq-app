#!/bin/zsh
# Diagnostics-stream end-to-end UI tests (UITests/diagnostics/) against scripts/fixtures/diagnostics-gateway.py: the
# settings fixture with the performance-log routes answered by the real sink code, writing to build/fixtures/hq-logs.
# Usage: scripts/e2e-diagnostics.sh <SIM_UDID>
#   HQN_DIAGNOSTICS_PORT (default 10070) moves the fixture; HQN_E2E_ONLY="testD1_…,testD3_…" runs only those tests
#   (default: every testD… of the stream plus the settings suite's Diagnostics test, testG9). Refuses a busy port and
#   stops only the fixture it started. Screenshots land in .build/shots.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID}
PORT=${HQN_DIAGNOSTICS_PORT:-10070}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is busy; stop it first"; exit 1; fi
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -rf $FIX/diagnostics.json $FIX/hq-logs
python3 scripts/fixtures/diagnostics-gateway.py --port $PORT --hermes-cookies --credentials $FIX/diagnostics.json \
  --log-dir $FIX/hq-logs > $FIX/diagnostics.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/diagnostics.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || { echo "the fixture did not start (see $FIX/diagnostics.log)"; exit 1; }
echo "diagnostics fixture on 127.0.0.1:$PORT (pid $PIDS), sink folder $FIX/hq-logs"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
TESTS=(${(s:,:)HQN_E2E_ONLY})
if (( ${#TESTS} == 0 )); then
  TESTS=($(grep -h -o -E 'func testD[0-9A-Za-z_]+' UITests/diagnostics/*.swift | awk '{print $2}') testG9_ResumeSessionsDiagnosticsAndJankyMark)
fi
ONLY=()
for t in $TESTS; do ONLY+=(-only-testing:HermesHQNativeUITests/SettingsEndToEndTests/$t); done
STATUS=0
TEST_RUNNER_HQN_SETTINGS_A=$PWD/$FIX/diagnostics.json TEST_RUNNER_HQN_SETTINGS_B=$PWD/$FIX/diagnostics.json \
TEST_RUNNER_HQN_SETTINGS_CONFIG=B TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-diagnostics.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-diagnostics.log | tail -30
echo "sink folder:"; find $FIX/hq-logs -type f | head -10
echo "diagnostics e2e: xcodebuild exit $STATUS"
exit $STATUS
