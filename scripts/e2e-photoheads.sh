#!/bin/zsh
# Photo-heads end-to-end UI tests (UITests/photoheads/) against the photoheads fixture (docs/spec/3x-photoheads.md §10).
# Usage: scripts/e2e-photoheads.sh SIM_UDID
#   Three stand-in gateways on 127.0.0.1 (HQN_PHOTOHEADS_PORTS="A B OLD", default "9950 9951 9952"):
#     A    --hermes-cookies --media   the seeded pictures of §10.1
#     B    --label Beta --media       the same bot names, other pictures (gateway switch)
#     OLD  --no-assets                an older gateway: no has_avatar, no asset methods
#   Refuses busy ports; credentials go to build/fixtures/photoheads-*.json (0600, never printed) and reach the runner
#   as TEST_RUNNER_HQN_PHOTOHEADS_A / _B / _OLD; the pictures the tests pick are in build/fixtures/photoheads-media
#   (made by scripts/fixtures/make-photoheads-media.swift when missing; TEST_RUNNER_HQN_PHOTOHEADS_MEDIA). One of them
#   is added to the simulator's photo library once (the real-picker test) and copied into its On My iPhone as
#   photoheads-pick.jpg (the Choose File test). Screenshots land in build/shots (HQN_UI_SHOTS moves them;
#   HQN_SHOTS_DARK=1 runs dark, HQN_UI_DESKTOPLOOK=1 in the Desktop Look). Only the fixtures this script started are stopped.
#   HQN_E2E_ONLY="testP1_…,testP6_…" runs only those tests. HQN_E2E_ITERATIONS=20 runs each chosen test that many
#   times in one go (xcodebuild -test-iterations). The simulator is required: there is no default one.
#   HQ_IDENTITY=original tests the original record's build (the one that may show a sender's picture on an alert:
#   testP21b_…); give it its own HQN_DD so the two builds do not rebuild each other, and never run both at once in
#   one worktree (they share the generated project).
set -e
cd "$(dirname "$0")/.."
SIM=${1:-$HQ_SIM}
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-photoheads.sh SIM_UDID  (your own simulator; there is no default)"; exit 1; }
FIX=build/fixtures
MEDIA=$PWD/$FIX/photoheads-media
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

read -r PA PB PO <<< "${HQN_PHOTOHEADS_PORTS:-9950 9951 9952}"
for port in $PA $PB $PO; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first"; exit 1; fi
done
[[ -s $MEDIA/portrait.jpg && -s $MEDIA/huge.jpg ]] || swift scripts/fixtures/make-photoheads-media.swift $MEDIA > $FIX/photoheads-media.log 2>&1

PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/photoheads-a.json $FIX/photoheads-b.json $FIX/photoheads-old.json
python3 scripts/fixtures/photoheads-gateway.py --port $PA --hermes-cookies --credentials $FIX/photoheads-a.json --media $MEDIA \
  > $FIX/photoheads-a.log 2>&1 &
PIDS+=($!)
python3 scripts/fixtures/photoheads-gateway.py --port $PB --label Beta --credentials $FIX/photoheads-b.json --media $MEDIA \
  > $FIX/photoheads-b.log 2>&1 &
PIDS+=($!)
python3 scripts/fixtures/photoheads-gateway.py --port $PO --no-assets --credentials $FIX/photoheads-old.json \
  > $FIX/photoheads-old.log 2>&1 &
PIDS+=($!)
for i in {1..75}; do
  [[ -s $FIX/photoheads-a.json && -s $FIX/photoheads-b.json && -s $FIX/photoheads-old.json ]] \
    && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PO -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PO -sTCP:LISTEN >/dev/null 2>&1 || { echo "fixtures did not start (see $FIX/photoheads-*.log)"; exit 1; }
echo "photoheads fixtures on 127.0.0.1:$PA, :$PB (Beta) and :$PO (no assets); pids $PIDS"

# The real-picker test picks from the simulator's own library: one drawn picture, added once per simulator.
xcrun simctl bootstatus $SIM -b > /dev/null 2>&1 || true
if [[ ! -e $FIX/photoheads-library-$SIM ]]; then
  xcrun simctl addmedia $SIM $MEDIA/portrait.jpg > /dev/null 2>&1 && touch $FIX/photoheads-library-$SIM || echo "could not add a picture to the simulator's library"
fi
# The Choose File test picks from the Files browser: the same picture, in this simulator's On My iPhone (the app
# group of the system's local file provider).
rm -f $FIX/photoheads-files-$SIM
find ~/Library/Developer/CoreSimulator/Devices/$SIM/data/Containers/Shared/AppGroup -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r group; do
  id=$(plutil -extract MCMMetadataIdentifier raw "$group/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)
  if [[ $id == group.com.apple.FileProvider.LocalStorage ]]; then
    mkdir -p "$group/File Provider Storage" && cp $MEDIA/portrait.jpg "$group/File Provider Storage/photoheads-pick.jpg" \
      && touch $FIX/photoheads-files-$SIM
  fi
done
[[ -e $FIX/photoheads-files-$SIM ]] || echo "could not put a picture in the simulator's On My iPhone (testP11b_… will skip)"

[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/PhotoHeadsEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/PhotoHeadsEndToEndTests)
[[ -n "$HQN_E2E_ITERATIONS" ]] && ONLY+=(-test-iterations $HQN_E2E_ITERATIONS)
STATUS=0
TEST_RUNNER_HQN_PHOTOHEADS_A=$PWD/$FIX/photoheads-a.json TEST_RUNNER_HQN_PHOTOHEADS_B=$PWD/$FIX/photoheads-b.json \
TEST_RUNNER_HQN_PHOTOHEADS_OLD=$PWD/$FIX/photoheads-old.json TEST_RUNNER_HQN_PHOTOHEADS_MEDIA=$MEDIA \
TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=${HQN_SHOTS_DARK:-0} TEST_RUNNER_HQN_UI_DESKTOPLOOK=${HQN_UI_DESKTOPLOOK:-0} TEST_RUNNER_HQN_IDENTITY=${HQ_IDENTITY:-native} \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
  > build/last-e2e-photoheads.log 2>&1 || STATUS=$?
RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-photoheads.log | tail -30
echo "photoheads e2e: xcodebuild exit $STATUS"
exit $STATUS
