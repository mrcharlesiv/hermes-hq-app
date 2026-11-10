#!/bin/zsh
# Notifications end-to-end UI tests (UITests/push/PushEndToEndTests.swift) against the push fixture
# (scripts/fixtures/push-gateway.py: a stand-in hermes-hq-push plugin; deliveries go through `xcrun simctl push`).
# Usage: scripts/e2e-push.sh SIM_UDID
#   Starts the fixture on 127.0.0.1:${HQN_PUSH_PORT:-9810} (9810-9819 only; refuses a busy port), writes its invented
#   credentials to build/fixtures/e2e-push.json (0600, never printed), runs -only-testing:HermesHQNativeUITests/
#   PushEndToEndTests (HQN_PUSH_ONLY="test1_…,…" narrows it) and stops the fixture. HQ_IDENTITY=original tests the
#   original record's build. Use your own simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-push.sh SIM_UDID}
PORT=${HQN_PUSH_PORT:-9810}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
# HQN_ANY_PORT=1: another range (integration and ship runs use their own ports).
if [[ -z "$HQN_ANY_PORT" ]] && (( PORT < 9810 || PORT > 9819 )); then echo "HQN_PUSH_PORT must be in 9810-9819"; exit 1; fi
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is already in use"; exit 1; fi
[[ ${HQ_IDENTITY:-native} == original ]] && { export HQ_ORIGINAL=YES; BUNDLE=com.charlesmcdowell.dispatch; } \
  || { unset HQ_ORIGINAL; BUNDLE=com.charlesmcdowell.hermeshq.native; }
rm -f $FIX/e2e-push.json
python3 scripts/fixtures/push-gateway.py --port $PORT --credentials $FIX/e2e-push.json --sim $SIM --bundle $BUNDLE \
  > $FIX/e2e-push.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-push.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-push.json ]] || { echo "fixture did not start (see $FIX/e2e-push.log)"; exit 1; }
echo "push fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID), app $BUNDLE"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_PUSH_ONLY" ]]; then
  for t in ${(s:,:)HQN_PUSH_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/PushEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/PushEndToEndTests)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-push.json TEST_RUNNER_HQN_UI_PUSH=1 \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO test -quiet $ONLY \
  > build/last-e2e-push.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-push.log | tail -20
echo "push e2e: xcodebuild exit $STATUS"
exit $STATUS
