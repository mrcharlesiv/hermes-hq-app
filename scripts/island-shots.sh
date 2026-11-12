#!/bin/zsh
# [island-fit] Photographs the Dynamic Island's small views in every shape (UITests/live/IslandFitTests.swift).
# Usage: scripts/island-shots.sh [SIM_UDID]   (HQN_ISLAND_SPECS="turn:970;turn:970,talk:30" for a few; shots: .build/island)
# Builds the Hermes HQ identity: only it carries the widget extension.
set -e
cd "$(dirname "$0")/.."
[[ -z $DEVELOPER_DIR && -d /Applications/Xcode-27.2.app ]] && export DEVELOPER_DIR=/Applications/Xcode-27.2.app/Contents/Developer
SIM=${1:-${HQ_SIM:?a simulator UDID}}
SHOTS=${HQN_UI_SHOTS:-$PWD/.build/island}
mkdir -p $SHOTS build
# The other app whose activity shares the island in the "twin" cases.
(cd TestSupport/IslandTwin && xcodegen generate -q && xcodebuild -project Twin.xcodeproj -scheme Twin \
  -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath ../../build/island-twin build -quiet) > build/last-island-twin.log 2>&1
xcrun simctl install $SIM build/island-twin/Build/Products/Debug-iphonesimulator/Twin.app
export HQ_ORIGINAL=YES
xcodegen generate -q
STATUS=0
TEST_RUNNER_HQN_SHOTS=$SHOTS TEST_RUNNER_HQN_ISLAND_SPECS=$HQN_ISLAND_SPECS \
  xcodebuild -project HermesHQNative.xcodeproj -scheme HermesHQNativeUI -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath ${HQN_DD:-build/dd} -parallel-testing-enabled NO -collect-test-diagnostics never test -quiet \
  -only-testing:HermesHQNativeUITests/IslandFitTests > build/last-island-shots.log 2>&1 || STATUS=$?
grep -E "error:|failed" build/last-island-shots.log | tail -20
# Each shot's top strip, with nothing else to look at.
python3 - "$SHOTS" <<'PY'
import glob, os, sys
from PIL import Image
# One sheet: each case's island, the island held open, and its card in Notification Center.
rows = []
for path in sorted(glob.glob(os.path.join(sys.argv[1], "island-*.png"))):
    if path.endswith(("-open.png", "-lock.png")): continue
    parts = []
    for suffix, top, bottom in (("", 0, 0.07), ("-open", 0, 0.2), ("-lock", 0.7, 0.9)):   # the card sits low
        other = path[:-4] + suffix + ".png"
        if not os.path.exists(other): continue
        im = Image.open(other).convert("RGB")
        part = im.crop((0, int(im.height * top), im.width, int(im.height * bottom)))
        parts.append(part.resize((part.width // 2, part.height // 2)))
    row = Image.new("RGB", (sum(p.width for p in parts) + 8 * len(parts), max(p.height for p in parts)), "white")
    x = 0
    for p in parts:
        row.paste(p, (x, 0)); x += p.width + 8
    rows.append(row)
if rows:
    sheet = Image.new("RGB", (max(r.width for r in rows), sum(r.height + 8 for r in rows)), "white")
    y = 0
    for r in rows:
        sheet.paste(r, (0, y)); y += r.height + 8
    sheet.save(os.path.join(sys.argv[1], "sheet.png"))
PY
echo "island shots: xcodebuild exit $STATUS, in $SHOTS"
exit $STATUS
