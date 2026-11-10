#!/bin/zsh
# End-to-end UI tests for photos and files (UITests/attachments/AttachmentsEndToEndTests.swift) against the
# attachments fixture (scripts/fixtures/attachments-gateway.py; docs/spec/1x-attachments.md §14, §15.2).
# Usage: scripts/e2e-attachments.sh [SIM_UDID] [RUNS]
#   Starts the fixture on 127.0.0.1:$HQN_ATTACH_PORT (default 9723; refuses a busy port; this stream owns 9723-9725),
#   writes its invented credentials to build/fixtures/attach.json (0600, never printed), copies the test media to
#   build/fixtures/attach-media (plus a 33 MB file and 17 small ones for the limits), grants the app add-only Photos
#   access, runs AttachmentsEndToEndTests RUNS times (default 1), saves screenshots under .build/shots/, and stops only
#   the fixture it started. HQN_ATTACH_ONLY="test01_…,test05_…" runs only those tests.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-${HQ_SIM:-4305E619-02F9-4139-AADB-708D3F932DE7}}
RUNS=${2:-1}
PORT=${HQN_ATTACH_PORT:-9723}
FIX=$PWD/build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/shots}
MEDIA=$FIX/attach-media
mkdir -p $FIX $SHOTS && chmod 700 $FIX

# HQN_ANY_PORT=1: another range (integration runs every suite on its own ports).
if [[ -z "$HQN_ANY_PORT" ]] && (( PORT < 9723 || PORT > 9725 )); then echo "use a port in 9723-9725 (this stream's)"; exit 1; fi
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is already in use; set HQN_ATTACH_PORT to a free port in 9723-9725"; exit 1
fi

rm -rf $MEDIA && mkdir -p $MEDIA && chmod 700 $MEDIA
cp UITests/Fixtures/attachments/* $MEDIA/
dd if=/dev/zero of=$MEDIA/big.bin bs=1048576 count=101 2>/dev/null
for i in $(seq -w 1 17); do printf 'note %s\n' $i > $MEDIA/note-$i.txt; done

rm -f $FIX/attach.json
python3 scripts/fixtures/attachments-gateway.py --port $PORT --credentials $FIX/attach.json --files $FIX/attach-files \
  > $FIX/attach.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $FIXTURE_PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do
  [[ -s $FIX/attach.json ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
[[ -s $FIX/attach.json ]] || { echo "fixture did not start (see $FIX/attach.log)"; exit 1; }
echo "attachments fixture on 127.0.0.1:$PORT (pid $FIXTURE_PID)"

xcrun simctl bootstatus $SIM -b >/dev/null 2>&1 || true
xcrun simctl privacy $SIM grant photos-add com.charlesmcdowell.hermeshq.native >/dev/null 2>&1 || true

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q   # integration: parallel suites share one project
ONLY=()
if [[ -n "$HQN_ATTACH_ONLY" ]]; then
  for t in ${(s:,:)HQN_ATTACH_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/AttachmentsEndToEndTests/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/AttachmentsEndToEndTests)
fi
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$FIX/attach.json TEST_RUNNER_HQN_UI_FIXTURE_URL=http://127.0.0.1:$PORT \
  TEST_RUNNER_HQN_ATTACH_MEDIA=$MEDIA TEST_RUNNER_HQN_UI_SHOTS=$SHOTS \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ${HQN_DD:-build/dd} test -quiet $ONLY \
    > build/last-e2e-attachments-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-attachments-$run.log | tail -20
  echo "e2e-attachments run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
