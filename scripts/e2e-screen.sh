#!/bin/zsh
# Bot Screen end-to-end UI tests (UITests/screen/ScreenEndToEndTests.swift) against the screen fixture
# (scripts/fixtures/screen-gateway.py: a stand-in gateway with a live RFB screen, leases, the Mac health route,
# screenshots and file.attach). A copy of scripts/e2e-browser.sh for that fixture, with one difference: the simulator
# UDID is REQUIRED, so the shared default simulator can never be used.
# Usage: scripts/e2e-screen.sh <SIM_UDID>
#   Makes the fixture's frames once (scripts/fixtures/make-screen-frames.swift → build/fixtures/screen-frames), starts
#   the fixture on 127.0.0.1:${HQN_SCREEN_PORT:-9940} (9940-9949 only; refuses a busy port), writes its invented
#   credentials to build/fixtures/e2e-screen.json (0600, never printed), runs
#   -only-testing:HermesHQNativeUITests/ScreenEndToEndTests and stops the fixture it started.
#   HQN_SCREEN_ONLY="test04_takeOverPointerClicks,…"  narrows the run.
#   HQN_SCREEN_APPEARANCE=dark                       runs in dark (screenshots get the suffix -dark).
#   HQN_SCREEN_DARK=1                                after the light run, runs the screenshot tests again in dark.
#   HQN_SHOTS_DIR=<folder>                           where the tests save PNGs (default build/shots).
#   HQN_SCREEN_STRESS=1                              runs UITests/screen/ScreenStressTests.swift instead (the repeatable
#                                                    part of the stress plan, docs/spec/3x-screen.md §9).
#   test07 needs the on-screen keyboard: this simulator's "minimize the keyboard" setting is switched off for the run
#   and put back afterwards.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?pass your simulator UDID}
PORT=${HQN_SCREEN_PORT:-9940}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
# HQN_ANY_PORT=1: a ship run uses its own ports.
ANY=(); [[ -n "${HQN_ANY_PORT:-}" ]] && ANY=(--any-port)
[[ -n "${HQN_ANY_PORT:-}" ]] || case $PORT in 994[0-9]) ;; *) echo "use a port in 9940-9949 (HQN_SCREEN_PORT)"; exit 1;; esac
[[ -s $FIX/screen-frames/1280x800/manifest.json && -s $FIX/screen-frames/1920x1080/manifest.json ]] || swift scripts/fixtures/make-screen-frames.swift $FIX/screen-frames
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_SCREEN_PORT to a free port in 9940-9949"; exit 1
fi
CRED=$FIX/e2e-screen-$PORT.json
[[ $PORT == 9940 ]] && CRED=$FIX/e2e-screen.json
rm -f $CRED
python3 scripts/fixtures/screen-gateway.py --port $PORT $ANY --credentials $CRED --frames $FIX/screen-frames \
  > $FIX/e2e-screen-$PORT.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true; xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true; xcrun simctl spawn $SIM defaults delete com.apple.Preferences AutomaticMinimizationEnabled >/dev/null 2>&1 || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $CRED ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $CRED ]] || { echo "fixture did not start (see $FIX/e2e-screen-$PORT.log)"; exit 1; }
echo "screen fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
xcrun simctl spawn $SIM defaults write com.apple.Preferences AutomaticMinimizationEnabled -bool NO >/dev/null 2>&1 || true
# A fresh simulator covers the keyboard with its "slide to type" card the first time; this simulator has seen it.
xcrun simctl spawn $SIM defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool YES >/dev/null 2>&1 || true
# The tests that take the screenshots of every state (the dark pass runs these again).
SHOT_TESTS=test01_menuLabelFollowsStatus,test02_noAnswerThenRetry,test03_liveWatchZoomPanDoubleTap,test04_takeOverPointerClicks,test05_keyboardKeysAndModifiers,test06_pasteClipboardAndTyped,test07_rotateHintLandscapeCompactTyping,test09_relaunchHeldResumeAndHandBack,test10_otherViewerForceHandBackAndEviction,test11_notes,test13_pauseInBackgroundAndResume,test14_setupCardRequestCheckAndAutoOpen,test15_latestScreenshotsLiveStoredExpired,test16_toolScreenshotInStepSheet,test17_linuxEncodingsPixelExact,test18_botInfoTileAndComputerRow,test19_screenOffStartAndPackagesMissing,test20_largestTextSize,test22_macWithNoPictureSaysWhy,test23_aScreenshotThatCannotBeFetchedIsRetriedNotExpired
CLASS=ScreenEndToEndTests
[[ $HQN_SCREEN_STRESS == 1 ]] && CLASS=ScreenStressTests
run_suite() {   # $1 = appearance, $2 = comma-separated tests (empty = all)
  local appearance=$1 only=$2 args=()
  xcrun simctl ui $SIM appearance $appearance >/dev/null 2>&1 || true
  if [[ -n $only ]]; then
    for t in ${(s:,:)only}; do args+=(-only-testing:HermesHQNativeUITests/$CLASS/$t); done
  else
    args=(-only-testing:HermesHQNativeUITests/$CLASS)
  fi
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$CRED TEST_RUNNER_HQN_UI_SCREEN=1 TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS \
  TEST_RUNNER_HQN_SHOTS_SUFFIX=$appearance TEST_RUNNER_HQN_UI_SCREEN_STRESS=${HQN_SCREEN_STRESS:-0} \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $args \
    > build/last-e2e-screen-$appearance.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-screen-$appearance.log | tail -20
  echo "screen e2e ($appearance): xcodebuild exit $STATUS"
  return $STATUS
}
FAILED=0
run_suite ${HQN_SCREEN_APPEARANCE:-light} "$HQN_SCREEN_ONLY" || FAILED=1
if [[ $HQN_SCREEN_DARK == 1 && $CLASS == ScreenEndToEndTests ]]; then
  run_suite dark "${HQN_SCREEN_ONLY:-$SHOT_TESTS}" || FAILED=1
fi
exit $FAILED
