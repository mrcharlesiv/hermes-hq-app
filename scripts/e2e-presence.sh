#!/bin/zsh
# Presence end-to-end UI tests (UITests/presence/PresenceEndToEndTests.swift) against the presence fixture
# (scripts/fixtures/presence-gateway.py: the Watch Browser fixture plus per-bot plugin rows, profiles.configure with
# Hermes' compare-and-swap, and an outage switch). A copy of scripts/e2e-browser.sh for that fixture.
# Usage: scripts/e2e-presence.sh <SIM_UDID>
#   The simulator is required: this never falls back to a default one. Makes the fixture's frames once
#   (scripts/fixtures/make-browser-frames.swift → build/fixtures/browser-frames), starts the fixture on
#   127.0.0.1:${HQN_PRESENCE_PORT:-9930} (refuses a busy port), writes its invented credentials to
#   build/fixtures/e2e-presence.json (0600, never printed), runs
#   -only-testing:HermesHQNativeUITests/PresenceEndToEndTests (HQN_PRESENCE_ONLY="test1_…,…" narrows it;
#   HQN_PRESENCE_CLASS names another class in UITests/presence, e.g. PresenceStressTests; HQN_PRESENCE_BOTS=N adds N
#   bots; HQN_PRESENCE_LONG=1 runs the stress tests' outage and flap loops at the plan's full length) and stops the
#   fixture. Screenshots are written to ${HQN_PRESENCE_SHOTS:-build/shots} as <name>-light.png; HQN_PRESENCE_DARK=1
#   runs everything in dark appearance and writes <name>-dark.png (the tests set the appearance before each launch and
#   put it back to light). HQN_DD (default build/dd, inside the worktree) and HQN_SKIP_XCODEGEN are honoured.
#   Use your own simulator, never one signed in to a real gateway.
set -e
cd "$(dirname "$0")/.."
SIM=$1
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-presence.sh <SIM_UDID>   (your own simulator; there is no default)"; exit 2; }
PORT=${HQN_PRESENCE_PORT:-9930}
CLASS=${HQN_PRESENCE_CLASS:-PresenceEndToEndTests}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
[[ -s $FIX/browser-frames/frame-29.jpg ]] || swift scripts/fixtures/make-browser-frames.swift $FIX/browser-frames
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_PRESENCE_PORT to a free port in 9930-9934"; exit 1
fi
rm -f $FIX/e2e-presence.json
python3 scripts/fixtures/presence-gateway.py --port $PORT --credentials $FIX/e2e-presence.json --frames $FIX/browser-frames \
  --bots ${HQN_PRESENCE_BOTS:-0} > $FIX/e2e-presence.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/e2e-presence.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/e2e-presence.json ]] || { echo "fixture did not start (see $FIX/e2e-presence.log)"; exit 1; }
echo "presence fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_PRESENCE_ONLY" ]]; then
  for t in ${(s:,:)HQN_PRESENCE_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/$CLASS/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/$CLASS)
fi
TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/e2e-presence.json TEST_RUNNER_HQN_UI_PRESENCE=1 \
  TEST_RUNNER_HQN_UI_SHOTS=${HQN_PRESENCE_SHOTS:-$PWD/build/shots} TEST_RUNNER_HQN_UI_DARK=${HQN_PRESENCE_DARK:-0} \
  TEST_RUNNER_HQN_UI_LONG=${HQN_PRESENCE_LONG:-0} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
  > build/last-e2e-presence.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-presence.log | tail -20
echo "presence e2e: xcodebuild exit $STATUS"
exit $STATUS
