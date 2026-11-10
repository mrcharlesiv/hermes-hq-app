#!/bin/zsh
# desktoplook2: a contact sheet of screenshots (ffmpeg xstack). Usage:
#   scripts/desktoplook2-sheet.sh <out.png> <columns> <shot.png>…      (each shot scaled to 402 pt wide)
set -e
OUT=$1; COLS=$2; shift 2
FILES=("$@")
N=${#FILES}
W=${HQN_SHEET_W:-402}
INPUTS=(); FILTER=""; LAYOUT=""
for i in {1..$N}; do
  INPUTS+=(-i "${FILES[$i]}")
  FILTER+="[$((i-1)):v]scale=${W}:-2,pad=${W}+8:ih+8:4:4:gray[s$((i-1))];"
done
H=$(( W * 2622 / 1206 + 8 ))
for i in {0..$((N-1))}; do
  c=$(( i % COLS )); r=$(( i / COLS ))
  LAYOUT+="$(( c * (W + 8) ))_$(( r * H ))|"
done
LAYOUT=${LAYOUT%|}
for i in {0..$((N-1))}; do FILTER+="[s$i]"; done
FILTER+="xstack=inputs=${N}:layout=${LAYOUT}:fill=gray"
ffmpeg -loglevel error -y "${INPUTS[@]}" -filter_complex "$FILTER" -frames:v 1 "$OUT"
echo "$OUT"
