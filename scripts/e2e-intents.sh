#!/bin/zsh
# [intents] Siri, Shortcuts, the Action Button and Home Screen quick actions end to end
# (UITests/intents/IntentsEndToEndTests.swift; docs/spec/3x-intents.md §13 and §14) against two stand-in gateways:
#   scripts/fixtures/intents-gateway.py         two bots and the voice memo pipeline       127.0.0.1:${HQN_INTENTS_PORT:-9921}
#   scripts/fixtures/intents-pages-gateway.py   five bots and listed chats (quick actions) 127.0.0.1:${HQN_INTENTS_PAGES_PORT:-9922}
# Usage: scripts/e2e-intents.sh SIM_UDID [RUNS]
#   Ports must be in 9920-9929 and free (a busy port is refused: another agent, or a real Hermes, may be there).
#   Invented credentials go to build/fixtures/ (0600, never printed). Runs only IntentsEndToEndTests
#   (HQN_INTENTS_ONLY="testA14_…,testS01_…" narrows it), one test at a time. Before each run the app is removed from
#   the simulator so its notification permission starts unasked (HQN_INTENTS_KEEP_APP=1 skips that). Light and dark
#   screenshots go to ${HQN_UI_SHOTS:-build/shots}/intents-<name>-<light|dark>.png; the tests' measured times and
#   which-outcome notes to build/intents-ui/notes.txt. The app's own screens are put in each appearance by a debug
#   hook; the Home Screen's menu and the Shortcuts app are the system's, so after the runs the simulator itself is set
#   to dark (xcrun simctl ui … appearance), the three tests that show them run once more, and it is set back to light
#   (HQN_INTENTS_NO_DARK_PASS=1 skips that; it is also skipped with HQN_INTENTS_ONLY; HQN_INTENTS_DARK_ONLY=1 runs
#   that dark pass alone, on the app as it is installed). HQ_IDENTITY=original runs the shipping identity (scheme
#   "hermes", name "Hermes HQ"). DerivedData: ${HQN_DD:-build/dd}. Stops the fixtures it started, and only those.
#   Use your own simulator, never one signed in to a real gateway.
#   Logs: build/last-e2e-intents-<run>.log, build/last-e2e-intents-dark.log, build/fixtures/intents-<port>.log,
#   build/fixtures/intents-pages-<port>.log.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-intents.sh SIM_UDID [RUNS]}
RUNS=${2:-1}
[[ -z "$HQN_INTENTS_DARK_ONLY" ]] || RUNS=0
PORT=${HQN_INTENTS_PORT:-9921}
PAGES_PORT=${HQN_INTENTS_PAGES_PORT:-9922}
REF=${HQN_REF:-/Users/me/Projects/hermes-hq-native-ref238}
DD=${HQN_DD:-build/dd}
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
for p in $PORT $PAGES_PORT; do
  if [[ -z "$HQN_ANY_PORT" ]] && (( p < 9920 || p > 9929 )); then echo "intents ports must be in 9920-9929 (got $p)"; exit 1; fi
  if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is already in use"; exit 1; fi
done
[[ $PORT != $PAGES_PORT ]] || { echo "the two fixtures need two ports"; exit 1; }

if [[ ${HQ_IDENTITY:-native} == original ]]; then
  export HQ_ORIGINAL=YES; BUNDLE=com.charlesmcdowell.dispatch; URL_SCHEME=hermes; APP_NAME="Hermes HQ"
else
  unset HQ_ORIGINAL; BUNDLE=com.charlesmcdowell.hermeshq.native; URL_SCHEME=hermeshq-native; APP_NAME="HQ Native"
fi

CRED=$FIX/intents-e2e.json
PAGES_CRED=$FIX/intents-pages-e2e.json
rm -f $CRED $PAGES_CRED
rm -rf $FIX/intents-media-$PORT
HQN_INTENTS_ANY_PORT=${HQN_INTENTS_ANY_PORT:-$HQN_ANY_PORT} python3 scripts/fixtures/intents-gateway.py --port $PORT --credentials $CRED --media-dir $FIX/intents-media-$PORT --ref $REF \
  > $FIX/intents-$PORT.log 2>&1 &
FIXTURE_PID=$!
HQN_INTENTS_ANY_PORT=${HQN_INTENTS_ANY_PORT:-$HQN_ANY_PORT} python3 scripts/fixtures/intents-pages-gateway.py --port $PAGES_PORT --credentials $PAGES_CRED --files $FIX/intents-pages-files \
  --tick-seconds 0 > $FIX/intents-pages-$PAGES_PORT.log 2>&1 &
PAGES_PID=$!
DARK_PASS=0
trap 'kill $FIXTURE_PID $PAGES_PID 2>/dev/null || true; [[ $DARK_PASS -eq 1 ]] && xcrun simctl ui $SIM appearance light >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM          # an interrupted run stops here (and the EXIT trap cleans up), it does not go on to the next run
for i in {1..75}; do
  [[ -s $CRED && -s $PAGES_CRED ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PAGES_PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $CRED ]] || { echo "the intents fixture did not start (see $FIX/intents-$PORT.log)"; exit 1; }
[[ -s $PAGES_CRED ]] || { echo "the pages fixture did not start (see $FIX/intents-pages-$PAGES_PORT.log)"; exit 1; }
chmod 600 $CRED $PAGES_CRED
echo "intents fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID); pages fixture on 127.0.0.1:$PAGES_PORT (pid $PAGES_PID)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_INTENTS_ONLY" ]]; then
  for t in ${(s:,:)HQN_INTENTS_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/IntentsEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/IntentsEndToEndTests)
fi
mkdir -p build/intents-ui
FAILED=0

# testA11 renames a bot and looks for the new name in the Shortcuts app. The system rations an app's parameter
# refreshes, and a run of this suite (a fresh sign-in per test) spends the ration, so the test itself only notes
# "NOT SEEN". Here the simulator's own log decides: the refresh was refused by the system ("Donation quota exceeded")
# -> said, and not a failure of the app; not seen and not refused -> a failure.
rationed_or_failed() {
  tail -n +$((NOTES_BEFORE + 1)) build/intents-ui/notes.txt | grep -q "A11/L608 NOT SEEN" || return 0
  local refused
  refused=$(xcrun simctl spawn $SIM log show --start "$RUN_START" --style compact \
    --predicate "eventMessage CONTAINS \"Donation quota exceeded for $BUNDLE\"" 2>/dev/null | grep -c "Donation quota exceeded" || true)
  if (( refused > 0 )); then
    echo "$1: the Shortcuts app did not show the renamed bot; the system refused $refused parameter refresh(es) in this run (\"Donation quota exceeded\" in the simulator's log), so the rename could not be seen here"
    echo "$1: the system refused $refused parameter refresh(es) (Donation quota exceeded)" >> build/intents-ui/notes.txt
    return 0
  fi
  echo "$1: FAILED: the Shortcuts app did not show the renamed bot, and the system did not refuse the refresh"
  return 1
}
RUN_LIST=()
(( RUNS < 1 )) || RUN_LIST=($(seq 1 $RUNS))
for run in $RUN_LIST; do
  [[ -n "$HQN_INTENTS_KEEP_APP" ]] || xcrun simctl uninstall $SIM $BUNDLE >/dev/null 2>&1 || true
  echo "--- run $run/$RUNS ($(date '+%H:%M:%S'))" >> build/intents-ui/notes.txt
  RUN_START=$(date '+%Y-%m-%d %H:%M:%S'); NOTES_BEFORE=$(wc -l < build/intents-ui/notes.txt)
  TEST_RUNNER_HQN_UI_INTENTS=1 TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$CRED TEST_RUNNER_HQN_UI_CREDENTIALS_PAGES=$PWD/$PAGES_CRED \
    TEST_RUNNER_HQN_UI_SHOTS=$SHOTS TEST_RUNNER_HQN_UI_SCHEME=$URL_SCHEME TEST_RUNNER_HQN_UI_APP_NAME="$APP_NAME" \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD -parallel-testing-enabled NO test -quiet $ONLY \
    > build/last-e2e-intents-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-intents-$run.log | tail -20
  echo "intents e2e run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
  rationed_or_failed "run $run/$RUNS" || FAILED=1
done
if [[ -z "$HQN_INTENTS_ONLY" && -z "$HQN_INTENTS_NO_DARK_PASS" ]]; then
  # The system's own screens (the Home Screen menu with the quick actions, the Shortcuts app) in dark.
  DARK_PASS=1
  xcrun simctl ui $SIM appearance dark
  echo "--- dark pass ($(date '+%H:%M:%S'))" >> build/intents-ui/notes.txt
  RUN_START=$(date '+%Y-%m-%d %H:%M:%S'); NOTES_BEFORE=$(wc -l < build/intents-ui/notes.txt)
  DARK=()
  for t in testA11_TheShortcutsAppListsTheAction testA37_TheHomeScreenMenuShowsTheItemsAndSearchChatsOpensSearch \
           testA40_AStaleItemIsRefusedAndSigningOutEndsTheSignIn; do
    DARK+=(-only-testing:HermesHQNativeUITests/IntentsEndToEndTests/$t)
  done
  TEST_RUNNER_HQN_UI_INTENTS=1 TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$CRED TEST_RUNNER_HQN_UI_CREDENTIALS_PAGES=$PWD/$PAGES_CRED \
    TEST_RUNNER_HQN_UI_SHOTS=$SHOTS TEST_RUNNER_HQN_UI_SCHEME=$URL_SCHEME TEST_RUNNER_HQN_UI_APP_NAME="$APP_NAME" \
    TEST_RUNNER_HQN_UI_DEVICE_LOOK=dark \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD -parallel-testing-enabled NO test -quiet $DARK \
    > build/last-e2e-intents-dark.log 2>&1 && STATUS=0 || STATUS=$?
  xcrun simctl ui $SIM appearance light
  DARK_PASS=0
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-intents-dark.log | tail -20
  echo "intents e2e dark pass (the system's screens): xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
  rationed_or_failed "dark pass" || FAILED=1
fi
echo "notes: build/intents-ui/notes.txt   screenshots: $SHOTS/intents-*.png"
exit $FAILED
