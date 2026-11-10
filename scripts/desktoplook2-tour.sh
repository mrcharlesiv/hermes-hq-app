#!/bin/zsh
# desktoplook2: screenshots of every screen, look on and off, light and dark, into build/shots/desktoplook2/.
# Usage: scripts/desktoplook2-tour.sh <udid> [skin…]          (default skins: midnight)
#   HQN_TOUR_LOOKS="on off"  HQN_TOUR_MODES="dark light"  HQN_TOUR_SCREENS="bots sessions …"  HQN_TOUR_PORTS="10060 10061"
#   HQN_TOUR_EXTRA="-HQDebugTourDetent large"  more launch arguments for every shot
#   Starts its own stand-in gateways (groups fixture: bots, sections, a room, chats; pages fixture: Jobs and Kanban)
#   on the given ports, refuses busy ones, and stops only what it started. Needs a Debug build in build/dd.
set -e
cd "$(dirname "$0")/.."
U=$1; shift
[[ -n "$U" ]] || { echo "usage: scripts/desktoplook2-tour.sh <udid> [skin…]"; exit 2; }
SKINS=(${@:-midnight})
LOOKS=(${=HQN_TOUR_LOOKS:-on off})
MODES=(${=HQN_TOUR_MODES:-dark light})
SCREENS=(${=HQN_TOUR_SCREENS:-bots sessions chat room botinfo editbot more morepage settings theme jobs tab3})
read -r PG PP <<< "${HQN_TOUR_PORTS:-10060 10061}"
OUT=${HQN_TOUR_OUT:-build/shots/desktoplook2}
FIX=build/fixtures/tour
mkdir -p $FIX $OUT && chmod 700 $FIX
for port in $PG $PP; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "port $port is busy"; exit 1; fi
done
PIDS=()
trap 'for p in $PIDS; do kill $p 2>/dev/null || true; done' EXIT INT TERM
rm -f $FIX/groups.json $FIX/pages.json
python3 scripts/fixtures/groups-gateway.py --port $PG --credentials $FIX/groups.json > $FIX/groups.log 2>&1 &
PIDS+=($!)
python3 scripts/pages-fixture-gateway.py --port $PP --credentials $FIX/pages.json --files $FIX/files --tick-seconds 0 > $FIX/pages.log 2>&1 &
PIDS+=($!)
for i in {1..80}; do [[ -s $FIX/groups.json && -s $FIX/pages.json ]] && break; sleep 0.25; done
[[ -s $FIX/pages.json ]] || { echo "fixtures did not start"; exit 1; }
for skin in $SKINS; do
  for look in $LOOKS; do
    flag=$([[ $look == on ]] && echo YES || echo NO)
    for mode in $MODES; do
      for screen in $SCREENS; do
        cred=$FIX/groups.json
        [[ $screen == jobs || $screen == tab3 || $screen == sheet ]] && cred=$FIX/pages.json
        wait=${HQN_SHOT_WAIT:-8}
        HQN_SHOT_WAIT=$wait scripts/desktoplook-shots.sh $U $OUT/$screen-$skin-look$look-$mode.png $cred -- \
          -HQDebugResetAccounts YES -HQDebugResetTheme YES -HQDebugSkin $skin -HQDebugDesktopLook $flag \
          -HQDebugAppearance $mode -hqn.appearance $mode -HQDebugTour $screen -HQDebugNoSwipePeek YES -HQDebugTalkIntroSeen YES ${=HQN_TOUR_EXTRA} >/dev/null
        echo "$OUT/$screen-$skin-look$look-$mode.png"
      done
    done
  done
done
