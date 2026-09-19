#!/bin/zsh
# Record + compose the YouTube Shorts one after another (a failed take moves on).
#   batch_shorts.sh [key …]   (default: all ten)
cd "$(dirname "$0")"
export OS3D_VIDEO_OUT=${OS3D_VIDEO_OUT:-$(git rev-parse --path-format=absolute --git-common-dir)/../marketing/youtube}
keys=($@)
(( $# )) || keys=(spring vase donut bowl nut loft pipe gem frame ring)
for k in $keys; do
  echo "=== $k $(date +%H:%M:%S)"
  python3 shorts.py $k > take-short-$k.log 2>&1 && echo "OK $k" || { echo "FAILED $k"; tail -3 take-short-$k.log; }
done
echo "=== batch done $(date +%H:%M:%S)"
