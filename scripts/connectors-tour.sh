#!/bin/zsh
# [connectors-ux] Pictures of More › Connectors and the pages under it, in both looks, against a running stand-in
# (scripts/fixtures/connectors-gateway.py). One picture per stop, scrolled down the list, into
# build/connectors-tour/<label>/<page>-<scroll>-look<on|off>-<mode>.png.
# Usage: scripts/connectors-tour.sh <udid> <credentials.json> <label> [page…]
#   page: list (the Connectors list, at each HQN_TOUR_SCROLLS offset) or the name of a connector, catalog app or
#   managed app (its page, at the top).  HQN_TOUR_LOOKS="on off"  HQN_TOUR_MODES="light dark"  HQN_TOUR_SCROLLS="0 700 1400"
set -e
cd "$(dirname "$0")/.."
U=$1; CRED=$2; LABEL=$3; shift 3
[[ -n "$LABEL" ]] || { echo "usage: scripts/connectors-tour.sh <udid> <credentials.json> <label> [page…]"; exit 2; }
PAGES=(${@:-list})
LOOKS=(${=HQN_TOUR_LOOKS:-on off})
MODES=(${=HQN_TOUR_MODES:-light dark})
SCROLLS=(${=HQN_TOUR_SCROLLS:-0 700 1400 2100})
OUT=build/connectors-tour/$LABEL
mkdir -p $OUT
for look in $LOOKS; do
  flag=$([[ $look == on ]] && echo YES || echo NO)
  for mode in $MODES; do
    for page in $PAGES; do
      if [[ $page == list ]]; then stops=($SCROLLS); item=(); else stops=(0); item=(-HQDebugTourItem $page); fi
      for y in $stops; do
        scroll=(); [[ $y != 0 ]] && scroll=(-HQDebugTourScroll $y)
        HQN_SHOT_WAIT=${HQN_SHOT_WAIT:-8} scripts/desktoplook-shots.sh $U $OUT/$page-$y-look$look-$mode.png $CRED -- \
          -HQDebugResetAccounts YES -HQDebugResetTheme YES -HQDebugDesktopLook $flag \
          -HQDebugAppearance $mode -hqn.appearance $mode -HQDebugTour connectors $item $scroll -HQDebugNoSwipePeek YES \
          -HQDebugTalkIntroSeen YES ${=HQN_TOUR_EXTRA} >/dev/null
        echo "$OUT/$page-$y-look$look-$mode.png"
      done
    done
  done
done
