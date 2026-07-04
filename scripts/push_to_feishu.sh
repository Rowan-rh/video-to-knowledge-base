#!/bin/bash
# push_to_feishu.sh — 推送知识库到飞书知识库
# 用法：./push_to_feishu.sh <OUT_DIR> [--space-id <ID>]
#
# 将 knowledge/*.md 推送到飞书知识库：
#   - 创建父节点 <视频标题>-知识库
#   - 为每个 md 文件创建子节点并写入内容
#
# 选项：
#   --space-id ID           飞书知识库空间 ID（默认用第一个可用空间）
#   --parent-node-token TKN 父节点 token（放到指定目录下，默认放空间根目录）
#   --help                  显示帮助
#
# 退出码：
#   0 = 成功
#   1 = 错误
#   2 = 飞书未配置

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# === 参数解析 ===
OUT_DIR=""
SPACE_ID=""
TARGET_PARENT=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --space-id) SPACE_ID="$2"; shift 2 ;;
    --parent-node-token) TARGET_PARENT="$2"; shift 2 ;;
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) [ -z "$OUT_DIR" ] && OUT_DIR="$1"; shift ;;
  esac
done

if [ -z "$OUT_DIR" ]; then
  err "用法: push_to_feishu.sh <OUT_DIR> [--space-id <ID>]"
  exit 1
fi

# 规范化路径
OUT_DIR="$(cd "$OUT_DIR" 2>/dev/null && pwd)" || { err "目录不存在: $OUT_DIR"; exit 1; }
KNOWLEDGE_DIR="$OUT_DIR/knowledge"

if [ ! -d "$KNOWLEDGE_DIR" ]; then
  err "knowledge/ 目录不存在: $KNOWLEDGE_DIR"
  exit 1
fi

# 从目录名推导视频标题
DIR_NAME="$(basename "$OUT_DIR")"
VIDEO_TITLE="${DIR_NAME%-知识库}"
if [ "$DIR_NAME" = "$VIDEO_TITLE" ]; then
  VIDEO_TITLE="$DIR_NAME"
fi
PARENT_TITLE="${DIR_NAME}"

echo "==============================================="
echo "  推送知识库到飞书"
echo "==============================================="
echo ""
echo "知识库目录: $OUT_DIR"
echo "知识库标题: $PARENT_TITLE"

# === 1. 检查飞书配置 ===
info "1. 检查飞书配置"

if ! command -v lark-cli >/dev/null 2>&1; then
  err "lark-cli 未安装"
  echo "  安装方法: npm install -g lark-cli"
  exit 2
fi

AUTH_JSON="$(lark-cli auth status 2>/dev/null || true)"
if [ -z "$AUTH_JSON" ]; then
  err "无法获取 lark-cli 认证状态"
  exit 2
fi

USER_STATUS="$(echo "$AUTH_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('identities',{}).get('user',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")"
USER_NAME="$(echo "$AUTH_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('identities',{}).get('user',{}).get('userName',''))" 2>/dev/null || echo "")"

if [ "$USER_STATUS" != "ready" ] && [ "$USER_STATUS" != "needs_refresh" ]; then
  err "飞书用户未认证 (status=$USER_STATUS)"
  echo "  请运行: lark-cli auth login"
  exit 2
fi
ok "飞书用户: $USER_NAME ($USER_STATUS)"

# 获取知识库空间
if [ -z "$SPACE_ID" ]; then
  SPACE_JSON="$(lark-cli wiki +space-list --as user --format json 2>/dev/null || true)"
  if [ -z "$SPACE_JSON" ]; then
    err "无法获取知识库空间列表"
    exit 2
  fi
  SPACE_ID="$(echo "$SPACE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
spaces = d.get('data',{}).get('spaces',[])
if spaces:
    print(spaces[0]['space_id'])
" 2>/dev/null || true)"
  SPACE_NAME="$(echo "$SPACE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
spaces = d.get('data',{}).get('spaces',[])
if spaces:
    print(spaces[0].get('name',''))
" 2>/dev/null || true)"
fi

if [ -z "$SPACE_ID" ]; then
  err "未找到可用的飞书知识库空间"
  echo "  请创建空间: lark-cli wiki +space-create --name '我的知识库' --as user"
  exit 2
fi
ok "知识库空间: ${SPACE_NAME:-$SPACE_ID}"

echo ""

# === 2. 检查 knowledge/ 内容 ===
info "2. 检查 knowledge/ 内容"

MD_FILES=()
while IFS= read -r f; do
  MD_FILES+=("$f")
done < <(find "$KNOWLEDGE_DIR" -maxdepth 1 -name "*.md" -type f | sort)

if [ ${#MD_FILES[@]} -eq 0 ]; then
  warn "knowledge/ 目录下没有 md 文件，无需推送"
  exit 0
fi

echo "  发现 ${#MD_FILES[@]} 个文档:"
for f in "${MD_FILES[@]}"; do
  echo "    - $(basename "$f")"
done
echo ""

# === 3. 查找或创建父节点 ===
info "3. 创建父节点"

# 确定在哪个级别查找已有节点（根目录 或 指定父节点下）
SEARCH_PARENT="$TARGET_PARENT"

# 检查目标位置是否已有同名节点
EXISTING_PARENT=""
if [ -n "$SPACE_ID" ]; then
  if [ -n "$SEARCH_PARENT" ]; then
    NODES_JSON="$(lark-cli wiki +node-list --space-id "$SPACE_ID" --parent-node-token "$SEARCH_PARENT" --as user --format json --page-all 2>/dev/null || true)"
  else
    NODES_JSON="$(lark-cli wiki +node-list --space-id "$SPACE_ID" --as user --format json --page-all 2>/dev/null || true)"
  fi
  if [ -n "$NODES_JSON" ]; then
    PARENT_TITLE_FOR_PY="$PARENT_TITLE" EXISTING_PARENT="$(echo "$NODES_JSON" | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
title = os.environ.get('PARENT_TITLE_FOR_PY', '')
for n in d.get('data',{}).get('nodes',[]):
    if n.get('title') == title:
        print(n['node_token'])
        break
" 2>/dev/null || true)"
  fi
fi

if [ -n "$EXISTING_PARENT" ]; then
  warn "父节点已存在: $PARENT_TITLE (node_token=$EXISTING_PARENT)"
  PARENT_NODE="$EXISTING_PARENT"
  PARENT_URL=""
else
  if [ -n "$TARGET_PARENT" ]; then
    PARENT_RESULT="$(lark-cli wiki +node-create \
      --space-id "$SPACE_ID" \
      --parent-node-token "$TARGET_PARENT" \
      --title "$PARENT_TITLE" \
      --as user 2>/dev/null)"
  else
    PARENT_RESULT="$(lark-cli wiki +node-create \
      --space-id "$SPACE_ID" \
      --title "$PARENT_TITLE" \
      --as user 2>/dev/null)"
  fi
  PARENT_NODE="$(echo "$PARENT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('node_token',''))" 2>/dev/null || true)"
  PARENT_URL="$(echo "$PARENT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('url',''))" 2>/dev/null || true)"

  if [ -z "$PARENT_NODE" ]; then
    err "创建父节点失败"
    echo "$PARENT_RESULT"
    exit 1
  fi
  ok "已创建父节点: $PARENT_TITLE"
fi

echo ""

# === 4. 逐个推送文档 ===
info "4. 推送文档到飞书"

SUCCESS=0
FAIL=0
SKIP=0
ORPHAN_TOKENS=()  # 记录失败创建的孤儿节点 token，最后统一清理

# 退出前尝试清理孤儿节点（防止网络中断留下空节点）
cleanup_orphans() {
  if [ ${#ORPHAN_TOKENS[@]} -gt 0 ]; then
    warn "清理 ${#ORPHAN_TOKENS[@]} 个孤儿节点..."
    for tok in "${ORPHAN_TOKENS[@]}"; do
      lark-cli wiki +node-delete --node-token "$tok" --as user >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup_orphans EXIT

# 检查节点是否为空（防止重跑时跳过空节点导致永远写不进去）
is_node_empty() {
  local node_token="$1"
  # 飞书 API：获取文档内容。空文档返回空字符串或极短内容
  local content
  content="$(lark-cli docs +get --api-version v2 --doc "$node_token" --as user 2>/dev/null || echo "")"
  # 移除空白后判断长度（< 10 字符视为空）
  local stripped
  stripped="$(echo "$content" | tr -d '[:space:]')"
  [ "${#stripped}" -lt 10 ]
}

for md_file in "${MD_FILES[@]}"; do
  fname="$(basename "$md_file" .md)"
  # 用文件名作为节点标题（保留编号前缀保证排序）
  node_title="$fname"

  # 检查是否已有子节点
  EXISTING_CHILD=""
  if [ -n "$PARENT_NODE" ]; then
    CHILD_JSON="$(lark-cli wiki +node-list \
      --space-id "$SPACE_ID" \
      --parent-node-token "$PARENT_NODE" \
      --as user --format json 2>/dev/null || true)"
    if [ -n "$CHILD_JSON" ]; then
      NODE_TITLE_FOR_PY="$node_title" EXISTING_CHILD="$(echo "$CHILD_JSON" | python3 -c "
import json, sys, os
d = json.load(sys.stdin)
title = os.environ.get('NODE_TITLE_FOR_PY', '')
for n in d.get('data',{}).get('nodes',[]):
    if n.get('title') == title:
        print(n['node_token'])
        break
" 2>/dev/null || true)"
    fi
  fi

  # 已存在节点：检查是否为空；非空才跳过（防止孤儿节点永远写不进去）
  if [ -n "$EXISTING_CHILD" ]; then
    if is_node_empty "$EXISTING_CHILD"; then
      warn "[$fname] 节点已存在但内容为空（孤儿节点），重新写入"
      OBJ_TOKEN="$EXISTING_CHILD"
    else
      warn "[$fname] 节点已存在且有内容，跳过"
      SKIP=$((SKIP + 1))
      continue
    fi
  else
    # 创建子节点
    CHILD_RESULT="$(lark-cli wiki +node-create \
      --space-id "$SPACE_ID" \
      --parent-node-token "$PARENT_NODE" \
      --title "$node_title" \
      --as user 2>/dev/null)"

    OBJ_TOKEN="$(echo "$CHILD_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('obj_token',''))" 2>/dev/null || true)"

    if [ -z "$OBJ_TOKEN" ]; then
      err "[$fname] 创建节点失败"
      FAIL=$((FAIL + 1))
      continue
    fi
  fi

  # 写入 markdown 内容到节点关联文档
  # 使用 stdin 传入内容（--content -），markdown 格式
  if cat "$md_file" | lark-cli docs +update \
    --api-version v2 \
    --doc "$OBJ_TOKEN" \
    --command overwrite \
    --content - \
    --doc-format markdown \
    --as user >/dev/null 2>&1; then
    ok "[$fname] 推送成功"
    SUCCESS=$((SUCCESS + 1))
  else
    # 写入失败：记录 OBJ_TOKEN 用于稍后清理（孤儿节点）
    ORPHAN_TOKENS+=("$OBJ_TOKEN")
    # 大文件可能超限，尝试截断前 2000 行
    FILE_LINES=$(wc -l < "$md_file")
    if [ "$FILE_LINES" -gt 2000 ]; then
      warn "[$fname] 文件过大 (${FILE_LINES} 行)，尝试截断推送..."
      if head -2000 "$md_file" | lark-cli docs +update \
        --api-version v2 \
        --doc "$OBJ_TOKEN" \
        --command overwrite \
        --content - \
        --doc-format markdown \
        --as user >/dev/null 2>&1; then
        ok "[$fname] 截断推送成功 (${FILE_LINES} → 2000 行)"
        # 成功写入，从孤儿列表移除
        ORPHAN_TOKENS=("${ORPHAN_TOKENS[@]/$OBJ_TOKEN/}")
        SUCCESS=$((SUCCESS + 1))
      else
        err "[$fname] 推送失败（即使截断后），将作为孤儿节点清理"
        FAIL=$((FAIL + 1))
      fi
    else
      err "[$fname] 推送失败，将作为孤儿节点清理"
      FAIL=$((FAIL + 1))
    fi
  fi
done

# 显式禁用 EXIT trap 的清理（已经失败的就让它失败，不再清理）
trap - EXIT
# 主动清理孤儿节点
cleanup_orphans

echo ""
echo "==============================================="
echo "  推送完成"
echo "==============================================="
echo ""
echo "  空间: ${SPACE_NAME:-$SPACE_ID}"
echo "  父节点: $PARENT_TITLE"
echo "  父节点链接: ${PARENT_URL:-https://feishu.cn/wiki/$PARENT_NODE}"
echo ""
echo "  成功: $SUCCESS"
echo "  跳过: $SKIP (已存在)"
echo "  失败: $FAIL"
echo "  总计: ${#MD_FILES[@]}"
echo ""

if [ $FAIL -gt 0 ]; then
  warn "有 $FAIL 个文档推送失败，可重试: ./push_to_feishu.sh $OUT_DIR --space-id $SPACE_ID"
  exit 1
fi

ok "全部推送完成"
exit 0
