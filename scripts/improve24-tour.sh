#!/bin/zsh
# improve-24: the survey's screenshots (docs/briefs/improve-24.md). One picture per screen and look, through the
# stand-in gateways the brief names, into build/improve/tour/<screen>-look<on|off>-<mode>.png.
# Usage: scripts/improve24-tour.sh <udid> [screen…]
#   HQN_TOUR_LOOKS="on off"  HQN_TOUR_MODES="light"  HQN_IMPROVE_FIX=build/fixtures/improve  HQN_TOUR_EXTRA="-x y"
#   Screens (see App/Debug/DesktopLookTourHooks.swift): bots sessions chat room botinfo editbot more settings theme
#   jobs tab3 chatinfo commands newchat focus, and morepage:<section,item> (a More row pushed).
#   Gateways must already run (see the brief): groups.json for most screens, morepages.json for jobs/tab3/morepage.
set -e
cd "$(dirname "$0")/.."
U=$1; shift
[[ -n "$U" ]] || { echo "usage: scripts/improve24-tour.sh <udid> [screen…]"; exit 2; }
SCREENS=(${@:-bots sessions chat room botinfo editbot more settings theme jobs tab3 chatinfo commands newchat focus})
LOOKS=(${=HQN_TOUR_LOOKS:-on off})
MODES=(${=HQN_TOUR_MODES:-light})
FIX=${HQN_IMPROVE_FIX:-build/fixtures/improve}
OUT=${HQN_TOUR_OUT:-build/improve/tour}
mkdir -p $OUT
for look in $LOOKS; do
  flag=$([[ $look == on ]] && echo YES || echo NO)
  for mode in $MODES; do
    for screen in $SCREENS; do
      cred=$FIX/groups.json; extra=()
      name=$screen
      case $screen in
        jobs|tab3) cred=$FIX/morepages.json ;;
        morepage:*) cred=$FIX/morepages.json; item=${screen#morepage:}; screen=morepage; extra=(-HQDebugTourItem $item)
                    name=morepage-${item/,/-} ;;
      esac
      HQN_SHOT_WAIT=${HQN_SHOT_WAIT:-9} scripts/desktoplook-shots.sh $U $OUT/$name-look$look-$mode.png $cred -- \
        -HQDebugResetAccounts YES -HQDebugResetTheme YES -HQDebugDesktopLook $flag \
        -HQDebugAppearance $mode -hqn.appearance $mode -HQDebugTour $screen -HQDebugNoSwipePeek YES \
        -HQDebugTalkIntroSeen YES $extra ${=HQN_TOUR_EXTRA} >/dev/null
      echo "$OUT/$name-look$look-$mode.png"
    done
  done
done
