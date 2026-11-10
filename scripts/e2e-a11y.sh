#!/bin/zsh
# Accessibility end-to-end UI tests (UITests/a11y/, docs/spec/3x-a11y.md §8.5).
# Usage: scripts/e2e-a11y.sh SIM_UDID
#   The simulator is required: this script never falls back to a default one.
#   Starts the settings stand-in gateway on 127.0.0.1:10120 and the pages stand-in (Jobs, Artifacts, Kanban, a bot
#   to chat with) on 10121 (HQN_A11Y_PORTS="10125 10126" moves them; the stress tester uses 10125-10129). Refuses a
#   busy port. Credentials go to build/fixtures/a11y-settings.json (0600, never printed) and
#   reach the runner as TEST_RUNNER_HQN_A11Y_SETTINGS; screenshots land in build/shots (TEST_RUNNER_HQN_SHOTS).
#   HQN_E2E_ONLY="testD4_signInFieldValidity,testE1_…" runs only those. HQN_A11Y_REAL=1 also runs the real-settings
#   pass (Bold Text, Reduce Transparency, Reduce Motion, Button Shapes switched on in this simulator, then off again). HQN_A11Y_LIVE=1 also runs the live
#   text-size and Increase Contrast pass (simctl ui while the app runs) and saves its screenshots.
#   The simulator is booted first and stays booted for the whole script (xcodebuild shuts down a simulator it had to
#   boot itself, which lost the live pass and the exit log in stress round 3); it is shut down again at the end only
#   if this script booted it. After the tests the script prints how every instance of the app ended, read from the
#   simulator's own log (build/last-e2e-a11y-exits.txt): an ordinary exit, the harness's SIGTERM, or anything else,
#   and anything else (SIGSEGV, SIGABRT, SIGKILL, a watchdog) fails the run as a real crash.
#   HQN_A11Y_NOBUILD=1 runs test-without-building (build once with build-for-testing, then run several lanes on
#   several simulators from the same derived data). HQN_A11Y_TAG names this run's result bundle and logs.
#   Only what this script started is stopped.
set -e
cd "$(dirname "$0")/.."
SIM=$1
if [[ -z "$SIM" ]]; then echo "usage: scripts/e2e-a11y.sh SIM_UDID   (create one: xcrun simctl create HQN-m9-a11y 'iPhone 17 Pro' com.apple.CoreSimulator.SimRuntime.iOS-27-0)"; exit 2; fi
FIX=${HQN_A11Y_FIX:-build/fixtures}
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
read -r PA PB REST <<< "${HQN_A11Y_PORTS:-10120 10121}"
PB=${PB:-$((PA + 1))}
for P in $PA $PB; do
  if lsof -nP -iTCP:$P -sTCP:LISTEN >/dev/null 2>&1; then echo "port $P is busy; stop it first"; exit 1; fi
done
TAG=${HQN_A11Y_TAG:-a11y}
BOOTED_HERE=
if ! xcrun simctl list devices booted | grep -q "$SIM"; then xcrun simctl boot $SIM >/dev/null 2>&1 || true; BOOTED_HERE=1; fi
xcrun simctl bootstatus $SIM >/dev/null 2>&1 || { echo "simulator $SIM did not boot"; exit 1; }
PIDS=()
RESTORE_SIZE=$(xcrun simctl ui $SIM content_size 2>/dev/null || echo large)
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done; xcrun simctl ui $SIM content_size ${RESTORE_SIZE:-large} >/dev/null 2>&1 || true; xcrun simctl ui $SIM increase_contrast disabled >/dev/null 2>&1 || true; if [[ -n "$REAL_ON" ]]; then for KEY in EnhancedTextLegibilityEnabled EnhancedBackgroundContrastEnabled ReduceMotionEnabled ButtonShapesEnabled; do xcrun simctl spawn $SIM defaults write com.apple.Accessibility $KEY -bool NO >/dev/null 2>&1 || true; done; fi; if [[ -n "$BOOTED_HERE" ]]; then xcrun simctl shutdown $SIM >/dev/null 2>&1 || true; fi' EXIT INT TERM
rm -f $FIX/a11y-settings.json
( umask 077; python3 scripts/fixtures/settings-gateway.py --port $PA --hermes-cookies --credentials $FIX/a11y-settings.json > $FIX/a11y-settings.log 2>&1 ) &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/a11y-settings.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 || { echo "the stand-in gateway did not start (see $FIX/a11y-settings.log)"; exit 1; }
chmod 600 $FIX/a11y-settings.json
rm -f $FIX/a11y-pages.json; mkdir -p $FIX/a11y-pages-files
( umask 077; python3 scripts/pages-fixture-gateway.py --port $PB --credentials $FIX/a11y-pages.json --files $FIX/a11y-pages-files --tick-seconds 0 > $FIX/a11y-pages.log 2>&1 ) &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/a11y-pages.json ]] && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 || { echo "the pages stand-in did not start (see $FIX/a11y-pages.log)"; exit 1; }
chmod 600 $FIX/a11y-pages.json
echo "a11y stand-in gateways on 127.0.0.1:$PA (settings) and :$PB (pages) (pids $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/A11yEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/A11yEndToEndTests)
STATUS=0
ACTION=test; [[ -n "$HQN_A11Y_NOBUILD" ]] && ACTION=test-without-building
LOG=build/last-e2e-$TAG.log
RESULT=$PWD/build/results/$TAG-$(date +%Y%m%d-%H%M%S).xcresult
mkdir -p build/results; rm -rf "$RESULT"
STARTED=$(date "+%Y-%m-%d %H:%M:%S")
TEST_RUNNER_HQN_A11Y_SETTINGS=$PWD/$FIX/a11y-settings.json TEST_RUNNER_HQN_A11Y_PAGES=$PWD/$FIX/a11y-pages.json TEST_RUNNER_HQN_SHOTS=$SHOTS \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$RESULT" $ACTION -quiet $ONLY \
  > $LOG 2>&1 || STATUS=$?
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" $LOG | tail -30
grep -h "\[a11y-soft\]\|\[a11y-visited\]\|\[measure\]" $LOG 2>/dev/null | sort -u | cut -c1-600 | head -60 || true
# How every instance of the app ended during the tests, from the simulator's own log.
APPID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' ${HQN_DD:-build/dd}/Build/Products/Debug-iphonesimulator/HermesHQNative.app/Info.plist 2>/dev/null || echo hermeshq)
EXITS=build/last-e2e-$TAG-exits.txt
xcrun simctl spawn $SIM log show --start "$STARTED" --style compact --predicate 'process == "launchd_sim" AND eventMessage CONTAINS "exited due"' 2>/dev/null \
  | grep -F "UIKitApplication:$APPID" | sed -E 's/^([0-9-]+ [0-9:.]+).*(exited due.*)$/\1 \2/' > $EXITS || true
CLEAN=$(grep -c "exited due to exit(0)" $EXITS || true)
HARNESS=$(grep -c "exited due to SIGTERM | sent by xcodebuild" $EXITS || true)
OTHER=$(grep -v "exited due to exit(0)" $EXITS | grep -vc "exited due to SIGTERM | sent by xcodebuild" || true)
echo "a11y app exits: $(wc -l < $EXITS | tr -d ' ') in all, $CLEAN ordinary exit, $HARNESS SIGTERM from the test harness, $OTHER anything else ($EXITS)"
if [[ "$OTHER" != 0 ]]; then
  echo "a11y app exits: the app ended some other way, which is a real crash or kill:"
  grep -v "exited due to exit(0)" $EXITS | grep -v "exited due to SIGTERM | sent by xcodebuild" | cut -c1-300
  [[ $STATUS -ne 0 ]] || STATUS=1
fi
echo "a11y e2e: xcodebuild exit $STATUS"

if [[ -n "$HQN_A11Y_REAL" ]]; then
  # Real-settings pass: Bold Text, Reduce Transparency, Reduce Motion and Button Shapes are switched on in THIS
  # simulator's own accessibility settings (not the DEBUG overrides), the simulator is restarted so every process
  # reads them, one test runs, and the settings are switched off again. Only ever the simulator passed in.
  AX=(EnhancedTextLegibilityEnabled EnhancedBackgroundContrastEnabled ReduceMotionEnabled ButtonShapesEnabled)
  real_settings() {   # YES | NO
    for KEY in $AX; do xcrun simctl spawn $SIM defaults write com.apple.Accessibility $KEY -bool $1 >/dev/null 2>&1 || true; done
    xcrun simctl shutdown $SIM >/dev/null 2>&1 || true
    xcrun simctl boot $SIM >/dev/null 2>&1 || true
    xcrun simctl bootstatus $SIM >/dev/null 2>&1 || true
  }
  REAL_ON=1; real_settings YES
  REALSTATUS=0
  REALRESULT=$PWD/build/results/$TAG-real-$(date +%Y%m%d-%H%M%S).xcresult; rm -rf "$REALRESULT"
  TEST_RUNNER_HQN_A11Y_REAL=1 TEST_RUNNER_HQN_SHOTS=$SHOTS \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never -resultBundlePath "$REALRESULT" $ACTION -quiet \
    -only-testing:HermesHQNativeUITests/A11yEndToEndTests/testC5_realSettingsAreSeenAndBoldIsNotDoubled \
    > build/last-e2e-a11y-real.log 2>&1 || REALSTATUS=$?
  real_settings NO; REAL_ON=
  python3 scripts/e2e-summary.py "$REALRESULT" || grep -E "error:|failed" build/last-e2e-a11y-real.log | tail -30
  grep -h "\[measure\] real settings" build/last-e2e-a11y-real.log 2>/dev/null | sort -u | cut -c1-900 || true
  echo "a11y real settings: xcodebuild exit $REALSTATUS"
  [[ $REALSTATUS -eq 0 ]] || STATUS=$REALSTATUS
fi

if [[ -n "$HQN_A11Y_LIVE" ]]; then
  # Live pass: the app keeps running while the text size and Increase Contrast change under it (the simulator's own
  # settings, not the DEBUG overrides). Fails if the app dies; the screenshots are for looking at.
  APP=$(ls -d ${HQN_DD:-build/dd}/Build/Products/Debug-iphonesimulator/HermesHQNative.app | head -1)
  BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
  xcrun simctl install $SIM "$APP"
  for ROOT in "-HQDemoChat 400 -HQDemoAutoOpen" "-HQDemoLists"; do
    NAME=${${ROOT#-HQDemo}%% *}
    xcrun simctl terminate $SIM $BUNDLE >/dev/null 2>&1 || true
    xcrun simctl ui $SIM content_size large; xcrun simctl ui $SIM increase_contrast disabled
    xcrun simctl launch $SIM $BUNDLE ${=ROOT} -HQA11yAudit YES >/dev/null
    sleep 6
    LIVEPID=$(xcrun simctl spawn $SIM launchctl list | awk -v b="$BUNDLE" '$3 ~ b {print $1}' | head -1)
    for SIZE in extra-small accessibility-extra-extra-extra-large large accessibility-large extra-extra-extra-large accessibility-extra-large large; do
      xcrun simctl ui $SIM content_size $SIZE; sleep 2.5
      xcrun simctl io $SIM screenshot "$SHOTS/a11y-live-$NAME-$SIZE.png" >/dev/null 2>&1
    done
    # Every one-notch step, up and then down (stress round 1: Large <-> Extra Large with a chat open crashed; the
    # jumps above never take that step), then the same single step back and forth quickly.
    LADDER=(extra-small small medium large extra-large extra-extra-large extra-extra-extra-large accessibility-medium accessibility-large accessibility-extra-large accessibility-extra-extra-large accessibility-extra-extra-extra-large)
    for SIZE in $LADDER ${(Oa)LADDER} small medium large; do xcrun simctl ui $SIM content_size $SIZE; sleep 1.2; done
    for i in {1..6}; do xcrun simctl ui $SIM content_size extra-large; sleep 0.6; xcrun simctl ui $SIM content_size large; sleep 0.6; done
    STEPPID=$(xcrun simctl spawn $SIM launchctl list | awk -v b="$BUNDLE" '$3 ~ b {print $1}' | head -1)
    if [[ "$STEPPID" != "$LIVEPID" ]]; then echo "a11y live ($NAME): the app died on a one-notch text size step (pid $LIVEPID -> $STEPPID)"; STATUS=1; fi
    xcrun simctl io $SIM screenshot "$SHOTS/a11y-live-$NAME-after-steps.png" >/dev/null 2>&1
    xcrun simctl ui $SIM increase_contrast enabled; sleep 2.5
    xcrun simctl io $SIM screenshot "$SHOTS/a11y-live-$NAME-contrast-on.png" >/dev/null 2>&1
    for i in {1..10}; do xcrun simctl ui $SIM increase_contrast disabled; sleep 0.3; xcrun simctl ui $SIM increase_contrast enabled; sleep 0.3; done
    for i in {1..3}; do for SIZE in extra-small accessibility-extra-extra-extra-large medium accessibility-medium; do xcrun simctl ui $SIM content_size $SIZE; sleep 0.5; done; done
    xcrun simctl ui $SIM increase_contrast disabled; xcrun simctl ui $SIM content_size large; sleep 3
    xcrun simctl io $SIM screenshot "$SHOTS/a11y-live-$NAME-after-storm.png" >/dev/null 2>&1
    NOWPID=$(xcrun simctl spawn $SIM launchctl list | awk -v b="$BUNDLE" '$3 ~ b {print $1}' | head -1)
    if [[ -z "$NOWPID" || "$NOWPID" == "-" || "$NOWPID" != "$LIVEPID" ]]; then echo "a11y live ($NAME): the app did not survive (pid $LIVEPID -> $NOWPID)"; STATUS=1
    else echo "a11y live ($NAME): the app survived 7 size jumps, 38 one-notch size steps, 21 contrast flips and a 12-change size storm (pid $NOWPID)"; fi
    xcrun simctl terminate $SIM $BUNDLE >/dev/null 2>&1 || true
  done
fi
exit $STATUS
