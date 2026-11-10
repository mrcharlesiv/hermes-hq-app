#!/bin/zsh
# Screenshots of every live-voice state, light and dark (docs/spec/3x-talk.md), into build/shots/<mode>-<name>.png.
# Usage: scripts/talk-shots.sh <SIM_UDID> [PORT]   — needs the voice fixture running on 127.0.0.1:PORT (default 9900,
# credentials build/fixtures/talk-dev.json) and the app installed on that simulator. The states are driven by the DEBUG
# hook -HQDebugTalkShot (App/Debug/TalkDebugHooks.swift) with the stand-in microphone and the stand-in speaker: no sound
# is made. SHOT_ONLY="listening muted" takes only those; SHOT_MODES="dark" only that appearance.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID}
PORT=${2:-9900}
BUNDLE=${HQN_BUNDLE:-com.charlesmcdowell.hermeshq.native}
OUT=build/shots
mkdir -p $OUT
CREDS=build/fixtures/talk-dev.json
[[ -s $CREDS ]] || { echo "start the dev fixture first (docs/briefs/m9/talk-report.md, How to run)"; exit 1; }
U=$(python3 -c "import json;print(json.load(open('$CREDS'))['username'])")
P=$(python3 -c "import json;print(json.load(open('$CREDS'))['password'])")
control() { curl -s -m 5 -X POST http://127.0.0.1:$PORT/__fixture/$1 -H 'Content-Type: application/json' -d "$2" >/dev/null; }

launch() {   # launch <extra args…>
  SIMCTL_CHILD_HQN_SIGNIN_URL=http://127.0.0.1:$PORT SIMCTL_CHILD_HQN_SIGNIN_USERNAME=$U SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=$P \
    xcrun simctl launch --terminate-running-process $SIM $BUNDLE -HQDebugTalkFixture granted -HQDebugTalkSpeaker fixture \
    -HQDebugResetVoice YES -HQDebugOpenBot ${HQN_SHOT_BOT:-ivy} "$@" >/dev/null
}
shot() {     # shot <name> <seconds> <extra args…>
  local name=$1 wait=$2; shift 2
  if [[ -n "$SHOT_ONLY" && " $SHOT_ONLY " != *" $name "* ]]; then return; fi
  launch "$@"
  sleep $wait
  xcrun simctl io $SIM screenshot $OUT/$MODE-$name.png >/dev/null 2>&1
  echo "$MODE-$name"
}

control voice '{"reset":true}'
# One sign-in to the dev fixture (a clean phone); every later launch restores it.
launch -HQDebugResetAccounts YES
sleep ${HQN_SHOT_SIGNIN_WAIT:-8}
for MODE in ${=SHOT_MODES:-light dark}; do
  xcrun simctl ui $SIM appearance $MODE
  shot talk-circle ${W:-5} -HQDebugTalkShot circle
  shot talk-tip ${W:-6} -HQDebugTalkShot tip
  shot intro ${W:-5} -HQDebugTalkShot intro
  shot info ${W:-5} -HQDebugTalkShot info
  for state in starting listening still muted reconnecting transcribing thinking speaking lost problem; do
    shot dock-$state ${W:-6} -HQDebugTalkShot $state
  done
  for state in paused-silence paused-interrupted paused-background paused-route stopped stopped-denied ended; do
    shot $state ${W:-5} -HQDebugTalkShot $state
  done
  for state in pill pill-problem pill-paused pill-stopped; do shot $state ${W:-7} -HQDebugTalkShot $state; done
  for state in read-preparing read-speaking; do shot $state ${W:-5} -HQDebugTalkShot $state; done
  for state in dictating dictation-transcribing dictation-empty dictation-failed dictation-denied; do
    shot $state ${W:-6} -HQDebugTalkShot $state
  done
  for state in settings-root settings-voice settings-conversation settings-stt settings-tts settings-eleven; do
    shot $state ${W:-7} -HQDebugTalkShot $state
  done
  shot diag ${W:-7} -HQDebugTalkShot diag
  shot diag-recording ${W:-8} -HQDebugTalkShot diag-recording
  shot diag-busy ${W:-8} -HQDebugTalkShot diag-busy
  shot diag-denied ${W:-8} -HQDebugTalkShot diag-denied
  # A real 3 second take, then what follows it.
  shot diag-recorded ${WLONG:-12} -HQDebugTalkShot diag-recorded
  shot diag-played ${WLONG:-14} -HQDebugTalkShot diag-played
  shot diag-transcribed ${WLONG:-14} -HQDebugTalkShot diag-transcribed
  shot audio-preview ${W:-8} -HQDebugTalkShot audio-preview
  shot audio-preview-playing ${WLONG:-10} -HQDebugTalkShot audio-preview-playing
  for state in ${=HQN_EXTRA_SHOTS}; do shot $state ${W:-6} -HQDebugTalkShot $state; done
done
xcrun simctl ui $SIM appearance light
xcrun simctl terminate $SIM $BUNDLE >/dev/null 2>&1 || true
