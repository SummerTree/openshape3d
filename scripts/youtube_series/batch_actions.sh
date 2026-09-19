#!/bin/zsh
# Record + compose several CAD-action videos in a row: batch_actions.sh fillet chamfer …
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export OS3D_VIDEO_OUT=${OS3D_VIDEO_OUT:-/Users/thelodgestudio/projects/openshape3d/marketing/youtube}
cd "$(dirname "$0")"
for v in "$@"; do
  echo "=== $v $(date +%H:%M:%S)"
  python3 action_tutorial.py $v > take-action-$v.log 2>&1 && echo "ok $v" || { echo "FAILED $v"; grep -E "Missed|Error" take-action-$v.log | tail -2; }
done
echo "=== batch done $(date +%H:%M:%S)"
