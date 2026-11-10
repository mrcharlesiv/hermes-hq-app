#!/bin/zsh
# Runs only the transcript stream unit suites (Tests/Chat/Transcript) on the given simulator. Usage: scripts/talk-unit.sh <SIM_UDID> [Suite…]
# With no suite names it runs every suite of Tests/Chat/Transcript. Derived data stays in ./build/dd (as scripts/build.sh).
set -e
cd "$(dirname "$0")/.."
SIM=${1:?simulator UDID}; shift || true
[[ ${HQ_IDENTITY:-native} == original ]] && export HQ_ORIGINAL=YES || unset HQ_ORIGINAL
SUITES=("$@")
if (( ${#SUITES} == 0 )); then
  SUITES=($(grep -h -o -E '(struct|final class|class) [A-Za-z0-9_]+Tests' Tests/Chat/Transcript/*.swift | awk '{print $NF}' | sort -u))
fi
ONLY=()
for suite in $SUITES; do ONLY+=("-only-testing:HermesHQNativeTests/$suite"); done
xcodegen generate -q
mkdir -p build
xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNative -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build/dd test $ONLY -quiet > build/last-transcript-unit.log 2>&1 && STATUS=0 || STATUS=$?
RESULT=$(ls -td build/dd/Logs/Test/Test-HermesHQNative-*.xcresult 2>/dev/null | grep -v 'HermesHQNativeUI' | head -1)
python3 scripts/e2e-summary.py "$RESULT" > build/last-transcript-unit.txt 2>/dev/null || true
grep -v -E ': Passed \(' build/last-transcript-unit.txt | head -80
echo "$(grep -c ': Passed (' build/last-transcript-unit.txt) passed, $(grep -c -E ': (Failed|Expected Failure) \(' build/last-transcript-unit.txt) failed (every case: build/last-transcript-unit.txt)"
grep -E 'error:' build/last-transcript-unit.log | grep -v appintentsmetadataprocessor | head -20
echo "transcript unit tests exit $STATUS"; exit $STATUS
