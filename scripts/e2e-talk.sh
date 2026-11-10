#!/bin/zsh
# Live voice end-to-end UI tests (UITests/talk/TalkEndToEndTests.swift, docs/spec/3x-talk.md §14.2) against the voice
# stand-in gateway.
# Usage: scripts/e2e-talk.sh <SIM_UDID> [PORT] [RUNS]
#   Runs scripts/check-talk-guards.sh first. Starts scripts/fixtures/voice-gateway.py on 127.0.0.1:PORT (default
#   $HQN_TALK_PORT or 9901; refuses a busy port), writes its invented credentials to build/fixtures/talk-e2e.json
#   (0600, never printed), passes that path to the runner as TEST_RUNNER_HQN_UI_CREDENTIALS, runs TalkEndToEndTests
#   (HQN_TALK_ONLY="testE01_…,testE02_…" narrows it), copies every named screenshot to build/shots/e2e-<name>.png and
#   stops the fixture it started. No sound is made: the tests use the stand-in microphone and speaker.
#   Logs: build/last-e2e-talk-<run>.log and build/fixtures/talk-<PORT>.log; a summary in build/last-e2e-talk.txt.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID (never the default simulator: this Mac is shared)}
PORT=${2:-${HQN_TALK_PORT:-9901}}
RUNS=${3:-1}
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
FIX=build/fixtures
OUT=${HQN_UI_SHOTS:-build/shots}
mkdir -p $FIX $OUT && chmod 700 $FIX

scripts/check-talk-guards.sh

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; the talk stream's builder owns 9900-9904"; exit 1
fi
rm -f $FIX/talk-e2e.json
rm -rf $FIX/talk-media-$PORT
python3 scripts/fixtures/voice-gateway.py --port $PORT --credentials $FIX/talk-e2e.json --media-dir $FIX/talk-media-$PORT \
  --ref $REF > $FIX/talk-$PORT.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/talk-e2e.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/talk-e2e.json ]] || { echo "fixture did not start (see $FIX/talk-$PORT.log)"; exit 1; }
echo "voice fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_TALK_ONLY" ]]; then
  for t in ${(s:,:)HQN_TALK_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/TalkEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/TalkEndToEndTests)
fi
FAILED=0
: > build/last-e2e-talk.txt
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$FIX/talk-e2e.json \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
    > build/last-e2e-talk-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  (python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-talk-$run.log | tail -20) | tee -a build/last-e2e-talk.txt
  TMP=build/shots-e2e.tmp
  rm -rf $TMP && mkdir -p $TMP
  xcrun xcresulttool export attachments --path "$RESULT" --output-path $TMP >/dev/null 2>&1 || true
  # Name each screenshot after its attachment (e2e-E02-speaking.png …).
  TMP=$TMP OUT=$OUT python3 - <<'PY' || true
import json, os, re
folder, out = os.environ['TMP'], os.environ['OUT']
try: manifest = json.load(open(os.path.join(folder, 'manifest.json')))
except OSError: manifest = []
for test in manifest:
    for item in test.get('attachments', []):
        exported = item.get('exportedFileName', '')
        name = re.sub(r'_\d+_[0-9A-F]{8}-[0-9A-F-]{27}', '', item.get('suggestedHumanReadableName', '')).removesuffix('.png')
        source = os.path.join(folder, exported)
        if name and exported.endswith('.png') and os.path.exists(source): os.replace(source, os.path.join(out, 'e2e-' + name + '.png'))
PY
  rm -rf $TMP
  echo "talk e2e run $run/$RUNS: xcodebuild exit $STATUS" | tee -a build/last-e2e-talk.txt
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
