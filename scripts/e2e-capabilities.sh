#!/bin/zsh
# Capabilities-stream end-to-end UI tests (UITests/capabilities/) against the capabilities stand-in gateway and the
# Composio stand-in (docs/spec/3x-capabilities.md §12, §13).
# Usage: scripts/e2e-capabilities.sh <SIM_UDID> [CONFIG]
#   CONFIG A (default): gateway on 127.0.0.1:10010, Composio stand-in on 10012.
#   CONFIG S: the same with --latency 400 and --slow-activate 3 on the Composio stand-in (slow answers).
#   The simulator is required (this Mac is shared: there is no default). Busy ports are refused. Credentials go to
#   build/fixtures/cap-a.json (0600, never printed) and reach the runner as TEST_RUNNER_HQN_CAP_A; screenshots land in
#   build/shots (HQN_UI_SHOTS moves them; HQN_SHOTS_DARK=1 takes the dark set, HQN_UI_DESKTOPLOOK=1 the Desktop Look set). Only what this script started is stopped.
#   HQN_TEXT_SIZE=UICTContentSizeCategoryAccessibilityL runs at a larger text size; HQN_CAP_NO_LOGO="gmail,slack"
#   makes those apps' logos fail.
#   HQN_E2E_ONLY="testC1_…,testC9_…" runs only those tests. HQN_CAP_PORTS="GW COMPOSIO" moves the ports.
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-capabilities.sh <SIM_UDID> [CONFIG]"; exit 2; }
CONFIG=${2:-A}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
read -r PA PC <<< "${HQN_CAP_PORTS:-10010 10012}"
for port in $PA $PC; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first"; exit 1; fi
done
PIDS=()
# The stand-ins' last state is kept for reading after a failure (build/fixtures/cap-a-state.json, composio-state.json).
trap 'curl -s -m 3 http://127.0.0.1:$PA/__state > $FIX/cap-a-state.json 2>/dev/null; curl -s -m 3 http://127.0.0.1:$PC/__state > $FIX/composio-state.json 2>/dev/null; for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/cap-a.json
python3 scripts/fixtures/capabilities-gateway.py --port $PA --hermes-cookies --credentials $FIX/cap-a.json > $FIX/cap-a.log 2>&1 &
PIDS+=($!)
EXTRA=()
[[ $CONFIG == S ]] && EXTRA=(--latency 400 --slow-activate 3)
[[ -n "$HQN_CAP_NO_LOGO" ]] && EXTRA+=(--no-logo $HQN_CAP_NO_LOGO)   # these apps' logos answer 404 (the letter tile shows)
python3 scripts/fixtures/composio-mock.py --port $PC $EXTRA > $FIX/composio.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/cap-a.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$PC -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PC -sTCP:LISTEN >/dev/null 2>&1 || { echo "stand-ins did not start (see $FIX/cap-a.log, $FIX/composio.log)"; exit 1; }
echo "capabilities stand-ins on 127.0.0.1:$PA (gateway) and :$PC (Composio); config $CONFIG; pids $PIDS"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/CapabilitiesEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/CapabilitiesEndToEndTests)
STATUS=0
TEST_RUNNER_HQN_CAP_A=$PWD/$FIX/cap-a.json TEST_RUNNER_HQN_CAP_COMPOSIO=http://127.0.0.1:$PC \
TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} TEST_RUNNER_HQN_TEXT_SIZE=${HQN_TEXT_SIZE:-} \
TEST_RUNNER_HQN_UI_DESKTOPLOOK=${HQN_UI_DESKTOPLOOK:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-capabilities.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-capabilities.log | tail -30
echo "capabilities e2e: xcodebuild exit $STATUS"
exit $STATUS
