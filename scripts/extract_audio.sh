#!/bin/bash
# extract_audio.sh — 从视频抽 16kHz 单声道 wav
# 用法：./extract_audio.sh <video> <output.wav>
set -e
VIDEO="$1"
OUT="$2"

if [ -z "$VIDEO" ] || [ -z "$OUT" ]; then
  echo "用法：$0 <video.mp4> <output.wav>" >&2
  exit 1
fi
if [ ! -f "$VIDEO" ]; then
  echo "文件不存在: $VIDEO" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

# 显示元信息
echo "输入：$VIDEO"
ffprobe -v error -show_entries format=duration:stream=codec_name,sample_rate,channels "$VIDEO" 2>&1 | head -10

# 抽音轨
ffmpeg -hide_banner -loglevel error -stats -y \
  -i "$VIDEO" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$OUT" 2>&1

ls -lh "$OUT"
echo "✓ 抽音轨完成"
