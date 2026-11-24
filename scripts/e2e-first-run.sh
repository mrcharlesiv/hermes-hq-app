#!/bin/zsh
# [first-run] The redrawn first run end to end (UITests/onboarding/FirstRunArrivalEndToEndTests.swift) against the
# onboarding stand-in gateway (scripts/fixtures/onboarding-gateway.py), with -HQFirstRunArrival YES. Modelled on
# scripts/e2e-onboarding.sh.
# Usage: scripts/e2e-first-run.sh <SIM_UDID>
#   One password fixture on 127.0.0.1:9992 (HQN_ONBOARDING_PORTS="A" moves it; the first port is used). Refuses a busy
#   port; credentials go to build/fixtures/first-run-a.json (0600, never printed) and reach the runner as
#   TEST_RUNNER_HQN_ONBOARDING_A. Screenshots land in build/first-run/shots (HQN_UI_SHOTS moves them) as
#   <light|dark>-<n>-<name>.png, named as the mock's are. HQN_FIRST_RUN_PASSES="light dark" (default) runs once per
#   appearance. HQN_E2E_ONLY="testPath,testFilm" picks tests (default testPath). HQN_FIRST_RUN_FILM=1 records the
#   simulator's screen during testFilm to build/first-run/shots/film-<pass>.mov. Only what this script started is stopped.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-$HQ_SIM}
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-first-run.sh <SIM_UDID> (no default simulator: this Mac is shared)"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/first-run/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

read -r PA _ <<< "${HQN_ONBOARDING_PORTS:-9992}"
if lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PA is busy; stop it first"; exit 1; fi
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/first-run-a.json
python3 scripts/fixtures/onboarding-gateway.py --port $PA --credentials $FIX/first-run-a.json > $FIX/first-run-a.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/first-run-a.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 || { echo "fixture did not start (see $FIX/first-run-a.log)"; exit 1; }
echo "first-run fixture on 127.0.0.1:$PA (pid $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)${HQN_E2E_ONLY:-testPath}}; do ONLY+=(-only-testing:HermesHQNativeUITests/FirstRunArrivalEndToEndTests/$t); done
STATUS=0
for PASS in ${=HQN_FIRST_RUN_PASSES:-light dark}; do
  DARK=0; [[ $PASS == dark ]] && DARK=1
  PASS_STATUS=0
  REC=""
  if [[ -n "$HQN_FIRST_RUN_FILM" ]]; then
    xcrun simctl io $SIM recordVideo --force $SHOTS/film-$PASS.mov >/dev/null 2>&1 &
    REC=$!
    PIDS+=($REC)
  fi
  TEST_RUNNER_HQN_ONBOARDING_A=$PWD/$FIX/first-run-a.json \
  TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=$DARK \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
    > build/first-run/last-e2e-first-run-$PASS.log 2>&1 || PASS_STATUS=$?
  [[ -n "$REC" ]] && { kill -INT $REC 2>/dev/null || true; wait $REC 2>/dev/null || true; }
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  echo "== $PASS pass =="
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/first-run/last-e2e-first-run-$PASS.log | tail -30
  echo "first-run e2e ($PASS): xcodebuild exit $PASS_STATUS"
  [[ $PASS_STATUS -eq 0 ]] || STATUS=$PASS_STATUS
done
exit $STATUS
