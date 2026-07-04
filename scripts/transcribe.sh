#!/bin/bash
# transcribe.sh — 用 whisper.cpp + Metal GPU 转录音频
#
# 用法：./transcribe.sh <audio.wav> <captions_dir> [model] [processors] [threads] [lang]
#
# 位置参数（向后兼容）：
#   $1 AUDIO      音频 wav 路径
#   $2 OUT_DIR    输出目录
#   $3 MODEL      模型名（默认 ggml-medium-q5_0，质量+速度平衡）
#   $4 PROCESSORS 并行 processor 数（默认 4，M1 Pro 16GB 推荐）
#   $5 THREADS    线程数（默认 8）
#   $6 LANG       语言（默认 zh）
#
# 可用模型（按速度排序）：
#   ggml-tiny-q5_1      31M   ⚠ 中文质量差
#   ggml-base-q5_1      57M   ⚠ 中文质量差
#   ggml-small-q5_1    181M   ⭐⭐⭐  极速，有少量漏段
#   ggml-medium-q5_0   514M   ⭐⭐⭐⭐ 默认（推荐，质量+速度平衡）
#   ggml-large-v3-q5_0 1.0G   ⭐⭐⭐⭐⭐ 最高质量（速度慢 1.8×）
set -e

AUDIO="$1"
OUT_DIR="$2"
MODEL_NAME="${3:-ggml-medium-q5_0}"
PROCESSORS="${4:-4}"
THREADS="${5:-8}"
LANG="${6:-zh}"

if [ -z "$AUDIO" ] || [ -z "$OUT_DIR" ]; then
  echo "用法：$0 <audio.wav> <captions_dir> [model] [processors] [threads] [lang]" >&2
  echo "" >&2
  echo "可用模型：" >&2
  echo "  ggml-medium-q5_0  默认（推荐）" >&2
  echo "  ggml-large-v3-q5_0  最高质量" >&2
  echo "  ggml-small-q5_1    极速" >&2
  echo "" >&2
  echo "示例：" >&2
  echo "  $0 audio.wav captions/                                  # 用默认 medium" >&2
  echo "  $0 audio.wav captions/ ggml-large-v3-q5_0 4 8 zh         # 指定 large" >&2
  exit 1
fi

MODEL_PATH=~/.cache/whisper.cpp/${MODEL_NAME}.bin
if [ ! -f "$MODEL_PATH" ]; then
  echo "模型未下载: $MODEL_PATH" >&2
  echo "下载：" >&2
  echo "  curl -L -o $MODEL_PATH 'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}.bin'" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
WHISPER=/opt/homebrew/bin/whisper-cli
[ ! -x "$WHISPER" ] && WHISPER=$(which whisper-cli 2>/dev/null)
if [ ! -x "$WHISPER" ]; then
  echo "whisper-cli 未装或不在 PATH 中" >&2
  exit 1
fi

echo "=== whisper.cpp 转录 ==="
echo "音频:   $AUDIO ($(du -h "$AUDIO" | awk '{print $1}'))"
echo "模型:   $MODEL_NAME ($(du -h "$MODEL_PATH" | awk '{print $1}'))"
echo "Procs:  $PROCESSORS"
echo "线程:   $THREADS"
echo "语言:   $LANG"
echo ""

START=$(date +%s)

# 关键参数：
#   -pp             print progress
#   -p N            processors (parallel encoder pipelines)
#   -t N            threads
#   --prompt        引导上下文（中文视频用中文 prompt 提升识别）
"$WHISPER" \
  -m "$MODEL_PATH" \
  -f "$AUDIO" \
  -l "$LANG" \
  -pp \
  -p "$PROCESSORS" \
  -t "$THREADS" \
  --prompt "本视频是关于技术讲座的分享，包含主讲人的口头讲解和 PPT 演示。" \
  -osrt -ovtt -otxt -olrc -ocsv \
  -of "$OUT_DIR/full" \
  2>&1 | tail -20

END=$(date +%s)
ELAPSED=$((END - START))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo "✓ 转录完成（$MINUTES 分 $SECONDS 秒）"
ls -la "$OUT_DIR"/full.* 2>&1