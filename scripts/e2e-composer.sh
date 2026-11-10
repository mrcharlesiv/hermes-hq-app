#!/bin/zsh
# [m9/composer] End-to-end UI tests of the composer stream (UITests/composer/ComposerUITests.swift) against its
# stand-in gateway (scripts/fixtures/composer-gateway.py, docs/spec/3x-composer.md §18).
# Usage: scripts/e2e-composer.sh <SIM_UDID> [RUNS]
#   Starts the fixture on 127.0.0.1:${HQN_COMPOSER_PORT:-10030} (refusing a busy port: it never talks to a port it did
#   not open), writes its invented credentials to build/fixtures/composer-<port>.json (0600, never printed), passes
#   them to the runner as TEST_RUNNER_HQN_UI_CREDENTIALS and the screenshot folder as TEST_RUNNER_HQN_SHOTS_DIR
#   (default build/shots/composer), runs ComposerUITests RUNS times and stops only the fixture it started (by PID).
#   HQN_COMPOSER_ONLY="test1_…,test4_…" narrows the run. HQN_COMPOSER_DARK=1 runs in dark. Derived data: ${HQN_DD:-build/dd}.
#   HQ_IDENTITY=original runs against the shipped identity's project.
#   Use this stream's own simulator (HQN-m9-composer; the stress tester uses HQN-m9-composer-s). Never the default one.
set -e
cd "$(dirname "$0")/.."
SIM=${1:?usage: scripts/e2e-composer.sh <SIM_UDID> [RUNS]}
RUNS=${2:-1}
PORT=${HQN_COMPOSER_PORT:-10030}
FIX=build/fixtures
SHOTS=${HQN_SHOTS_DIR:-$PWD/build/shots/composer}
[[ $SHOTS == /* ]] || SHOTS=$PWD/$SHOTS
DD=${HQN_DD:-build/dd}
mkdir -p $FIX $SHOTS && chmod 700 $FIX
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is already in use; set HQN_COMPOSER_PORT"; exit 1; fi
CRED=$FIX/composer-$PORT.json
rm -f $CRED
# HQN_COMPOSER_FIXTURE=questions: the questions stand-in (approval cards) for ComposerApprovalUITests instead.
SCRIPT=scripts/fixtures/composer-gateway.py
SUITE=ComposerUITests
if [[ ${HQN_COMPOSER_FIXTURE:-} == questions ]]; then
  SCRIPT=scripts/fixtures/questions-gateway.py; SUITE=ComposerApprovalUITests; export TEST_RUNNER_HQN_UI_QUESTIONS=1
fi
python3 $SCRIPT --port $PORT --credentials $CRED > $FIX/composer-$PORT.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT INT TERM
for i in {1..50}; do [[ -s $CRED ]] && lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.2; done
[[ -s $CRED ]] || { echo "the fixture did not start (see $FIX/composer-$PORT.log)"; exit 1; }
echo "composer fixture on 127.0.0.1:$PORT (pid $PID)"

[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
[[ -n "$HQN_SKIP_XCODEGEN" ]] || xcodegen generate -q
ONLY=()
if [[ -n "$HQN_COMPOSER_ONLY" ]]; then
  for t in ${(s:,:)HQN_COMPOSER_ONLY}; do ONLY+=(-only-testing:HermesHQNativeUITests/$SUITE/$t); done
else
  ONLY=(-only-testing:HermesHQNativeUITests/$SUITE)
fi
xcrun simctl bootstatus $SIM -b >/dev/null 2>&1 || true
xcrun simctl ui $SIM appearance ${${HQN_COMPOSER_DARK:+dark}:-light} >/dev/null 2>&1 || true
FAILED=0
for run in $(seq 1 $RUNS); do
  TEST_RUNNER_HQN_UI_CREDENTIALS=$PWD/$CRED TEST_RUNNER_HQN_SHOTS_DIR=$SHOTS \
    xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath $DD test -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 $ONLY > build/last-e2e-composer-$PORT-$run.log 2>&1 && STATUS=0 || STATUS=$?
  RESULT=$(ls -td $DD/Logs/Test/Test-HermesHQNativeUI-*.xcresult | head -1)
  python3 scripts/e2e-summary.py "$RESULT" || grep -E "error:|failed" build/last-e2e-composer-$PORT-$run.log | tail -20
  echo "e2e-composer run $run/$RUNS: xcodebuild exit $STATUS"
  [[ $STATUS -eq 0 ]] || FAILED=1
done
exit $FAILED
