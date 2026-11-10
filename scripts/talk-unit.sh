#!/bin/zsh
# Runs only the live-voice unit suites (Tests/Talk) on the given simulator. Usage: scripts/talk-unit.sh <SIM_UDID> [Suite…]
# With no suite names it runs every suite of Tests/Talk. Derived data stays in ./build/dd (as scripts/build.sh).
# The live fixture suite needs TEST_RUNNER_HQ_TALK_FIXTURE="http://127.0.0.1:<port>|<credentials file>".
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID}; shift || true
[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
SUITES=("$@")
if (( ${#SUITES} == 0 )); then
  SUITES=($(grep -h -o -E '^(struct|final class|class) [A-Za-z0-9_]+Tests' Tests/Talk/*.swift | awk '{print $NF}' | sort -u))
fi
ONLY=()
for suite in $SUITES; do ONLY+=("-only-testing:HermesHQNativeTests/$suite"); done
xcodegen generate -q
mkdir -p build
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd test $ONLY -quiet > build/last-talk-unit.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td build/dd/Logs/Test/Test-HermesHQNative-*.xcresult 2>/dev/null | grep -v 'HermesHQNativeUI' | head -1)
python3 scripts/e2e-summary.py "$RESULT" > build/last-talk-unit.txt 2>/dev/null || true
grep -v -E ': Passed \(' build/last-talk-unit.txt | head -80
echo "$(grep -c ': Passed (' build/last-talk-unit.txt) passed, $(grep -c -E ': (Failed|Expected Failure) \(' build/last-talk-unit.txt) failed (every case: build/last-talk-unit.txt)"
grep -E 'error:' build/last-talk-unit.log | grep -v appintentsmetadataprocessor | head -20
echo "talk unit tests exit $STATUS"; exit $STATUS
