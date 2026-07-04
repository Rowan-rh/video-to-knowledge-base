#!/bin/bash
# extract_frames.sh — 抽关键帧（场景切换 + 间隔保底），时间戳嵌入文件名
# 用法：./extract_frames.sh <video> <frames_dir> [scene_threshold=0.25] [tick_seconds=90]
set -e
VIDEO="$1"
OUT_DIR="$2"
SCENE_TH="${3:-0.25}"
TICK_S="${4:-90}"

if [ -z "$VIDEO" ] || [ -z "$OUT_DIR" ]; then
  echo "用法：$0 <video.mp4> <frames_dir> [scene_threshold=0.25] [tick_seconds=90]" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

echo "=== 场景切换抽帧（阈值 $SCENE_TH）==="
ffmpeg -hide_banner -loglevel info -y \
  -i "$VIDEO" -vf "select='gt(scene,$SCENE_TH)'" \
  -vsync vfr -frame_pts true -q:v 3 \
  "$OUT_DIR/scene_%015d.000000.jpg" \
  2> "$OUT_DIR/.scene_showinfo.log"
SCENE_COUNT=$(ls "$OUT_DIR"/scene_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "  → $SCENE_COUNT 张场景帧"

echo ""
echo "=== 间隔保底抽帧（每 $TICK_S 秒）==="
ffmpeg -hide_banner -loglevel error -y \
  -i "$VIDEO" -vf "fps=1/$TICK_S" \
  -frame_pts true -q:v 3 \
  "$OUT_DIR/tick_%015d.000000.jpg" 2>&1 | tail -3
TICK_COUNT=$(ls "$OUT_DIR"/tick_*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "  → $TICK_COUNT 张保底帧"

# 解析时间戳并保存（用 quoted heredoc + 环境变量，防止 shell 注入）
OUT_DIR_FOR_PY="$OUT_DIR" TICK_S_FOR_PY="$TICK_S" python3 << 'PY'
import re, json, os
from pathlib import Path

OUT = Path(os.environ["OUT_DIR_FOR_PY"])
TICK_S = int(os.environ["TICK_S_FOR_PY"])
SCENE_LOG = OUT / ".scene_showinfo.log"

def parse_showinfo():
    if not SCENE_LOG.exists():
        return {}
    times = []
    for m in re.finditer(r'\[Parsed_showinfo_\d+[^\]]*\]\s*n:\s*(\d+)\s+pts:\d+\s+pts_time:([0-9.]+)', SCENE_LOG.read_text()):
        times.append((int(m.group(1)), float(m.group(2))))
    return times

scene_times = parse_showinfo()
scene_files = sorted(OUT.glob("scene_*.jpg"))
scene_map = []
for i, f in enumerate(scene_files):
    ts = scene_times[i][1] if i < len(scene_times) else None
    scene_map.append({"file": str(f.relative_to(OUT.parent)), "pts_time": ts})

with open(OUT / ".scene_timestamps.json", "w") as fp:
    json.dump(scene_map, fp, indent=2, ensure_ascii=False)

# tick 文件按 N * tick_seconds 计算
tick_files = sorted(OUT.glob("tick_*.jpg"))
tick_map = []
for f in tick_files:
    m = re.search(r'tick_0*(\d+)\.000000\.jpg', f.name)
    n = int(m.group(1)) if m else 0
    ts = n * TICK_S
    tick_map.append({"file": str(f.relative_to(OUT.parent)), "pts_time": ts})

with open(OUT / ".tick_timestamps.json", "w") as fp:
    json.dump(tick_map, fp, indent=2, ensure_ascii=False)

print(f"  → 时间戳: scene={len(scene_map)}, tick={len(tick_map)}")
PY

echo ""
TOTAL=$(ls "$OUT_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' ')
echo "✓ 抽帧完成：$TOTAL 张 jpg (大小 $(du -sh $OUT_DIR | awk '{print $1}'))"
