#!/bin/zsh
# desktoplook end-to-end UI tests (UITests/desktoplook/) against the desktoplook fixture (docs/spec/3x-desktoplook.md §11).
# Usage: scripts/e2e-desktoplook.sh <SIM_UDID>          (the UDID is required: never the default simulator)
#   HQN_LOOK_PORTS="A B" moves the fixtures (default "10103 10101": 10100 is taken on this Mac by an unrelated app).
#   Refuses busy ports; credentials go to build/fixtures/desktoplook-*.json (0600, never printed) and reach the runner
#   as TEST_RUNNER_HQN_LOOK_A / _B; screenshots land in build/shots (HQN_UI_SHOTS; HQN_SHOTS_DARK=1 for dark).
#   Only the fixtures this script started are stopped. HQN_E2E_ONLY="testL1_…,testL3_…" runs only those tests.
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-desktoplook.sh <SIM_UDID>"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
read -r PA PB <<< "${HQN_LOOK_PORTS:-10103 10101}"
for port in $PA $PB; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/desktoplook-a.json $FIX/desktoplook-b.json
python3 scripts/fixtures/desktoplook-gateway.py --port $PA --hermes-cookies --credentials $FIX/desktoplook-a.json > $FIX/desktoplook-a.log 2>&1 &
PIDS+=($!)
python3 scripts/fixtures/desktoplook-gateway.py --port $PB --label Beta --credentials $FIX/desktoplook-b.json > $FIX/desktoplook-b.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/desktoplook-a.json && -s $FIX/desktoplook-b.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 || { echo "fixtures did not start (see $FIX/desktoplook-*.log)"; exit 1; }
echo "desktoplook fixtures on 127.0.0.1:$PA and :$PB (pids $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/DesktopLookEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/DesktopLookEndToEndTests)
STATUS=0
TEST_RUNNER_HQN_LOOK_A=$PWD/$FIX/desktoplook-a.json TEST_RUNNER_HQN_LOOK_B=$PWD/$FIX/desktoplook-b.json \
TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-desktoplook.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-desktoplook.log | tail -30
echo "desktoplook e2e: xcodebuild exit $STATUS"
exit $STATUS
