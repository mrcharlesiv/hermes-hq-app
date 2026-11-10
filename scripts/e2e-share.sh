#!/bin/zsh
# [share] Share extension end-to-end UI tests (UITests/share/ShareEndToEndTests.swift) against this stream's stand-in
# gateway (scripts/fixtures/share-gateway.py). docs/spec/3x-share.md §10.4.
#
# Usage: scripts/e2e-share.sh SIM_UDID [RUNS]
#   Always the Hermes HQ identity (HQ_ORIGINAL=YES): only that build embeds the extension.
#   Starts the fixture on 127.0.0.1:${HQN_SHARE_PORT:-9910} and a second gateway on ${HQN_SHARE_PORT_B:-9914}
#   (9910-9919 only; refuses a busy port), writes their invented credentials to build/fixtures/share*.json (0600, never
#   printed), makes the invented media, builds for testing, checks the built extension
#   (scripts/check-share-target.sh), installs the app and the test-only host app HQShareProbe on SIM_UDID, runs
#   -only-testing:HermesHQNativeUITests/ShareEndToEndTests RUNS times and stops what it started.
#
#   HQN_SHARE_ONLY="testS03_PhotoLosesItsLocation,…"  narrows the run
#   HQN_SHARE_NOUS=1         also starts the reference Nous fixture on ${HQN_SHARE_NOUS_PORT:-9912} with its stand-in
#                            Portal on ${HQN_SHARE_PORTAL_PORT:-9913} and runs testS14 (never while ShareFixtureTests'
#                            gateway holds 9913)
#   HQN_SHARE_REAL_HOSTS=1   also runs the Safari / Photos / Files tests (they drive those apps)
#   HQN_SHARE_DARK=1         the whole run in dark appearance (screenshots are named …-dark.png); light again after
#   HQN_SHARE_SUFFIX=-s      another name for the fixture files (a stress run beside a builder's)
#   HQN_SKIP_BUILD=1         reuse the last build-for-testing
#   HQN_DD=…                 derived data (default build/dd, inside this worktree)
# Use your own simulator, never one signed in to a real gateway. The simulator is left booted: shut it down when done.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-share.sh SIM_UDID [RUNS]}
RUNS=${2:-1}
PORT=${HQN_SHARE_PORT:-9910}
PORT_B=${HQN_SHARE_PORT_B:-9914}
PORT_N=${HQN_SHARE_NOUS_PORT:-9912}
PORT_P=${HQN_SHARE_PORTAL_PORT:-9913}
SUFFIX=${HQN_SHARE_SUFFIX:-}
DD=${HQN_DD:-build/dd}
FIX=build/fixtures
REF=/Users/me/Projects/hermes-hq-native-ref238
BUNDLE=com.charlesmcdowell.dispatch
GROUP_ID=group.com.charlesmcdowell.dispatch
export HQ_ORIGINAL=YES
mkdir -p $FIX build/shots && chmod 700 $FIX

USED=($PORT $PORT_B)
[[ -n "$HQN_SHARE_NOUS" ]] && USED+=($PORT_N $PORT_P)
for port in $USED; do
  if (( port < 9910 || port > 9919 )); then echo "port $port is outside 9910-9919"; exit 1; fi
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is already in use; stop what holds it first"; exit 1; fi
done
typeset -aU DISTINCT=($USED)
if (( ${#DISTINCT} != ${#USED} )); then echo "the ports must differ: $USED"; exit 1; fi

# Invented media (kept between runs).
MEDIA=$FIX/share-media
if [[ ! -s $MEDIA/huge.jpg || ! -s $MEDIA/clip-gps.mov || ! -s $MEDIA/exact.bin || ! -s $MEDIA/p12.jpg ]]; then
  swift scripts/fixtures/make-share-media.swift $MEDIA
fi

PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
A=$FIX/share$SUFFIX; B=$FIX/share-b$SUFFIX
rm -f $A.json $B.json $FIX/share-nous$SUFFIX.json
python3 scripts/fixtures/share-gateway.py --port $PORT --credentials $A.json --files $A-files --log $A.jsonl --sim $SIM \
  > $A.out 2>&1 &
PIDS+=($!)
python3 scripts/fixtures/share-gateway.py --port $PORT_B --credentials $B.json --files $B-files --log $B.jsonl \
  > $B.out 2>&1 &
PIDS+=($!)
if [[ -n "$HQN_SHARE_NOUS" ]]; then
  python3 $REF/scripts/nous-fixture-gateway.py --port $PORT_N --portal-port $PORT_P --public-url http://127.0.0.1:$PORT_N \
    --access-ttl 30 > $FIX/share-nous$SUFFIX.out 2>&1 &
  PIDS+=($!)
  print -r -- "{\"url\":\"http://127.0.0.1:$PORT_N\",\"nous\":true}" > $FIX/share-nous$SUFFIX.json
fi
for i in {1..75}; do
  [[ -s $A.json && -s $B.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PORT_B -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $A.json && -s $B.json ]] || { echo "the fixtures did not start (see $A.out, $B.out)"; exit 1; }
if [[ -n "$HQN_SHARE_NOUS" ]]; then
  for i in {1..75}; do lsof -nP -iTCP:$PORT_N -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
  lsof -nP -iTCP:$PORT_N -sTCP:LISTEN >/dev/null 2>&1 || { echo "the Nous fixture did not start (see $FIX/share-nous$SUFFIX.out)"; exit 1; }
fi
echo "share fixtures on 127.0.0.1:$PORT and :$PORT_B (pids $PIDS)"

if [[ -z "$HQN_SKIP_BUILD" ]]; then
  [[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath $DD build-for-testing -quiet > build/last-e2e-share-build.log 2>&1 \
    || { grep -E "error:" build/last-e2e-share-build.log | cut -c1-300 | sort -u | head -30; echo "share e2e: the build failed (build/last-e2e-share-build.log)"; exit 1; }
fi
PRODUCTS=$DD/Build/Products/Debug-iphonesimulator
scripts/check-share-target.sh $PRODUCTS/HermesHQNative.app

xcrun simctl bootstatus $SIM -b > /dev/null
xcrun simctl install $SIM $PRODUCTS/HermesHQNative.app
xcrun simctl install $SIM $PRODUCTS/HQShareProbe.app
# The opt-in Photos test needs one photo in the library (an invented one, with a location to lose).
[[ -n "$HQN_SHARE_REAL_HOSTS" ]] && xcrun simctl addmedia $SIM $MEDIA/photo-gps.jpg
GROUP=$(xcrun simctl get_app_container $SIM $BUNDLE $GROUP_ID)
[[ -d $GROUP ]] || { echo "the simulator has no App Group folder for $GROUP_ID"; exit 1; }

# (Never waits on a simulator that has stopped answering: each call is given 20 s.)
sim_ui() {
  xcrun simctl ui $SIM "$@" > /dev/null 2>&1 &
  local pid=$!
  ( sleep 20; kill $pid 2>/dev/null ) > /dev/null 2>&1 &
  local guard=$!
  wait $pid 2>/dev/null || true
  kill $guard 2>/dev/null || true
}
[[ "$HQN_SHARE_DARK" == "1" ]] && sim_ui appearance dark

ONLY=()
if [[ -n "$HQN_SHARE_ONLY" ]]; then
  for t in ${(s:,:)HQN_SHARE_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/ShareEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/ShareEndToEndTests)
fi
STATUS=0
for run in {1..$RUNS}; do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$A.json TEST_RUNNER_HQN_SHARE_B=$PWD/$B.json \
  TEST_RUNNER_HQN_UI_FIXTURE_URL=http://127.0.0.1:$PORT TEST_RUNNER_HQN_SHARE_MEDIA=$PWD/$MEDIA \
  TEST_RUNNER_HQN_SHARE_GROUP=$GROUP TEST_RUNNER_HQN_SHARE_FILES=$PWD/$A-files TEST_RUNNER_HQN_UI_SHOTS=$PWD/build/shots \
  TEST_RUNNER_HQN_SHARE_NOUS=${HQN_SHARE_NOUS:+$PWD/$FIX/share-nous$SUFFIX.json} \
  TEST_RUNNER_HQN_SHARE_REAL_HOSTS=${HQN_SHARE_REAL_HOSTS:-} TEST_RUNNER_HQN_UI_DARK=${HQN_SHARE_DARK:-0} \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath $DD -parallel-testing-enabled NO test-without-building -quiet $ONLY \
    > build/last-e2e-share.log 2>&1 && ONE=0 || ONE=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-share.log | cut -c1-300 | tail -20
  echo "share e2e run $run of $RUNS: xcodebuild exit $ONE"
  (( ONE == 0 )) || STATUS=$ONE
done
# The look of the simulator goes back to the usual, whatever a test left.
sim_ui content_size large
sim_ui appearance light
sim_ui increase_contrast disabled
echo "share e2e: exit $STATUS"
exit $STATUS
