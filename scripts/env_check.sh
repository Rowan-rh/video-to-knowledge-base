#!/bin/bash
# env_check.sh — 完整环境检查（video-to-knowledge-base skill）
# 用法：./env_check.sh [--fix] [--install-guide]
#
# 退出码：
#   0 = 全部通过
#   1 = 有缺失依赖
#   2 = 不支持的平台
#
# 模式：
#   (默认)     仅检查并报告
#   --fix      尝试自动安装缺失依赖
#   --install-guide  打印完整安装步骤

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
FIX=0; GUIDE=0
[ "$1" = "--fix" ] && FIX=1
[ "$1" = "--install-guide" ] && GUIDE=1

if [ $GUIDE -eq 1 ]; then
cat <<'EOF'
═══════════════════════════════════════════
  video-to-knowledge-base skill 安装指南
═══════════════════════════════════════════

1. macOS + Homebrew（必须）
   系统要求：macOS 14+ (Sonoma) on Apple Silicon
   安装 Homebrew（如未装）：/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

2. 命令行工具（必须）
   brew install ffmpeg whisper-cpp

3. 下载 whisper 模型（必须，一次性）
   mkdir -p ~/.cache/whisper.cpp
   curl -L -o ~/.cache/whisper.cpp/ggml-medium-q5_0.bin \
     "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"

4. 在 QoderWork 中运行（推荐）
   使用 QoderWork 远程模型处理 Steps 5-7（视觉理解+结构化笔记），质量远超本地小模型。

5. 离线 fallback（可选）
   如需完全离线运行，额外安装：
   brew install --cask ollama
   ollama serve &
   ollama pull llava-phi3       # 视觉理解 fallback（3GB）
   ollama pull qwen3:8b         # 文本改写 fallback（5GB）

6. 验证
   ./env_check.sh

7. 跑本地 pipeline（Steps 1-4）
   ./pipeline.sh /path/to/video.mp4 --to-step 4 --skip-feishu --skip-anki

EOF
exit 0
fi

ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

MISSING=()
WARNINGS=()

echo "==============================================="
echo "  video-to-knowledge-base 环境检查"
echo "==============================================="
echo ""

# ====== 1. 平台检查 ======
info "1. 平台检查"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  ok "Apple Silicon (arm64)"
elif [ "$ARCH" = "x86_64" ]; then
  warn "Intel Mac — Metal GPU 不可用，whisper.cpp 会用 CPU（慢 5-10x）"
  WARNINGS+=("推荐用 Apple Silicon Mac")
else
  err "不支持的架构: $ARCH"
  exit 2
fi

# macOS 版本
if [ "$(uname -s)" = "Darwin" ]; then
  MACOS_VER=$(sw_vers -productVersion 2>/dev/null | awk -F. '{print $1}')
  if [ -n "$MACOS_VER" ] && [ "$MACOS_VER" -ge 14 ]; then
    ok "macOS $(sw_vers -productVersion)"
  else
    err "macOS 版本太老（需要 14+），当前: $(sw_vers -productVersion 2>/dev/null)"
    MISSING+=("升级 macOS 到 14+ (Sonoma) 或更高")
  fi
fi

# Homebrew（Apple Silicon 路径）
if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
  BREW=$(which brew 2>/dev/null)
  ok "Homebrew $(${BREW} --version 2>&1 | head -1 | awk '{print $2}')"
else
  err "Homebrew 未装"
  MISSING+=("/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
fi

echo ""

# ====== 2. ffmpeg ======
info "2. ffmpeg"
if command -v ffmpeg >/dev/null 2>&1; then
  FFV=$(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')
  ok "ffmpeg $FFV"
else
  err "ffmpeg 未装"
  MISSING+=("brew install ffmpeg")
fi
if command -v ffprobe >/dev/null 2>&1; then
  ok "ffprobe $(ffprobe -version 2>&1 | head -1 | awk '{print $3}')"
else
  err "ffprobe 未装（随 ffmpeg 一起）"
fi

echo ""

# ====== 3. whisper.cpp ======
info "3. whisper.cpp"
WHISPER=""
for p in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
  if [ -x "$p" ]; then WHISPER="$p"; break; fi
done
if [ -n "$WHISPER" ]; then
  ok "whisper-cli ($WHISPER)"
  # 验证 Metal backend
  if "$WHISPER" -h 2>&1 | grep -q "ggml_metal_device_init"; then
    if "$WHISPER" -h 2>&1 | grep -q "GPU name:"; then
      GPU_NAME=$("$WHISPER" -h 2>&1 | grep "GPU name:" | head -1 | sed 's/.*GPU name:\s*//')
      ok "Metal GPU: $GPU_NAME"
    fi
  else
    warn "whisper.cpp 未启用 Metal（Intel Mac？CPU 推理会慢）"
  fi
else
  err "whisper.cpp 未装"
  MISSING+=("brew install whisper-cpp")
fi

# whisper 模型（检测任意已下载的模型，优先推荐 medium）
WHISPER_CACHE="$HOME/.cache/whisper.cpp"
WHISPER_MODEL=""
WHISPER_MODEL_NAME=""
# 按优先级检查：medium（默认推荐）> large > small
for _m in ggml-medium-q5_0 ggml-large-v3-q5_0 ggml-small-q5_1; do
  if [ -f "$WHISPER_CACHE/${_m}.bin" ]; then
    WHISPER_MODEL="$WHISPER_CACHE/${_m}.bin"
    WHISPER_MODEL_NAME="$_m"
    break
  fi
done

if [ -n "$WHISPER_MODEL" ]; then
  SIZE=$(du -h "$WHISPER_MODEL" | awk '{print $1}')
  ok "whisper 模型: $WHISPER_MODEL_NAME ($SIZE)"
  # 验证模型大小合理
  SIZE_BYTES=$(stat -f%z "$WHISPER_MODEL" 2>/dev/null || stat -c%s "$WHISPER_MODEL" 2>/dev/null)
  if [ "$SIZE_BYTES" -lt 150000000 ]; then
    warn "whisper 模型文件偏小（$SIZE），可能下载不完整"
    WARNINGS+=("重新下载模型")
  fi
else
  err "whisper 模型未下载（需要至少一个：medium/large/small）"
  # 拆成两个简单命令（不用复合命令，便于安全校验）
  MISSING+=("mkdir -p $WHISPER_CACHE")
  MISSING+=("curl -L -o $WHISPER_CACHE/ggml-medium-q5_0.bin 'https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin'")
fi

echo ""

# ====== 4. ollama（离线 fallback，非必须） ======
info "4. ollama（离线 fallback）"
if command -v ollama >/dev/null 2>&1; then
  ok "ollama $(ollama --version 2>&1 | awk '{print $NF}')"
else
  info "ollama 未装（仅影响离线 fallback，推荐用 QoderWork 远程模型）"
fi

# ollama serve
OLLAMA_UP=0
if curl -s -m 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
  ok "ollama serve 在跑"
  OLLAMA_UP=1
else
  err "ollama serve 未启动"
  warn "  → 启动方法："
  warn "      1) 在另一个终端跑: ollama serve"
  warn "      2) 或后台跑: nohup ollama serve > /tmp/ollama.log 2>&1 &"
fi

# 模型列表
if [ $OLLAMA_UP -eq 1 ]; then
  MODELS=$(curl -s -m 5 http://localhost:11434/api/tags | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(m['name'] for m in d.get('models',[])))" 2>/dev/null || echo "")

  if echo "$MODELS" | grep -q "llava-phi3"; then
    SIZE=$(curl -s -m 5 http://localhost:11434/api/show/llava-phi3 | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('size','?'))" 2>/dev/null || echo "?")
    ok "llava-phi3 已装 (size: $SIZE)"
  else
    info "llava-phi3 未拉取（离线 fallback 可选）"
  fi

  if echo "$MODELS" | grep -qE "qwen3:8b|qwen3:4b"; then
    QVER=$(echo "$MODELS" | grep -oE "qwen3:[48]b" | head -1)
    ok "$QVER 已装"
  else
    info "qwen3:8b 未拉取（离线 fallback 可选）"
  fi
fi

echo ""

# ====== 5. Python + ollama HTTP 库 ======
info "5. Python"
PYTHON=$(which python3)
if [ -n "$PYTHON" ]; then
  PYV=$($PYTHON --version 2>&1 | awk '{print $2}')
  PY_MAJOR=$(echo $PYV | cut -d. -f1)
  PY_MINOR=$(echo $PYV | cut -d. -f2)
  if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 9 ]; then
    ok "python3 $PYV"
  else
    warn "python3 $PYV（推荐 ≥ 3.9）"
  fi
else
  err "python3 未装"
fi

# 必需模块
for mod in "json" "subprocess" "pathlib" "urllib.request"; do
  if $PYTHON -c "import $mod" 2>/dev/null; then
    ok "Python module: $mod"
  else
    err "Python module 缺: $mod"
    MISSING+=("python -m pip install $mod")
  fi
done

echo ""

# ====== 6. 网络 ======
info "6. 网络可达性"
# 测 GitHub
if curl -sI -m 5 https://github.com 2>/dev/null | head -1 | grep -q "200\|301\|302"; then
  ok "GitHub 可达"
else
  warn "GitHub 不可达（可能影响 skill 安装）"
fi
# 测 hf-mirror（whisper 模型镜像）
if curl -sI -m 5 https://hf-mirror.com 2>/dev/null | head -1 | grep -q "200\|301\|302"; then
  ok "hf-mirror.com 可达（whisper 模型下载源）"
else
  warn "hf-mirror.com 不可达（whisper 模型下载可能失败）"
fi
# 测 ollama registry（如果本地模型未装）
if curl -sI -m 5 https://registry.ollama.ai 2>/dev/null | head -1 | grep -q "200\|301\|302"; then
  ok "registry.ollama.ai 可达（ollama 模型下载源）"
else
  warn "registry.ollama.ai 不可达（ollama 模型下载可能失败）"
fi

echo ""

# ====== 7. 磁盘 ======
info "7. 磁盘空间"
FREE_GB=$(df -g ~/.agents 2>/dev/null | tail -1 | awk '{print $4}')
NEED_GB=15
if [ "$FREE_GB" -ge $NEED_GB ] 2>/dev/null; then
  ok "${FREE_GB}GB 空闲（≥${NEED_GB}GB 推荐）"
elif [ "$FREE_GB" -ge 8 ] 2>/dev/null; then
  warn "仅 ${FREE_GB}GB 空闲（推荐 ${NEED_GB}GB；用 medium 模型可降到 ~8GB）"
else
  err "仅 ${FREE_GB}GB 空闲（最少 8GB）"
fi

# 输出目录可写
DST_TEST="$HOME/Downloads/.video-to-knowledge-base-test"
if touch "$DST_TEST" 2>/dev/null; then
  rm "$DST_TEST"
  ok "可写权限：~/Downloads/"
else
  warn "~/Downloads/ 不可写"
fi

echo ""

# ====== 8. 实测：用小音频 + 小模型跑一次 ======
info "8. 实测（验证全链路能跑通）"
if [ -n "$WHISPER" ] && [ -f "$WHISPER_MODEL" ] && [ $OLLAMA_UP -eq 1 ]; then
  TMPWAV=/tmp/env_check_test.wav
  TMPDIR=/tmp/env_check_test
  rm -rf "$TMPDIR"
  mkdir -p "$TMPDIR"
  # 找一段小音频（之前抽的 30s 样本，或生成静音）
  if [ -f "$OUT_DIR/audio/test_30s.wav" ]; then
    cp "$OUT_DIR/audio/test_30s.wav" "$TMPWAV"
  else
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=16000:cl=mono" -t 5 "$TMPWAV" 2>/dev/null
  fi
  if [ -f "$TMPWAV" ]; then
    T0=$(date +%s)
    "$WHISPER" -m "$WHISPER_MODEL" -f "$TMPWAV" -l zh -t 4 \
      -nt 2>/dev/null | head -3 > /tmp/_w_out.txt
    T1=$(date +%s)
    DUR=$((T1 - T0))
    if [ $DUR -le 20 ]; then
      ok "whisper 实测：5s 音频用 ${DUR}s（应 < 20s）"
    else
      warn "whisper 实测较慢：5s 音频用 ${DUR}s"
    fi
  fi
  # ollama 实际 generate
  if curl -s -m 30 -X POST http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen3:8b","prompt":"hi","stream":false,"options":{"num_predict":5}}' 2>/dev/null | grep -q '"response"'; then
    ok "ollama qwen3:8b 实际可 generate"
  else
    err "ollama qwen3:8b 不可 generate（可能模型损坏）"
    WARNINGS+=("重试：ollama pull qwen3:8b")
  fi
  rm -rf "$TMPDIR" "$TMPWAV" /tmp/_w_out.txt 2>/dev/null
fi

echo ""

# ====== 9. 飞书知识库配置（可选） ======
info "9. 飞书知识库推送（可选）"
LARK_CLI=""
for lp in /usr/local/bin/lark-cli /opt/homebrew/bin/lark-cli "$HOME/.npm-global/bin/lark-cli"; do
  if [ -x "$lp" ]; then LARK_CLI="$lp"; break; fi
done
if [ -z "$LARK_CLI" ] && command -v lark-cli >/dev/null 2>&1; then
  LARK_CLI="$(which lark-cli)"
fi

if [ -n "$LARK_CLI" ]; then
  ok "lark-cli $(lark-cli --version 2>/dev/null | awk '{print $NF}' || echo '?')"

  # 检查用户认证状态
  AUTH_JSON="$(lark-cli auth status 2>/dev/null || true)"
  if [ -n "$AUTH_JSON" ]; then
    USER_STATUS="$(echo "$AUTH_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('identities',{}).get('user',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")"
    USER_NAME="$(echo "$AUTH_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('identities',{}).get('user',{}).get('userName',''))" 2>/dev/null || echo "")"

    if [ "$USER_STATUS" = "ready" ] || [ "$USER_STATUS" = "needs_refresh" ]; then
      ok "飞书用户已认证: $USER_NAME ($USER_STATUS)"

      # 检查知识库空间
      SPACE_JSON="$(lark-cli wiki +space-list --as user --format json 2>/dev/null || true)"
      if [ -n "$SPACE_JSON" ]; then
        SPACE_COUNT="$(echo "$SPACE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',{}).get('spaces',[])))" 2>/dev/null || echo "0")"
        if [ "$SPACE_COUNT" -gt 0 ]; then
          SPACE_NAME="$(echo "$SPACE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); spaces=d.get('data',{}).get('spaces',[]); print(spaces[0].get('name','') if spaces else '')" 2>/dev/null || echo "")"
          ok "飞书知识库空间: ${SPACE_NAME:-可用} (${SPACE_COUNT} 个)"
          info "   → pipeline 完成后自动推送知识库到飞书"
          info "   → 或手动: push_to_feishu.sh <OUT_DIR>"
        else
          warn "未找到飞书知识库空间"
          WARNINGS+=("创建知识库空间: lark-cli wiki +space-create --name '我的知识库' --as user")
        fi
      else
        warn "无法查询飞书知识库空间（可能缺少 wiki scope）"
      fi
    else
      warn "飞书用户未认证 (status=$USER_STATUS)"
      WARNINGS+=("登录飞书: lark-cli auth login")
    fi
  else
    warn "无法获取 lark-cli 认证状态"
  fi
else
  info "lark-cli 未安装（飞书推送不可用，不影响本地 pipeline）"
  info "  → 安装: npm install -g @anthropic-ai/lark-cli"
  info "  → 然后: lark-cli config init --new"
fi

echo ""

# ====== 10. Anki + AnkiConnect（可选） ======
info "10. Anki 闪卡生成（可选）"
ANKI_APP="/Applications/Anki.app"
ANKI_ADDON_DIR="$HOME/Library/Application Support/Anki2/addons21/2055492159"
ANKI_CONNECT_PORT=8765

if [ -d "$ANKI_APP" ]; then
  ok "Anki 已安装: $ANKI_APP"

  # 检查是否运行中
  if pgrep -x Anki >/dev/null 2>&1; then
    ok "Anki 正在运行"
  else
    info "Anki 未运行（需要启动才能上传卡片）"
  fi

  # 检查 AnkiConnect 插件
  if [ -f "$ANKI_ADDON_DIR/__init__.py" ]; then
    ok "AnkiConnect 插件已安装"

    # 检查 AnkiConnect 是否可达
    if curl -s -m 3 -X POST "http://127.0.0.1:$ANKI_CONNECT_PORT" \
      -H "Content-Type: application/json" \
      -d '{"action":"version","version":6}' 2>/dev/null | grep -q '"result"'; then
      ANKI_VER=$(curl -s -m 3 -X POST "http://127.0.0.1:$ANKI_CONNECT_PORT" \
        -H "Content-Type: application/json" \
        -d '{"action":"version","version":6}' 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('result','?'))" 2>/dev/null || echo "?")
      ok "AnkiConnect 可达 (API v${ANKI_VER})"
      info "   → pipeline 完成后自动生成 Anki 闪卡"
    else
      warn "AnkiConnect 不可达 (localhost:$ANKI_CONNECT_PORT)"
      warn "  → 可能需要重启 Anki 以加载插件"
    fi
  else
    warn "AnkiConnect 插件未安装"
    info "  → 安装: Anki → Tools → Add-ons → Get Add-ons → 输入 2055492159"
    info "  → 或手动下载: https://github.com/FooSoft/anki-connect"
  fi
else
  info "Anki 未安装（闪卡生成不可用，不影响其他 pipeline 步骤）"
  info "  → 下载: https://apps.ankiweb.net/"
fi

echo ""
echo "==============================================="
if [ ${#MISSING[@]} -eq 0 ] && [ ${#WARNINGS[@]} -eq 0 ]; then
  echo -e "${GREEN}✅ 全部通过${NC} — 可以跑 ./pipeline.sh /path/to/video.mp4"
  exit 0
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo -e "${RED}❌ 缺失 ${#MISSING[@]} 项：${NC}"
  for cmd in "${MISSING[@]}"; do
    echo "  ✗ $cmd"
  done
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}⚠ ${#WARNINGS[@]} 项警告：${NC}"
  for w in "${WARNINGS[@]}"; do
    echo "  ⚠ $w"
  done
fi

echo ""
echo "安装指南：./env_check.sh --install-guide"
echo "自动安装（部分）：./env_check.sh --fix"

if [ $FIX -eq 1 ] && [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  echo "尝试自动修复..."
  for cmd in "${MISSING[@]}"; do
    # 安全校验：拒绝任何含 shell 特殊字符的命令（防止命令注入）
    if echo "$cmd" | grep -qE '[;&|`$()<>{}]'; then
      err "命令含 shell 特殊字符，跳过: $cmd"
      continue
    fi
    case "$cmd" in
      "brew install "*)
        pkg="${cmd#brew install }"
        echo "  跑: brew install $pkg"
        brew install "$pkg" || true
        ;;
      "brew install")  # 无参数 fallback
        echo "  跑: brew install"
        brew install || true
        ;;
      "ollama pull "*)
        model="${cmd#ollama pull }"
        echo "  跑: ollama pull $model"
        ollama pull "$model" || true
        ;;
      "python -m pip install "*)
        mod="${cmd#python -m pip install }"
        echo "  跑: python -m pip install $mod"
        python3 -m pip install "$mod" || true
        ;;
      "/bin/bash -c"*)
        # Homebrew 安装命令（特殊允许，但拆出 URL）
        err "Homebrew 安装需手动执行: $cmd"
        ;;
      mkdir*curl*)
        # 复合命令 mkdir X && curl ...  → 拆分执行
        mkdir_part="${cmd%%&&*}"
        curl_part="${cmd#*&& }"
        mkdir_part="${mkdir_part#mkdir }"
        curl_part="${curl_part#curl }"
        mkdir_dir="${mkdir_part%% *}"
        echo "  跑: mkdir -p $mkdir_dir && curl $curl_part"
        mkdir -p "$mkdir_dir" && curl $curl_part || true
        ;;
      *)
        echo "  跳过自动安装: $cmd"
        ;;
    esac
  done
  echo "请重新跑 env_check.sh 验证"
fi

exit 1
