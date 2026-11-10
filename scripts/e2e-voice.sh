#!/bin/zsh
# Voice memo end-to-end UI tests (UITests/voice/VoiceMemoEndToEndTests.swift) against the voice stand-in gateway.
# Usage: scripts/e2e-voice.sh [SIM_UDID] [RUNS]
#   Starts scripts/fixtures/voice-gateway.py on 127.0.0.1:$HQN_VOICE_PORT (default 9727; refuses a busy port), writes
#   its invented credentials to build/fixtures/voice-e2e.json (0600, never printed), passes that path to the runner as
#   TEST_RUNNER_HQN_UI_CREDENTIALS, runs only VoiceMemoEndToEndTests (HQN_VOICE_ONLY="testE01_…,testE02_…" narrows
#   it), exports the screenshots to .build/shots/e2e/, and stops the fixture it started.
#   Logs: build/last-e2e-voice-<run>.log and build/fixtures/voice-9727.log.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-1BE77711-F7EF-4BE6-AE1B-2D4DE84525D2}}
RUNS=${2:-1}
PORT=${HQN_VOICE_PORT:-9727}
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; the voice stream owns 9726-9728"; exit 1
fi
rm -f $FIX/voice-e2e.json
rm -rf $FIX/voice-media-$PORT
HQN_VOICE_ANY_PORT=${HQN_VOICE_ANY_PORT:-$HQN_ANY_PORT} python3 scripts/fixtures/voice-gateway.py --port $PORT --credentials $FIX/voice-e2e.json --media-dir $FIX/voice-media-$PORT \
  --ref $REF > $FIX/voice-$PORT.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/voice-e2e.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/voice-e2e.json ]] || { echo "fixture did not start (see $FIX/voice-$PORT.log)"; exit 1; }
echo "voice fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_VOICE_ONLY" ]]; then
  for t in ${(s:,:)HQN_VOICE_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/VoiceMemoEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/VoiceMemoEndToEndTests)
fi
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/voice-e2e.json \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
    > build/last-e2e-voice-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-voice-$run.log | tail -20
  VSHOTS=${HQN_UI_SHOTS:-.build/shots/e2e}
  rm -rf .build/shots/e2e.tmp && mkdir -p $VSHOTS .build/shots/e2e.tmp
  xcrun xcresulttool export attachments --path "$RESULT" --output-path .build/shots/e2e.tmp >/dev/null 2>&1 || true
  # Name each screenshot after its attachment (E01-sent-memo.png …).
  VSHOTS=$VSHOTS python3 - <<'PY' || true
import json, os, re
folder = '.build/shots/e2e.tmp'
try: manifest = json.load(open(os.path.join(folder, 'manifest.json')))
except OSError: manifest = []
for test in manifest:
    for item in test.get('attachments', []):
        exported = item.get('exportedFileName', '')
        name = re.sub(r'_\d+_[0-9A-F]{8}-[0-9A-F-]{27}', '', item.get('suggestedHumanReadableName', '')).removesuffix('.png')
        source = os.path.join(folder, exported)
        if name and exported.endswith('.png') and os.path.exists(source): os.replace(source, os.path.join(os.environ.get('VSHOTS', '.build/shots/e2e'), name + '.png'))
PY
  rm -rf .build/shots/e2e.tmp
  echo "voice e2e run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
