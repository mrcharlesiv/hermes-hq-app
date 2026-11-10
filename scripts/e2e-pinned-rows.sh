#!/bin/zsh
# [pinned-rows] Filter › Pinned Bots › Rows end to end (UITests/botslist/PinnedRowsTests.swift), against
# the Sessions fixture's demo list on 127.0.0.1:${HQN_PINNED_PORT:-9873}. Usage: scripts/e2e-pinned-rows.sh <SIM_UDID>
#   Use an erased simulator (each run starts a fresh fixture with new credentials). HQN_SHOTS_DARK=1 takes the
#   pictures in dark mode; they land in build/shots/pinned-rows.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?pass your own simulator UDID}
PORT=${HQN_PINNED_PORT:-9873}
FIX=build/fixtures; SHOTS=$PWD/build/shots/pinned-rows
mkdir -p $FIX $SHOTS && chmod 700 $FIX
[[ -z $DEVELOPER_DIR && -d /Applications/Xcode-27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer
PID=
if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  rm -f $FIX/pinned.json
  python3 scripts/fixtures/sessions-gateway.py --port $PORT --seed demo --credentials $FIX/pinned.json > $FIX/pinned.log 2>&1 &
  PID=$!
  trap '[[ -n $PID ]] && kill $PID 2>/dev/null || true' EXIT INT TERM
  for i in {1..50}; do [[ -s $FIX/pinned.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
else
  curl -s -X POST http://127.0.0.1:$PORT/__fixture/reset >/dev/null || true
fi
xcodegen generate -q
TEST_RUNNER_HQN_PINNED_ROWS=1 TEST_RUNNER_HQN_PINNED_CRED=$PWD/$FIX/pinned.json TEST_RUNNER_HQN_SHOTS=$SHOTS \
TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} \
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} test -only-testing:HermesHQNativeUITests/PinnedRowsTests -quiet \
  > build/last-pinned-rows.log 2>&1 && STATUS=0 || STATUS=$?
grep -E "error:|failed|passed|XCTAssert|Executed" build/last-pinned-rows.log | tail -30
echo "pinned-rows exit $STATUS (pictures in $SHOTS)"; exit $STATUS
