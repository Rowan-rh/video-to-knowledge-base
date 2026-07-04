#!/bin/bash
# transcribe.sh — 用 whisper.cpp + Metal GPU 转录音频
#
# 用法：./transcribe.sh <audio.wav> <captions_dir> [model] [processors] [threads] [lang] [timeout]
#
# 位置参数（向后兼容）：
#   $1 AUDIO      音频 wav 路径
#   $2 OUT_DIR    输出目录
#   $3 MODEL      模型名（默认 ggml-medium-q5_0，质量+速度平衡）
#   $4 PROCESSORS 并行 processor 数（默认 4，M1 Pro 16GB 推荐）
#   $5 THREADS    线程数（默认 8）
#   $6 LANG       语言（默认 zh）
#   $7 TIMEOUT    超时秒数（默认 7200 = 2 小时）
#
# 可用模型（按速度排序）：
#   ggml-tiny-q5_1      31M   ⚠ 中文质量差
#   ggml-base-q5_1      57M   ⚠ 中文质量差
#   ggml-small-q5_1    181M   ⭐⭐⭐  极速，有少量漏段
#   ggml-medium-q5_0   514M   ⭐⭐⭐⭐ 默认（推荐，质量+速度平衡）
#   ggml-large-v3-q5_0 1.0G   ⭐⭐⭐⭐⭐ 最高质量（速度慢 1.8×）
set -eo pipefail

# 颜色（如果是从 pipeline.sh 调用，则已定义）
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
err()  { echo -e "${RED}✗${NC} $1"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }

AUDIO="$1"
OUT_DIR="$2"
MODEL_NAME="${3:-ggml-medium-q5_0}"
PROCESSORS="${4:-4}"
THREADS="${5:-8}"
LANG="${6:-zh}"
TIMEOUT="${7:-7200}"

if [ -z "$AUDIO" ] || [ -z "$OUT_DIR" ]; then
  echo "用法：$0 <audio.wav> <captions_dir> [model] [processors] [threads] [lang] [timeout]" >&2
  echo "" >&2
  echo "可用模型：" >&2
  echo "  ggml-medium-q5_0  默认（推荐）" >&2
  echo "  ggml-large-v3-q5_0  最高质量" >&2
  echo "  ggml-small-q5_1    极速" >&2
  echo "" >&2
  echo "示例：" >&2
  echo "  $0 audio.wav captions/                                  # 用默认 medium" >&2
  echo "  $0 audio.wav captions/ ggml-large-v3-q5_0 4 8 zh 14400  # large + 4h 超时" >&2
  exit 1
fi

MODEL_PATH=~/.cache/whisper.cpp/${MODEL_NAME}.bin
if [ ! -f "$MODEL_PATH" ]; then
  echo "模型未下载: $MODEL_PATH" >&2
  echo "下载：" >&2
  echo "  curl -L -o $MODEL_PATH 'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}.bin'" >&2
  exit 1
fi

# 模型文件大小 sanity check（防止下载中断导致模型损坏）
# 阈值：tiny 30M / base 50M / small 150M / medium 400M / large 800M
ACTUAL_SIZE_MB=$(du -m "$MODEL_PATH" 2>/dev/null | awk '{print $1}' || echo 0)
case "$MODEL_NAME" in
  *tiny*)  MIN_MB=30 ;;
  *base*)  MIN_MB=50 ;;
  *small*) MIN_MB=150 ;;
  *medium*) MIN_MB=400 ;;
  *large*) MIN_MB=800 ;;
  *) MIN_MB=30 ;;
esac
if [ "$ACTUAL_SIZE_MB" -lt "$MIN_MB" ]; then
  err "模型文件过小（${ACTUAL_SIZE_MB}MB < ${MIN_MB}MB），可能下载不完整"
  err "请重新下载: $MODEL_PATH"
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
echo "超时:   ${TIMEOUT}s"
echo ""

LOG="$OUT_DIR/.whisper.log"
START=$(date +%s)

# 关键参数：
#   -pp             print progress
#   -p N            processors (parallel encoder pipelines)
#   -t N            threads
#   --prompt        引导上下文（中文视频用中文 prompt 提升识别）
#   timeout         防止模型 hang 住或视频超长卡死
# macOS 默认无 GNU timeout，用 perl 自带的 alarm() 实现（跨平台）
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$WHISPER" \
  -m "$MODEL_PATH" \
  -f "$AUDIO" \
  -l "$LANG" \
  -pp \
  -p "$PROCESSORS" \
  -t "$THREADS" \
  --prompt "本视频是关于技术讲座的分享，包含主讲人的口头讲解和 PPT 演示。" \
  -osrt -ovtt -otxt -olrc -ocsv \
  -of "$OUT_DIR/full" \
  > "$LOG" 2>&1
RC=$?

END=$(date +%s)
ELAPSED=$((END - START))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

# 输出末尾日志给用户看
echo "---- whisper 日志（最后 20 行）----"
tail -20 "$LOG"
echo "----"

if [ $RC -ne 0 ]; then
  err "whisper-cli 失败 (rc=$RC, 用时 ${MINUTES} 分 ${SECONDS} 秒)"
  if [ $RC -eq 142 ] || [ $RC -eq 143 ] || [ $RC -eq 124 ]; then
    # perl alarm 超时返回 142 (SIGALRM) 或 shell 124 (GNU timeout)
    err "超时（>${TIMEOUT}s）"
    err "建议：换 small-q5_1 模型、加 TIMEOUT、或检查视频是否 >2.5h"
  fi
  err "完整日志: $LOG"
  exit $RC
fi

echo ""
ok "转录完成（${MINUTES} 分 ${SECONDS} 秒）"
ls -la "$OUT_DIR"/full.* 2>&1

# 清理日志（成功就删，失败保留供排查）
rm -f "$LOG"