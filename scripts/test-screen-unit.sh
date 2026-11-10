#!/bin/zsh
# Bot Screen's unit tests (Tests/Screen/, docs/spec/3x-screen.md §8), with the live-socket suite running against the
# stand-in gateway (scripts/fixtures/screen-gateway.py) this script starts and stops.
#
#   scripts/test-screen-unit.sh <simulator-udid> [Suite ...]      # no suite named: every Screen suite
#
# HQN_SCREEN_UNIT_PORT (default 9941; any port in 9940-9949). Log: build/last-screen-unit.log.
set -u
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID (never the default simulator: this Mac is shared)}
shift
PORT=${HQN_SCREEN_UNIT_PORT:-9941}
# HQN_ANY_PORT=1: a ship run uses its own ports.
ANY=(); [[ -n "${HQN_ANY_PORT:-}" ]] && ANY=(--any-port)
[[ -n "${HQN_ANY_PORT:-}" ]] || case $PORT in 994[0-9]) ;; *) echo "use a port in 9940-9949 (HQN_SCREEN_UNIT_PORT)"; exit 1;; esac
FIX=build/fixtures
mkdir -p $FIX && chmod 700 $FIX
[[ -s $FIX/screen-frames/1280x800/manifest.json && -s $FIX/screen-frames/1920x1080/manifest.json ]] || swift scripts/fixtures/make-screen-frames.swift $FIX/screen-frames
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_SCREEN_UNIT_PORT to a free port in 9940-9949"; exit 1
fi
CRED=$FIX/screen-$PORT.json
rm -f $CRED
python3 scripts/fixtures/screen-gateway.py --port $PORT $ANY --credentials $CRED --frames $FIX/screen-frames > $FIX/screen-$PORT.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $CRED ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $CRED ]] || { echo "fixture did not start (see $FIX/screen-$PORT.log)"; exit 1; }
echo "screen fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

SUITES=("$@")
if (( ${#SUITES} == 0 )); then
  SUITES=(MacScreenTests RFBBadDataTests RFBParserTests ScreenControlBarTests ScreenHoldsTests ScreenKeyFieldTests ScreenKeysTests
          ScreenLiveWireTests ScreenSessionTests ScreenSetupTests ScreenStreamTests ScreenViewMathTests ScreenWireTests
          ScreenshotFeedTests ToolScreenshotsTests)
fi
ONLY=()
for suite in $SUITES; do ONLY+=(-only-testing:HermesHQNativeTests/$suite); done
xcodegen generate -q
TEST_RUNNER_HQN_SCREEN_FIXTURE="http://127.0.0.1:$PORT|$PWD/$CRED" \
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd test $ONLY > build/last-screen-unit.log 2>&1
CODE=$?
grep -E "error:|✘|recorded an issue|Test run with|Suite .* (passed|failed)" build/last-screen-unit.log | grep -v "^note" | tail -${LINES_MAX:-60}
echo "screen unit tests: xcodebuild exit $CODE"
exit $CODE
