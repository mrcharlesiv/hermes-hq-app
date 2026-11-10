#!/bin/zsh
# End-to-end UI tests of the m9 transcript stream (UITests/transcript/) against its stand-in gateway
# (scripts/fixtures/transcript-gateway.py; docs/spec/3x-transcript.md §0.1).
# Usage: scripts/e2e-transcript.sh SIM_UDID PORT          (builder: ports 10020-10024; stress: 10025-10029)
#   Refuses a busy port, starts the fixture on 127.0.0.1:PORT with invented credentials in build/fixtures (0600),
#   runs TranscriptEndToEndTests in light and then dark appearance (HQN_TRANSCRIPT_APPEARANCES="light" for one),
#   writes screenshots to build/shots/transcript-<name>-<appearance>.png and stops only the fixture it started.
#   HQN_TRANSCRIPT_ONLY="testT1_CronDeliveries,…" runs only those tests. HQN_DD: derived data (default build/dd).
set -e
cd "$(dirname "$0")/.."
SIM=$1; PORT=$2
[[ -n "$SIM" && -n "$PORT" ]] || { echo "usage: scripts/e2e-transcript.sh SIM_UDID PORT"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
DD=${HQN_DD:-build/dd}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is already in use"; exit 1; fi
rm -f $FIX/transcript.json
python3 scripts/fixtures/transcript-gateway.py --port $PORT --credentials $FIX/transcript.json > $FIX/transcript.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true; xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/transcript.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/transcript.json ]] || { echo "fixture did not start (see $FIX/transcript.log)"; exit 1; }
echo "transcript fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"
[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_TRANSCRIPT_ONLY" ]]; then
  for t in ${(s:,:)HQN_TRANSCRIPT_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/TranscriptEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/TranscriptEndToEndTests)
fi
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1 || true
FAILED=0
for appearance in ${=HQN_TRANSCRIPT_APPEARANCES:-light dark}; do
  xcrun simctl ui $SIM appearance $appearance >/dev/null 2>&1 || true
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/transcript.json TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS TEST_RUNNER_HQN_SHOTS_SUFFIX=$appearance \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD test -quiet $ONLY \
    > build/last-e2e-transcript-$appearance.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-transcript-$appearance.log | tail -20
  echo "e2e-transcript ($appearance): xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
