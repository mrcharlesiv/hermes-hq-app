#!/bin/zsh
# [terminal] Terminal page UI tests (UITests/terminal/TerminalEndToEndTests.swift) against the terminal fixture
# (scripts/fixtures/terminal-gateway.py: the push fixture plus the add-on's own terminal.py, real shells on this Mac in
# a scratch HOME).
# Usage: scripts/e2e-terminal.sh SIM_UDID
#   Starts the fixture on 127.0.0.1:${HQN_TERMINAL_PORT:-9817} (9810-9819 only; refuses a busy port), writes its invented
#   credentials to build/fixtures/e2e-terminal.json (0600, never printed), runs -only-testing:HermesHQNativeUITests/
#   TerminalEndToEndTests (HQN_TERMINAL_ONLY="test1_…,…" narrows it) and stops the fixture. HQN_TERMINAL_ADDON points at
#   another hermes-hq-push folder. Use your own simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-terminal.sh SIM_UDID}
PORT=${HQN_TERMINAL_PORT:-9817}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
if (( PORT < 9810 || PORT > 9819 )); then echo "HQN_TERMINAL_PORT must be in 9810-9819"; exit 1; fi
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is already in use"; exit 1; fi
ADDON=()
[[ -n "$HQN_TERMINAL_ADDON" ]] && ADDON=(--addon "$HQN_TERMINAL_ADDON")
rm -f $FIX/e2e-terminal.json
python3 scripts/fixtures/terminal-gateway.py --port $PORT --credentials $FIX/e2e-terminal.json $ADDON \
  > $FIX/e2e-terminal.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-terminal.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-terminal.json ]] || { echo "fixture did not start (see $FIX/e2e-terminal.log)"; exit 1; }
echo "terminal fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_TERMINAL_ONLY" ]]; then
  for t in ${(s:,:)HQN_TERMINAL_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/TerminalEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/TerminalEndToEndTests)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-terminal.json TEST_RUNNER_HQN_UI_TERMINAL=1 \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO test -quiet $ONLY \
  > build/last-e2e-terminal.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-terminal.log | tail -20
echo "terminal e2e: xcodebuild exit $STATUS"
exit $STATUS
