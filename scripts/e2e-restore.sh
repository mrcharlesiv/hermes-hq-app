#!/bin/zsh
# [restore] "Reopen the last chat on launch" end to end (UITests/restore/RestoreEndToEndTests.swift) against the restore
# fixture (scripts/fixtures/restore-gateway.py: the pages fixture plus resume/delete/remove-bot controls).
# Usage: scripts/e2e-restore.sh SIM_UDID
#   Starts the fixture on 127.0.0.1:${HQN_RESTORE_PORT:-9800} (9800-9809 only; refuses a busy port), writes its invented
#   credentials to build/fixtures/e2e-restore.json (0600, never printed), runs -only-testing:HermesHQNativeUITests/
#   RestoreEndToEndTests (HQN_RESTORE_ONLY="testR1_…,…" narrows it), and stops the fixture it started. Screens go to
#   .build/shots (HQN_SHOTS_DIR). DerivedData: ${HQN_DD:-.build/DerivedData}. Use your own simulator, never one signed
#   in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-restore.sh SIM_UDID}
PORT=${HQN_RESTORE_PORT:-9800}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/.build/shots}
DD=${HQN_DD:-.build/DerivedData}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
# HQN_ANY_PORT=1: another range (integration and ship runs use their own ports).
if [[ -z "$HQN_ANY_PORT" ]] && (( PORT < 9800 || PORT > 9809 )); then echo "HQN_RESTORE_PORT must be in 9800-9809"; exit 1; fi
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is already in use"; exit 1; fi
rm -f $FIX/e2e-restore.json
python3 scripts/fixtures/restore-gateway.py --port $PORT --credentials $FIX/e2e-restore.json --files $FIX/restore-files \
  --tick-seconds 0 > $FIX/e2e-restore.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-restore.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-restore.json ]] || { echo "fixture did not start (see $FIX/e2e-restore.log)"; exit 1; }
echo "restore fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_RESTORE_ONLY" ]]; then
  for t in ${(s:,:)HQN_RESTORE_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/RestoreEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/RestoreEndToEndTests)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-restore.json TEST_RUNNER_HQN_UI_RESTORE=1 TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD -parallel-testing-enabled NO test -quiet $ONLY \
  > build/last-e2e-restore.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-restore.log | tail -20
echo "restore e2e: xcodebuild exit $STATUS"
exit $STATUS
