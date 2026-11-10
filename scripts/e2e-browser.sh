#!/bin/zsh
# Watch Browser end-to-end UI tests (UITests/browser/BrowserEndToEndTests.swift) against the browser fixture
# (scripts/fixtures/browser-gateway.py: a stand-in hermes-hq-browser plugin with a fake sign-in page). A copy of
# scripts/e2e.sh for that fixture.
# Usage: scripts/e2e-browser.sh [SIM_UDID]
#   Makes the fixture's frames once (scripts/fixtures/make-browser-frames.swift → build/fixtures/browser-frames),
#   starts the fixture on 127.0.0.1:${HQN_BROWSER_PORT:-9800} (refuses a busy port), writes its invented credentials to
#   build/fixtures/e2e-browser.json (0600, never printed), runs -only-testing:HermesHQNativeUITests/BrowserEndToEndTests
#   (HQN_BROWSER_ONLY="test1_…,…" narrows it) and stops the fixture. Use your own simulator, never one signed in to a
#   real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-00CC6911-5CB1-458A-AEAE-DE5A5CB4F81A}}
PORT=${HQN_BROWSER_PORT:-9800}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
[[ -s $FIX/browser-frames/frame-29.jpg ]] || swift scripts/fixtures/make-browser-frames.swift $FIX/browser-frames
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_BROWSER_PORT to a free port in 9800-9809"; exit 1
fi
rm -f $FIX/e2e-browser.json
python3 scripts/fixtures/browser-gateway.py --port $PORT --credentials $FIX/e2e-browser.json --frames $FIX/browser-frames \
  > $FIX/e2e-browser.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-browser.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-browser.json ]] || { echo "fixture did not start (see $FIX/e2e-browser.log)"; exit 1; }
echo "browser fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_BROWSER_ONLY" ]]; then
  for t in ${(s:,:)HQN_BROWSER_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/BrowserEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/BrowserEndToEndTests)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-browser.json TEST_RUNNER_HQN_UI_BROWSER=1 \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
  > build/last-e2e-browser.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-browser.log | tail -20
echo "browser e2e: xcodebuild exit $STATUS"
exit $STATUS
