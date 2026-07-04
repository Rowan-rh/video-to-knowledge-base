#!/bin/bash
# pipeline.sh — 一键把视频转成知识库
# 用法：./pipeline.sh <video.mp4> [options]
#
# 选项：
#   --output DIR                输出目录（默认：<video-dir>/<video-stem>-知识库/）
#   --whisper-model NAME        whisper 模型名（默认 ggml-medium-q5_0）
#   --model-size fast|balanced|quality  简写：fast=small / balanced=medium(默认) / quality=large
#   --processors N              whisper 并行 processor 数（默认 4）
#   --threads N                 whisper 线程数（默认 8）
#   --frames N                  期望总帧数（自动分场景/保底）
#   --scene-threshold F         场景切换阈值（默认 0.4）
#   --max-frames N              抽帧总数上限（默认 200，超出按时间均匀采样）
#   --skip-frames               跳过抽帧和视觉理解
#   --skip-notes                跳过结构化笔记
#   --skip-feishu               跳过推送到飞书知识库
#   --feishu-space ID           飞书知识库空间 ID（默认自动检测）
#   --feishu-parent TOKEN       飞书父节点 token（放到指定目录下）
#   --skip-anki                 跳过 Anki 闪卡生成
#   --anki-deck NAME            Anki deck 名称（默认：视频知识库::<video-stem>）
#   --vision-model NAME         llava-phi3 (default)
#   --text-model NAME           qwen3:8b (default)
#   --from-step N               从第 N 步开始（默认 1）
#   --to-step N                 到第 N 步结束（默认 9）
#   -h, --help                  帮

set -eo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}=========== STEP $1: $2 ===========${NC}"; }
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }

# run_python <tag> <cmd...> — 跑 Python 脚本，成功时 tail 末尾，失败时打印完整日志并返回非零退出码
RUN_PY_LOGDIR=$(mktemp -d -t v2k_pylog.XXXXXX)
trap 'rm -rf "$RUN_PY_LOGDIR"' EXIT
run_python() {
  local tag="$1"; shift
  local log="$RUN_PY_LOGDIR/${tag}.log"
  if python3 "$@" > "$log" 2>&1; then
    tail -10 "$log"
  else
    local rc=$?
    err "Python 脚本失败 (rc=$rc): $*"
    cat "$log"
    return $rc
  fi
}

# 默认参数
VIDEO=""
OUT_DIR=""
WHISPER_MODEL="ggml-medium-q5_0"     # 默认 medium：质量+速度平衡
PROCESSORS=4                          # whisper.cpp 并行 processor
THREADS=8                             # whisper.cpp 线程
FRAMES=80
SCENE_TH=0.4              # 0.25 对 B 站讲解类太敏感，提到 0.4
MAX_FRAMES=200             # 总帧数上限（防止极端情况）
SKIP_FRAMES=0
SKIP_NOTES=0
SKIP_FEISHU=0
FEISHU_SPACE=""
FEISHU_PARENT=""
SKIP_ANKI=0
ANKI_DECK=""
VISION_MODEL="llava-phi3"
TEXT_MODEL="qwen3:8b"
WHISPER_TIMEOUT=7200       # whisper 转录超时（秒），默认 2h
FROM_STEP=1
TO_STEP=9

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --output) OUT_DIR="$2"; shift 2 ;;
    --whisper-model) WHISPER_MODEL="$2"; shift 2 ;;
    --model-size)
      case "$2" in
        fast)     WHISPER_MODEL="ggml-small-q5_1" ;;
        balanced) WHISPER_MODEL="ggml-medium-q5_0" ;;
        quality)  WHISPER_MODEL="ggml-large-v3-q5_0" ;;
        *) err "未知 --model-size: $2 (可用: fast|balanced|quality)"; exit 1 ;;
      esac
      shift 2
      ;;
    --processors) PROCESSORS="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --scene-threshold) SCENE_TH="$2"; shift 2 ;;
    --max-frames) MAX_FRAMES="$2"; shift 2 ;;
    --skip-frames) SKIP_FRAMES=1; shift ;;
    --skip-notes) SKIP_NOTES=1; shift ;;
    --skip-feishu) SKIP_FEISHU=1; shift ;;
    --feishu-space) FEISHU_SPACE="$2"; shift 2 ;;
    --feishu-parent) FEISHU_PARENT="$2"; shift 2 ;;
    --skip-anki) SKIP_ANKI=1; shift ;;
    --anki-deck) ANKI_DECK="$2"; shift 2 ;;
    --vision-model) VISION_MODEL="$2"; shift 2 ;;
    --text-model) TEXT_MODEL="$2"; shift 2 ;;
    --whisper-timeout) WHISPER_TIMEOUT="$2"; shift 2 ;;
    --from-step) FROM_STEP="$2"; shift 2 ;;
    --to-step) TO_STEP="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) err "未知参数: $1"; exit 1 ;;
    *) VIDEO="$1"; shift ;;
  esac
done

if [ -z "$VIDEO" ]; then
  err "请提供视频文件"
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 1
fi
if [ ! -f "$VIDEO" ]; then
  err "文件不存在: $VIDEO"
  exit 1
fi

VIDEO_DIR="$( cd "$( dirname "$VIDEO" )" && pwd )"
VIDEO_NAME="$( basename "$VIDEO" )"
VIDEO_STEM="${VIDEO_NAME%.*}"
[ -z "$OUT_DIR" ] && OUT_DIR="$VIDEO_DIR/${VIDEO_STEM}-知识库"

# OUT_DIR 路径规范化 + 白名单校验（防止写到系统目录/并发冲突）
OUT_DIR="$(cd "$(dirname "$OUT_DIR")" 2>/dev/null && pwd)/$(basename "$OUT_DIR")" || { err "无法解析 OUT_DIR: $OUT_DIR"; exit 1; }

# 白名单：OUT_DIR 必须在 $HOME、/tmp 或 $TMPDIR 子树下，禁止写到 /etc /var /usr 等系统目录
ALLOWED_ROOT_OK=0
case "$OUT_DIR/" in
  "$HOME"/*)   ALLOWED_ROOT_OK=1 ;;
  "/tmp"/*)    ALLOWED_ROOT_OK=1 ;;
esac
# $TMPDIR（macOS 通常是 /var/folders/.../T/，去掉末尾 / 避免双斜杠）
if [ "$ALLOWED_ROOT_OK" -eq 0 ] && [ -n "${TMPDIR:-}" ]; then
  case "$OUT_DIR/" in
    "${TMPDIR%/}/"*) ALLOWED_ROOT_OK=1 ;;
  esac
fi
if [ "$ALLOWED_ROOT_OK" -eq 0 ]; then
  err "OUT_DIR 不在允许范围内: $OUT_DIR"
  err "必须在 \$HOME ($HOME)、/tmp 或 \$TMPDIR (${TMPDIR:-未设置}) 子目录下"
  exit 1
fi

# step range 验证
if ! [[ "$FROM_STEP" =~ ^[0-9]+$ ]] || ! [[ "$TO_STEP" =~ ^[0-9]+$ ]]; then
  err "--from-step 和 --to-step 必须是数字"
  exit 1
fi
if [ "$FROM_STEP" -lt 1 ] || [ "$TO_STEP" -gt 9 ] || [ "$FROM_STEP" -gt "$TO_STEP" ]; then
  err "step 范围不合法: --from-step $FROM_STEP --to-step $TO_STEP（有效: 1-9，且 from ≤ to）"
  exit 1
fi

# 获取视频时长（秒），用于计算 tick 间隔
VIDEO_DUR_S=0
if command -v ffprobe >/dev/null 2>&1; then
  VIDEO_DUR_S=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null | cut -d. -f1)
fi
if [ -z "$VIDEO_DUR_S" ] || [ "$VIDEO_DUR_S" -le 0 ] 2>/dev/null; then
  VIDEO_DUR_S=4020  # fallback ~67min
fi

# tick 间隔：根据期望总帧数和视频时长动态计算
# 目标：FRAMES 张总帧（scene + tick 各约一半）
# tick 数 ≈ FRAMES * 0.55（留余量给 scene 帧）
# TICK_S = VIDEO_DUR_S / tick_count
TICK_COUNT=$(python3 -c "import math; print(max(1, int($FRAMES * 0.55)))" 2>/dev/null || echo 44)
TICK_S=$(python3 -c "print(max(30, int($VIDEO_DUR_S / $TICK_COUNT)))" 2>/dev/null || echo 90)

mkdir -p "$OUT_DIR"
echo "视频：$VIDEO（${VIDEO_DUR_S}s = $((VIDEO_DUR_S/60))min）"
echo "输出：$OUT_DIR"
echo "whisper 模型：$WHISPER_MODEL（procs=$PROCESSORS, threads=$THREADS）"
echo "视觉模型：$VISION_MODEL | 文本模型：$TEXT_MODEL"
echo "抽帧：目标 $FRAMES 帧（scene + tick），tick 间隔 ${TICK_S}s"
echo "---"

# 确保 Python 脚本在 OUT_DIR 中存在（--from-step 跳过 step 1 时也需要）
mkdir -p "$OUT_DIR/scripts"
if [ ! -f "$OUT_DIR/scripts/describe_frames.py" ] || [ ! -f "$OUT_DIR/scripts/compose_notes.py" ]; then
  cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py "$OUT_DIR/scripts/" 2>/dev/null || true
  chmod +x "$OUT_DIR/scripts/"*.sh "$OUT_DIR/scripts/"*.py 2>/dev/null || true
fi

# ====== STEP 1: 环境检查 ======
if [ $FROM_STEP -le 1 ] && [ $TO_STEP -ge 1 ]; then
  step 1 "环境检查"
  if "$SCRIPT_DIR/env_check.sh"; then
    ok "环境就绪"
  else
    err "环境检查失败，请修复后再跑"
    exit 1
  fi

  # 拷贝 Python 脚本到 OUT_DIR，确保 Path(__file__).parent.parent 指向知识库根目录
  mkdir -p "$OUT_DIR/scripts"
  cp "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/*.py "$OUT_DIR/scripts/" 2>/dev/null || true
  chmod +x "$OUT_DIR/scripts/"*.sh "$OUT_DIR/scripts/"*.py 2>/dev/null || true
  ok "脚本已拷贝到 $OUT_DIR/scripts/"
fi

# ====== STEP 2 & 4 并行：抽音轨（CPU）+ 抽帧（CPU+少量GPU）======
# 抽帧不依赖音轨，可与抽音轨并行，节省 ~30 秒
RUN_STEP_2=0
RUN_STEP_4=0
[ $FROM_STEP -le 2 ] && [ $TO_STEP -ge 2 ] && RUN_STEP_2=1
[ $FROM_STEP -le 4 ] && [ $TO_STEP -ge 4 ] && [ $SKIP_FRAMES -eq 0 ] && RUN_STEP_4=1

# 启动 step 4 后台（不依赖 step 2 输出）
STEP4_PID=""
STEP4_LOG=""
if [ $RUN_STEP_4 -eq 1 ]; then
  step 4 "抽关键帧（后台）"
  mkdir -p "$OUT_DIR/frames"
  STEP4_LOG="$OUT_DIR/frames/.step4.log"
  "$SCRIPT_DIR/extract_frames.sh" "$VIDEO" "$OUT_DIR/frames" "$SCENE_TH" "$TICK_S" "$MAX_FRAMES" > "$STEP4_LOG" 2>&1 &
  STEP4_PID=$!
fi

# 同步跑 step 2（CPU 密集，< 5 秒完成）
if [ $RUN_STEP_2 -eq 1 ]; then
  step 2 "抽音轨"
  mkdir -p "$OUT_DIR/audio"
  "$SCRIPT_DIR/extract_audio.sh" "$VIDEO" "$OUT_DIR/audio/full.wav"
  ok "音轨已抽"
fi

# 等 step 4 后台完成
if [ -n "$STEP4_PID" ]; then
  wait "$STEP4_PID" && STEP4_RC=0 || STEP4_RC=$?
  if [ $STEP4_RC -eq 0 ]; then
    ok "抽帧完成"
  else
    err "step 4 抽帧失败 (rc=$STEP4_RC)"
    [ -n "$STEP4_LOG" ] && tail -20 "$STEP4_LOG"
    exit $STEP4_RC
  fi
  rm -f "$STEP4_LOG"
fi

# 处理 SKIP_FRAMES 警告（兼容原逻辑）
if [ $SKIP_FRAMES -eq 1 ] && [ $FROM_STEP -le 4 ] && [ $TO_STEP -ge 4 ]; then
  warn "跳过抽帧（--skip-frames）"
fi

# ====== STEP 3: 转录 ======
if [ $FROM_STEP -le 3 ] && [ $TO_STEP -ge 3 ]; then
  step 3 "whisper.cpp 转录"
  mkdir -p "$OUT_DIR/captions"
  rm -f "$OUT_DIR/captions"/full.* 2>/dev/null
  "$SCRIPT_DIR/transcribe.sh" "$OUT_DIR/audio/full.wav" "$OUT_DIR/captions" \
    "$WHISPER_MODEL" "$PROCESSORS" "$THREADS" "zh" "$WHISPER_TIMEOUT"

  # 把 srt 转成 json 给后续步骤用（必须用 unquoted heredoc 让 bash 展开 $OUT_DIR）
  OUT_DIR_FOR_PY="$OUT_DIR" python3 << 'PY'
import os, re, json
from pathlib import Path
out_dir = os.environ["OUT_DIR_FOR_PY"]
srt = Path(f"{out_dir}/captions/full.srt")
if srt.exists():
    pattern = re.compile(r'(\d+)\n(\d{2}):(\d{2}):(\d{2}),(\d{3}) --> (\d{2}):(\d{2}):(\d{2}),(\d{3})\n(.*?)\n\n', re.DOTALL)
    segs = []
    for m in pattern.finditer(srt.read_text()):
        h1,mn1,s1,ms1,h2,mn2,s2,ms2 = (int(m.group(i)) for i in range(2,10))
        segs.append({
            "id": int(m.group(1)),
            "start": h1*3600+mn1*60+s1+ms1/1000,
            "end": h2*3600+mn2*60+s2+ms2/1000,
            "text": m.group(10).strip(),
        })
    Path(f"{out_dir}/captions/full.json").write_text(
        json.dumps({"text": "\n".join(s["text"] for s in segs), "segments": segs}, ensure_ascii=False, indent=2)
    )
    print(f"  → JSON 含 {len(segs)} 段")
PY

  # SRT 存在性 + 非空检查（防止 whisper 失败导致后面步骤基于空字幕跑出空白笔记）
  if [ ! -s "$OUT_DIR/captions/full.srt" ]; then
    err "转录产物缺失或为空：$OUT_DIR/captions/full.srt"
    err "可能原因：whisper-cli 失败、视频无声、视频超 2.5h、模型未下载"
    exit 1
  fi
  if [ ! -s "$OUT_DIR/captions/full.json" ]; then
    err "SRT→JSON 转换失败：$OUT_DIR/captions/full.json 未生成"
    exit 1
  fi
  ok "转录完成"
fi

# ====== STEP 5: 视觉理解 ======
if [ $FROM_STEP -le 5 ] && [ $TO_STEP -ge 5 ] && [ $SKIP_FRAMES -eq 0 ]; then
  step 5 "视觉理解（$VISION_MODEL）"
  VISION_MODEL="$VISION_MODEL" run_python describe_frames "$OUT_DIR/scripts/describe_frames.py"
  ok "视觉理解完成"
fi

# ====== STEP 6: 结构化笔记 ======
if [ $FROM_STEP -le 6 ] && [ $TO_STEP -ge 6 ] && [ $SKIP_NOTES -eq 0 ]; then
  step 6 "结构化笔记（$TEXT_MODEL）"
  TEXT_MODEL="$TEXT_MODEL" run_python compose_notes "$OUT_DIR/scripts/compose_notes.py"
  ok "笔记完成"
fi

# ====== STEP 7: 整合 + 帧索引 ======
if [ $FROM_STEP -le 7 ] && [ $TO_STEP -ge 7 ]; then
  step 7 "帧索引 + 整合"
  run_python index_frames "$OUT_DIR/scripts/index_frames.py"
  ok "全部完成"
fi

# ====== STEP 8: 推送到飞书知识库（可选） ======
if [ $FROM_STEP -le 8 ] && [ $TO_STEP -ge 8 ] && [ $SKIP_FEISHU -eq 0 ]; then
  step 8 "推送到飞书知识库"
  FEISHU_ARGS=""
  [ -n "$FEISHU_SPACE" ] && FEISHU_ARGS="$FEISHU_ARGS --space-id $FEISHU_SPACE"
  [ -n "$FEISHU_PARENT" ] && FEISHU_ARGS="$FEISHU_ARGS --parent-node-token $FEISHU_PARENT"
  if "$SCRIPT_DIR/push_to_feishu.sh" "$OUT_DIR" $FEISHU_ARGS; then
    ok "飞书推送完成"
  else
    FEISHU_EXIT=$?
    if [ $FEISHU_EXIT -eq 2 ]; then
      warn "飞书未配置，跳过推送（不影响本地知识库）"
      warn "  配置方法: lark-cli config init --new && lark-cli auth login"
    else
      warn "飞书推送部分失败（不影响本地知识库）"
    fi
  fi
elif [ $SKIP_FEISHU -eq 1 ]; then
  warn "跳过飞书推送（--skip-feishu）"
fi

# ====== STEP 9: Anki 闪卡生成（可选） ======
if [ $FROM_STEP -le 9 ] && [ $TO_STEP -ge 9 ] && [ $SKIP_ANKI -eq 0 ]; then
  step 9 "Anki 闪卡生成"
  ANKI_ARGS=()
  [ -n "$ANKI_DECK" ] && ANKI_ARGS+=(--deck "$ANKI_DECK")
  if python3 "$OUT_DIR/scripts/create_anki_cards.py" "${ANKI_ARGS[@]}"; then
    ok "Anki 闪卡生成完成"
  else
    ANKI_EXIT=$?
    if [ $ANKI_EXIT -eq 2 ]; then
      warn "AnkiConnect 不可达，卡片已导出到 knowledge/anki_cards.json"
      warn "  → 启动 Anki + 安装 AnkiConnect 插件后重跑: --from-step 9"
    else
      warn "Anki 闪卡生成失败（不影响知识库）"
    fi
  fi
elif [ $SKIP_ANKI -eq 1 ]; then
  warn "跳过 Anki 闪卡（--skip-anki）"
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}✅ 知识库生成完成${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "📁 输出目录: $OUT_DIR"
echo ""
echo "推荐阅读："
echo "  $OUT_DIR/knowledge/99-整合·全知识库.md   ← 一站式（思维导图 + 9 章节 + 速查）"
echo "  $OUT_DIR/knowledge/02-结构化笔记.md      ← 9 章节书面笔记"
echo "  $OUT_DIR/captions/full.srt                ← 字幕（可拖进播放器）"
echo ""
echo "🚀 下一步（端到端工作流）："
echo ""
echo "  1️⃣  摄入到第二大脑（强烈推荐）："
echo "      在 QoderWork 里说："
echo "      \"用 second-brain-ingest 把 $OUT_DIR/knowledge/ 下的笔记摄取到第二大脑\""
echo ""
echo "  2️⃣  RAG 问答检索："
echo "      \"用 second-brain-query 问：Hermes 资金化机制的核心创新是什么？\""
echo ""
echo "  3️⃣  健康检查："
echo "      \"跑 second-brain-lint 体检\""
echo ""
echo "  4️⃣  本地其他操作："
echo "      - 安装 Obsidian + Markdown Preview Mermaid Support 渲染思维导图"
echo "      - 重跑任意步骤: ./pipeline.sh $VIDEO --from-step N"
