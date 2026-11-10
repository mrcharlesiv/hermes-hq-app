#!/bin/zsh
# ui-sizing audit (2026-11-09): one picture of every screen the -HQDebugTour hook reaches, iOS look, default skin.
# Usage: scripts/ui-sizing-tour.sh <udid> <out dir> [screen-name…]
#   HQN_TOUR_MODE=dark|light (default dark)   HQN_TOUR_EXTRA="-HQDebugUIScale 1.3"   HQN_TOUR_PORTS="10160 10161"
#   Starts its own groups + pages stand-in gateways and stops only what it started. Needs a Debug build in build/dd.
set -e
cd "$(dirname "$0")/.."
U=$1; OUT=$2; shift 2
[[ -n "$U" && -n "$OUT" ]] || { echo "usage: scripts/ui-sizing-tour.sh <udid> <out dir> [name…]"; exit 2; }
MODE=${HQN_TOUR_MODE:-dark}
read -r PG PP <<< "${HQN_TOUR_PORTS:-10160 10161}"
FIX=build/fixtures/uisz-$PG
mkdir -p $FIX $OUT && chmod 700 $FIX
for port in $PG $PP; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT
trap 'exit 130' INT TERM   # a stop ends the tour (the EXIT trap still stops its gateways)
rm -f $FIX/groups.json $FIX/pages.json
python3 scripts/fixtures/groups-gateway.py --port $PG --credentials $FIX/groups.json > $FIX/groups.log 2>&1 &
PIDS+=($!)
python3 scripts/pages-fixture-gateway.py --port $PP --credentials $FIX/pages.json --files $FIX/files --tick-seconds 0 > $FIX/pages.log 2>&1 &
PIDS+=($!)
for i in {1..80}; do [[ -s $FIX/groups.json && -s $FIX/pages.json ]] && break; sleep 0.25; done
[[ -s $FIX/pages.json ]] || { echo "fixtures did not start"; exit 1; }

# name | tour screen | fixture (g/p) | extra launch arguments
SHOTS=(
  "01-bots|bots|g|"
  "02-sessions|sessions|g|"
  "03-chat|chat|g|"
  "04-chat-focus|focus|g|"
  "05-room|room|g|"
  "06-newchat|newchat|g|"
  "07-account|account|g|"
  "10-botinfo-about|botinfo|g|-HQDebugTourItem about"
  "11-botinfo-brain|botinfo|g|-HQDebugTourItem brain"
  "12-botinfo-chats|botinfo|g|-HQDebugTourItem chats"
  "13-botinfo-artifacts|botinfo|g|-HQDebugTourItem artifacts"
  "14-botinfo-settings|botinfo|g|-HQDebugTourItem settings"
  "15-editbot|editbot|g|"
  "17-botinfo-scrolled|botinfo|g|-HQDebugTourScroll 320"
  "16-changeface|changeface|g|"
  "20-chatinfo|chatinfo|g|"
  "21-commands|commands|g|"
  "22-models|models|g|"
  "23-prompts|prompts|g|"
  "24-prompteditor|prompteditor|g|"
  "25-errordetails|errordetails|g|"
  "26-talkinfo|talkinfo|g|"
  "27-glassdock|glassdock|g|"
  "28-glasstray|glasstray|g|-HQDebugAttach YES"
  "29-promptsheet|promptsheet|g|"
  "30-screensetup|screensetup|g|"
  "31-audiopreview|audiopreview|g|"
  "32-htmlstatus|htmlstatus|g|"
  "40-more|more|g|"
  "41-more-scrolled|morescrolled|g|"
  "42-connectors|connectors|g|"
  "43-plugins|plugins|g|"
  "44-secretkey|secretkey|g|"
  "45-starnode|starnode|g|"
  "50-settings|settings|g|"
  "51-settings-model|settings-model|g|"
  "52-settings-context|settings-context|g|"
  "53-settings-providers|settings-providers|g|"
  "54-settings-provider|settings-provider|g|"
  "55-settings-providers-add|settings-providers-add|g|"
  "56-theme|theme|g|"
  "57-theme-chats|theme|g|-HQDebugTourItem chats"
  "58-theme-backgrounds|theme|g|-HQDebugTourItem backgrounds"
  "60-jobs|jobs|p|"
  "61-tab3|tab3|p|"
  "62-kanban-newtask|sheet|p|"
  "63-kanban-task|task|p|"
  "64-kanbanabout|kanbanabout|p|"
)
for r in 0 1 2 3 4 5 6; do for i in 0 1 2 3 4 5 6 7 8 9; do SHOTS+=("7$r-morepage-$r-$i|morepage|p|-HQDebugTourItem $r,$i"); done; done

APP=build/dd/Build/Products/Debug-iphonesimulator/HermesHQNative.app
BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun simctl install $U "$APP"   # once: reinstalling 200+ MB per shot made each picture take a minute
shot() {   # out.png credentials.json launch-arguments…
  local out=$1 cred=$2; shift 2
  xcrun simctl terminate $U $BID >/dev/null 2>&1 || true
  eval $(python3 -c "
import json,sys,shlex
c=json.load(open(sys.argv[1]))
print('export SIMCTL_CHILD_HQN_SIGNIN_URL=%s SIMCTL_CHILD_HQN_SIGNIN_USERNAME=%s SIMCTL_CHILD_HQN_SIGNIN_PASSWORD=%s' % tuple(shlex.quote(c[k]) for k in ('url','username','password')))
" "$cred")
  xcrun simctl launch $U $BID "$@" >/dev/null
  sleep ${HQN_SHOT_WAIT:-7}
  xcrun simctl io $U screenshot "$out" >/dev/null 2>&1
}
WANT=("$@")
for s in $SHOTS; do
  IFS='|' read -r name screen fx extra <<< "$s"
  if (( ${#WANT} )); then (( ${WANT[(Ie)$name]} )) || continue; fi
  cred=$FIX/groups.json; [[ $fx == p ]] && cred=$FIX/pages.json
  [[ -n "$HQN_TOUR_SKIP_DONE" && -s $OUT/$name.png ]] && continue
  shot $OUT/$name.png $cred \
    -HQDebugResetAccounts YES -HQDebugResetTheme YES -HQDebugDesktopLook NO \
    -HQDebugAppearance $MODE -hqn.appearance $MODE -HQDebugTour $screen -HQDebugNoSwipePeek YES -HQDebugTalkIntroSeen YES \
    ${=extra} ${=HQN_TOUR_EXTRA} >/dev/null || echo "failed: $name"
  echo "$OUT/$name.png"
done
