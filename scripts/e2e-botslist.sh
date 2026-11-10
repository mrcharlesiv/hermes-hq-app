#!/bin/zsh
# Bots-list stream end-to-end UI tests (UITests/botslist/, docs/spec/3x-botslist.md) against the Bots-list fixture
# (scripts/fixtures/botslist-gateway.py: the settings fixture plus "fail:" turns) on 127.0.0.1:10040, and a second
# settings fixture labelled Beta on 10041. The tests are an extension of SettingsEndToEndTests (same sign-in and helpers).
# Usage: scripts/e2e-botslist.sh <SIM_UDID>      HQN_E2E_ONLY="testL05_…,testL16_…" runs only those tests.
#   HQN_SETTINGS_PORTS="A B C" moves the fixtures; HQN_DD picks the derived data. Only the fixtures this script started
#   are stopped; credentials go to build/fixtures/settings-*.json (0600, never printed).
set -e
cd "$(dirname "$0")/.."
SIM=${1:?pass your own simulator UDID}
CONFIG=${2:-B}
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

# HQN_SETTINGS_PORTS="A B NOUS-PORTAL" moves the fixtures (integration runs every suite on its own ports).
read -r PA PB PC <<< "${HQN_SETTINGS_PORTS:-10040 10041 10042}"
for port in $PA $PB $PC; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/settings-a.json $FIX/settings-b.json
python3 scripts/fixtures/botslist-gateway.py --port $PA --hermes-cookies --credentials $FIX/settings-a.json > $FIX/settings-a.log 2>&1 &
PIDS+=($!)
if [[ $CONFIG == C ]]; then
  python3 $REF/scripts/nous-fixture-gateway.py --port $PB --portal-port $PC --public-url http://127.0.0.1:$PB --access-ttl 30 \
    > $FIX/settings-nous.log 2>&1 &
  PIDS+=($!)
  print -r -- "{\"url\":\"http://127.0.0.1:$PB\",\"nous\":true}" > $FIX/settings-b.json
else
  python3 scripts/fixtures/settings-gateway.py --port $PB --label Beta --credentials $FIX/settings-b.json > $FIX/settings-b.log 2>&1 &
  PIDS+=($!)
fi
for i in {1..60}; do
  [[ -s $FIX/settings-a.json && -s $FIX/settings-b.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 || { echo "fixtures did not start (see $FIX/settings-*.log)"; exit 1; }
echo "settings fixtures on 127.0.0.1:$PA and :$PB (config $CONFIG; pids $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/SettingsEndToEndTests/$t); done
if [[ ${#ONLY} -eq 0 ]]; then
  for t in $(grep -oE 'func testL[0-9]+_[A-Za-z0-9]+' UITests/botslist/*.swift | sed 's/.*func //'); do
    ONLY+=(-only-testing:HermesHQNativeUITests/SettingsEndToEndTests/$t)
  done
fi
STATUS=0
TEST_RUNNER_HQN_SETTINGS_A=$PWD/$FIX/settings-a.json TEST_RUNNER_HQN_SETTINGS_B=$PWD/$FIX/settings-b.json \
TEST_RUNNER_HQN_SETTINGS_CONFIG=$CONFIG TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_BOTSLIST=1 TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-botslist.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-botslist.log | tail -30
echo "botslist e2e: xcodebuild exit $STATUS"
exit $STATUS
