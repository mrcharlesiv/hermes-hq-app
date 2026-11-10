#!/bin/zsh
# [onboarding] End-to-end UI tests (UITests/onboarding/) against the onboarding stand-in gateway
# (scripts/fixtures/onboarding-gateway.py; docs/spec/3x-onboarding.md §9.2).
# Usage: scripts/e2e-onboarding.sh <SIM_UDID>
#   Two password fixtures: A on 127.0.0.1:9990, B on 9991 (--label Beta); HQN_ONBOARDING_PORTS="A B" moves them.
#   Refuses busy ports; credentials go to build/fixtures/onboarding-*.json (0600, never printed) and reach the runner
#   as TEST_RUNNER_HQN_ONBOARDING_A / _B; screenshots land in build/shots (HQN_UI_SHOTS moves them) as
#   onboarding-<nn>-<name>-{light,dark}.png. Only the fixtures this script started are stopped.
#   HQN_E2E_ONLY="testO01_…,testO11_…" runs only those tests. HQN_ONBOARDING_PASSES="light dark" (default) runs the
#   suite once per appearance; "light" alone is the quick run.
set -e
cd "$(dirname "$0")/.."
SIM=${1:-$HQ_SIM}
[[ -n "$SIM" ]] || { echo "usage: scripts/e2e-onboarding.sh <SIM_UDID> (no default simulator: this Mac is shared)"; exit 2; }
FIX=build/fixtures
SHOTS=${HQN_UI_SHOTS:-$PWD/build/shots}
mkdir -p $FIX $SHOTS && chmod 700 $FIX

read -r PA PB <<< "${HQN_ONBOARDING_PORTS:-9990 9991}"
for port in $PA $PB; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy; stop it first"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/onboarding-a.json $FIX/onboarding-b.json
python3 scripts/fixtures/onboarding-gateway.py --port $PA --credentials $FIX/onboarding-a.json > $FIX/onboarding-a.log 2>&1 &
PIDS+=($!)
python3 scripts/fixtures/onboarding-gateway.py --port $PB --label Beta --credentials $FIX/onboarding-b.json > $FIX/onboarding-b.log 2>&1 &
PIDS+=($!)
for i in {1..60}; do
  [[ -s $FIX/onboarding-a.json && -s $FIX/onboarding-b.json ]] && lsof -nP -iTCP:$PA -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.2
done
lsof -nP -iTCP:$PB -sTCP:LISTEN >/dev/null 2>&1 || { echo "fixtures did not start (see $FIX/onboarding-*.log)"; exit 1; }
echo "onboarding fixtures on 127.0.0.1:$PA and :$PB (pids $PIDS)"

[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
for t in ${(s:,:)HQN_E2E_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/OnboardingEndToEndTests/$t); done
[[ ${#ONLY} -eq 0 ]] && ONLY=(-only-testing:HermesHQNativeUITests/OnboardingEndToEndTests)
STATUS=0
for PASS in ${=HQN_ONBOARDING_PASSES:-light dark}; do
  DARK=0; [[ $PASS == dark ]] && DARK=1
  PASS_STATUS=0
  TEST_RUNNER_HQN_ONBOARDING_A=$PWD/$FIX/onboarding-a.json TEST_RUNNER_HQN_ONBOARDING_B=$PWD/$FIX/onboarding-b.json \
  TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_SHOTS_DARK=$DARK \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
    -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet $ONLY \
    > build/last-e2e-onboarding-$PASS.log 2>&1 || PASS_STATUS=$?
  RESULT=$(ls -td ${HQN_DD:-build/dd}/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  echo "== $PASS pass =="
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-onboarding-$PASS.log | tail -30
  echo "onboarding e2e ($PASS): xcodebuild exit $PASS_STATUS"
  [[ $PASS_STATUS -eq 0 ]] || STATUS=$PASS_STATUS
done
exit $STATUS
