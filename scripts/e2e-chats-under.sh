#!/bin/zsh
# [chats-under] Chats under each bot on the Bots page, end to end (UITests/botslist/ChatsUnderBotsTests.swift), against
# the Sessions fixture's everyday list on 127.0.0.1:${HQN_CHATS_PORT:-9871}. Usage: scripts/e2e-chats-under.sh <SIM_UDID>
#   HQN_SHOTS_DARK=1 takes the pictures in dark mode; they land in build/shots/chats-under. HQN_E2E_ONLY=<test> runs one.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?pass your own simulator UDID}
PORT=${HQN_CHATS_PORT:-9871}
FIX=build/fixtures; SHOTS=$PWD/build/shots/chats-under
mkdir -p $FIX $SHOTS && chmod 700 $FIX
[[ -z $DEVELOPER_DIR && -d /Applications/Xcode-27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer
PID=
if ! lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  rm -f $FIX/chats.json
  python3 scripts/fixtures/sessions-gateway.py --port $PORT --seed everyday --credentials $FIX/chats.json > $FIX/chats.log 2>&1 &
  PID=$!
  trap '[[ -n $PID ]] && kill $PID 2>/dev/null || true' EXIT INT TERM
  for i in {1..50}; do [[ -s $FIX/chats.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
else
  curl -s -X POST http://127.0.0.1:$PORT/__fixture/reset >/dev/null || true
fi
xcodegen generate -q
TEST_RUNNER_HQN_CHATS_UNDER=1 TEST_RUNNER_HQN_CHATS_CRED=$PWD/$FIX/chats.json TEST_RUNNER_HQN_SHOTS=$SHOTS \
TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} \
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} test -only-testing:HermesHQNativeUITests/ChatsUnderBotsTests${HQN_E2E_ONLY:+/$HQN_E2E_ONLY} -quiet \
  > build/last-chats-under.log 2>&1 && STATUS=0 || STATUS=$?
grep -E "error:|failed|passed|XCTAssert|Executed" build/last-chats-under.log | tail -30
echo "chats-under exit $STATUS (pictures in $SHOTS)"; exit $STATUS
