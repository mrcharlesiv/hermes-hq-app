#!/bin/zsh
# Managed apps end-to-end UI tests (UITests/connectors/) against the connectors stand-in gateway
# (scripts/fixtures/connectors-gateway.py: a fake catalog and a fake Nous sign-in that completes).
# Usage: scripts/e2e-connectors.sh <SIM_UDID>
#   The simulator is required (this Mac is shared: there is no default). The gateway listens on 127.0.0.1:10130
#   (HQN_CONN_PORT moves it); a busy port is refused. Credentials go to build/fixtures/conn-a.json (0600, never
#   printed) and reach the runner as TEST_RUNNER_HQN_CONN_A. Screenshots land in build/shots/connectors
#   (HQN_UI_SHOTS moves them); HQN_SHOTS_DARK=1 takes the dark set. Only what this script started is stopped.
#   HQN_E2E_ONLY="testM1_BrowseAndSearch,…" runs only those tests.
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-connectors.sh <SIM_UDID>"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots/connectors}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
PORT=${HQN_CONN_PORT:-10130}
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is busy; stop it first"; exit 1; fi
PIDS=()
# The stand-in's last state is kept for reading after a failure (build/fixtures/conn-a-state.json).
trap 'curl -s -m 3 http://127.0.0.1:$PORT/__connectors > $FIX/conn-a-state.json 2>/dev/null; for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/conn-a.json
python3 scripts/fixtures/connectors-gateway.py --port $PORT --hermes-cookies --credentials $FIX/conn-a.json > $FIX/conn-a.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/conn-a.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 || { echo "the stand-in did not start (see $FIX/conn-a.log)"; exit 1; }
echo "connectors stand-in on 127.0.0.1:$PORT; pid $PIDS"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/ManagedAppsEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/ManagedAppsEndToEndTests)
STATUS=0
TEST_RUNNER_HQN_CONN_A=$PWD/$FIX/conn-a.json TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} TEST_RUNNER_HQN_DESKTOP_LOOK=${HQN_DESKTOP_LOOK:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-connectors.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-connectors.log | tail -30
echo "connectors e2e: xcodebuild exit $STATUS"
exit $STATUS
