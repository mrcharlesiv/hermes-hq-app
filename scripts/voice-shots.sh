#!/bin/zsh
# Screenshots of every voice memo state, light and dark (docs/spec/1x-voice.md), into .build/shots/<mode>-<name>.png.
# Usage: scripts/voice-shots.sh [SIM_UDID]   — needs the dev voice fixture running on 127.0.0.1:9726 (credentials
# build/fixtures/voice-dev.json) with seeded memo history, and the app installed on the simulator. The recorder states
# are driven by the DEBUG hooks -HQDebugMemoShot / -HQDebugMemoShotNotice / -HQDebugMemoShotTip (App/Debug/VoiceDebugHooks.swift).
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-1BE77711-F7EF-4BE6-AE1B-2D4DE84525D2}}
PORT=9726
BUNDLE=com.charlesmcdowell.hermeshq.native
OUT=.build/shots
mkdir -p $OUT
CREDS=build/fixtures/voice-dev.json
[[ -s $CREDS ]] || { echo "start the dev fixture first (docs/spec/1x-voice.md §8.2)"; exit 1; }
U=$(python3 -c "import json;print(json.load(open('$CREDS'))['username'])")
P=$(python3 -c "import json;print(json.load(open('$CREDS'))['password'])")
control() { curl -s -X POST http://127.0.0.1:$PORT/__fixture/$1 -H 'Content-Type: application/json' -d "$2" >/dev/null; }

launch() {   # launch <extra args…>
  SIMCTL_CHILD_HQN_SIGNIN_URL=http://127.0.0.1:$PORT SIMCTL_CHILD_HQN_SIGNIN_USERNAME=$U SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=$P \
    xcrun simctl launch --terminate-running-process $SIM $BUNDLE -HQDebugMemoFixture granted -HQDebugResetVoice YES \
    -HQDebugOpenBot default "$@" >/dev/null
}
shot() {     # shot <name> <seconds> <extra args…>   (SHOT_ONLY="a b" takes only those)
  local name=$1 wait=$2; shift 2
  if [[ -n "$SHOT_ONLY" && " $SHOT_ONLY " != *" $name "* ]]; then return; fi
  launch "$@"
  sleep $wait
  xcrun simctl io $SIM screenshot $OUT/$MODE-$name.png >/dev/null 2>&1
  echo "$MODE-$name"
}

# One sign-in to the dev fixture (a clean phone); every later launch restores it.
launch -HQDebugResetAccounts YES
sleep 6
for MODE in ${=SHOT_MODES:-light dark}; do
  xcrun simctl ui $SIM appearance $MODE
  shot idle-history 5
  shot pressing 3.5 -HQDebugMemoShot pressing -HQDebugMemoStartDelay 60
  shot holding 4 -HQDebugMemoShot holding
  shot armed 4 -HQDebugMemoShot armed
  shot lock-near 4 -HQDebugMemoShot lockNear
  shot locked 4.5 -HQDebugMemoShot locked
  shot review 7 -HQDebugMemoShot review
  shot review-playing 8.5 -HQDebugMemoShot playing
  shot confirm-delete 15 -HQDebugMemoShot confirm
  shot draft-chip-stopped 6 -HQDebugMemoShot holding -HQDebugMemoInterruptAfter 2
  for kind in denied transcript draft save record; do shot notice-$kind 3.5 -HQDebugMemoShotNotice $kind; done
  shot tip-now-hold 4 -HQDebugMemoShotTip nowHold
  shot tip-hold-to-record 4 -HQDebugMemoShotTip holdToRecord
  shot bubble-playing 6 -HQDebugMemoShot bubblePlaying -HQDebugMemoShotDelay 3
  control voice '{"uploadDelay":20}'
  shot sending-transcribing 6.5 -HQDebugMemoShot send
  control voice '{"uploadDelay":0}'
  sleep 16
  control plan "{\"plans\":[{\"chunks\":$(python3 -c "import json;print(json.dumps(['word ']*120))"),\"chunkDelay\":0.1}]}"
  shot queued-memo 7 -HQDebugSend "Write me a long answer" -HQDebugMemoShot send -HQDebugMemoShotDelay 3.6
  sleep 14
done
xcrun simctl ui $SIM appearance light
