#!/usr/bin/env python3
"""
create_anki_cards.py — 从 knowledge/*.md 提取知识点，生成 Anki 卡片并上传

用法：
    python3 create_anki_cards.py [--deck NAME] [--dry-run] [--json-only]

数据来源：
    - knowledge/04-概念速查.md          → 概念卡片（表格解析）
    - knowledge/99-整合·全知识库.md      → 扩展概念速查 + Q&A 附录

输出：
    - AnkiConnect API 上传到本地 Anki
    - 或 knowledge/anki_cards.json（离线回退）
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import urllib.request
import urllib.error
from pathlib import Path

# ── 路径 ──────────────────────────────────────────────────────────
ROOT = Path(__file__).resolve().parent.parent
KNOWLEDGE_DIR = ROOT / "knowledge"

# ── AnkiConnect ───────────────────────────────────────────────────
ANKI_CONNECT_URL = "http://127.0.0.1:8765"
MODEL_NAME = "视频知识库"
DEFAULT_DECK_PREFIX = "视频知识库"


# ── Markdown 解析 ─────────────────────────────────────────────────

def parse_glossary_table(text: str) -> list[dict]:
    """解析 Markdown 表格：| 名词 | 类别 | 简明定义 |"""
    cards = []
    lines = text.split("\n")
    in_table = False
    for line in lines:
        line = line.strip()
        if line.startswith("| 名词") and "| 类别" in line:
            in_table = True
            continue
        if in_table and line.startswith("|---"):
            continue
        if in_table and line.startswith("|"):
            parts = [p.strip() for p in line.split("|")]
            # parts: ['', '名词', '类别', '定义', '']
            if len(parts) >= 4 and parts[1]:
                term = parts[1].strip()
                category = parts[2].strip()
                definition = parts[3].strip()
                if term and definition and term != "名词":
                    cards.append({
                        "front": f"什么是 {term}？",
                        "back": definition,
                        "tags": [category] if category else [],
                        "source": "概念速查",
                        "category": category,
                    })
        elif in_table and not line.startswith("|"):
            in_table = False
    return cards


def parse_qa_section(text: str) -> list[dict]:
    """解析 99-整合·全知识库.md 的 Q&A 附录（## 附录：Q&A 环节精选实践问答）"""
    cards = []
    # 找到 Q&A 附录部分
    qa_match = re.search(r"## 附录：Q&A 环节精选实践问答\n(.*?)(?=\n---|\n# |\Z)", text, re.DOTALL)
    if not qa_match:
        return cards

    qa_text = qa_match.group(1)
    # 每个 ### 标题是一个 Q&A
    sections = re.split(r"### ", qa_text)
    for section in sections[1:]:  # skip preamble
        lines = section.strip().split("\n")
        if not lines:
            continue
        question = lines[0].strip().rstrip("？?") + "？"
        # 收集 bullet points 作为回答
        answer_lines = []
        for line in lines[1:]:
            line = line.strip()
            if line.startswith("- "):
                # 清理 markdown bold
                cleaned = re.sub(r"\*\*(.*?)\*\*", r"\1", line[2:])
                answer_lines.append(cleaned.strip())
            elif line.startswith("  ") and answer_lines:
                # 缩进续行
                cleaned = re.sub(r"\*\*(.*?)\*\*", r"\1", line).strip()
                if cleaned.startswith("- "):
                    cleaned = cleaned[2:]
                answer_lines[-1] += " " + cleaned

        if question and answer_lines:
            # HTML escape each answer line, then format as list
            escaped_lines = [html.escape(l, quote=False) for l in answer_lines]
            answer_html = "<ul>" + "".join(f"<li>{l}</li>" for l in escaped_lines) + "</ul>"
            cards.append({
                "front": question,
                "back": answer_html,
                "tags": ["Q&A"],
                "source": "Q&A 环节",
                "category": "Q&A",
            })
    return cards


def md_to_html(text: str) -> str:
    """简单 Markdown → HTML（bold, italic, code, lists）"""
    # 先转义 HTML 实体，防止注入
    text = html.escape(text, quote=False)
    # code blocks
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    # bold
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    # italic
    text = re.sub(r"\*(.+?)\*", r"<i>\1</i>", text)
    # bullet lists
    lines = text.split("\n")
    result = []
    in_list = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- "):
            if not in_list:
                result.append("<ul>")
                in_list = True
            result.append(f"<li>{stripped[2:]}</li>")
        else:
            if in_list:
                result.append("</ul>")
                in_list = False
            result.append(stripped)
    if in_list:
        result.append("</ul>")
    return "\n".join(result)


# ── AnkiConnect API ───────────────────────────────────────────────

def anki_request(action: str, **params) -> dict | None:
    """发送 AnkiConnect JSON-RPC 请求"""
    payload = json.dumps({
        "action": action,
        "version": 6,
        "params": params,
    }).encode("utf-8")

    try:
        req = urllib.request.Request(
            ANKI_CONNECT_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("error"):
                print(f"  AnkiConnect error: {data['error']}", file=sys.stderr)
            return data
    except (urllib.error.URLError, ConnectionRefusedError, OSError) as e:
        print(f"  AnkiConnect connection error: {e}", file=sys.stderr)
        return None


def check_anki_connect() -> bool:
    """检查 AnkiConnect 是否可用"""
    result = anki_request("version")
    return result is not None and result.get("result") is not None


def ensure_deck(deck_name: str) -> bool:
    """创建 deck（幂等）"""
    result = anki_request("createDeck", deck=deck_name)
    return result is not None and result.get("error") is None


def ensure_model() -> bool:
    """创建自定义 Note Type（幂等）"""
    # 先检查是否已存在
    models = anki_request("modelNames")
    if models and MODEL_NAME in (models.get("result") or []):
        return True

    result = anki_request("createModel", **{
        "modelName": MODEL_NAME,
        "inOrderFields": ["问题", "回答", "来源", "分类"],
        "cardTemplates": [
            {
                "Name": "回忆",
                "Front": '{{问题}}',
                "Back": "{{FrontSide}}<hr id='answer'>{{回答}}<br><small style='color:#888'>{{来源}}</small>",
            },
        ],
        "css": """
.card {
    font-family: 'PingFang SC', 'Noto Sans SC', 'Microsoft YaHei', sans-serif;
    font-size: 16px;
    text-align: left;
    color: #333;
    padding: 20px;
    max-width: 600px;
    margin: 0 auto;
}
.card h1 { font-size: 20px; margin-bottom: 10px; }
.card ul { padding-left: 20px; }
.card li { margin-bottom: 4px; }
.card code { background: #f4f4f4; padding: 2px 4px; border-radius: 3px; }
.card b { color: #1a5276; }
""",
        "isCloze": False,
    })
    return result is not None and result.get("error") is None


def add_notes(deck_name: str, cards: list[dict], video_tag: str) -> dict:
    """批量添加卡片，返回统计。使用 canAddNotes 预检去重。"""
    notes = []
    for card in cards:
        tags = [video_tag] + card.get("tags", [])
        # 清理 tag 中的空格和特殊字符
        tags = [re.sub(r"[^\w\u4e00-\u9fff]", "_", t) for t in tags if t]
        notes.append({
            "deckName": deck_name,
            "modelName": MODEL_NAME,
            "fields": {
                "问题": card["front"],
                "回答": card["back"],
                "来源": card.get("source", ""),
                "分类": card.get("category", ""),
            },
            "tags": tags,
            "options": {
                "allowDuplicate": False,
                "duplicateScope": "deck",
                "duplicateScopeOptions": {
                    "deckName": deck_name,
                    "checkChildren": False,
                    "checkAllModels": False,
                },
            },
        })

    # Step 1: 预检哪些可以添加（非重复）
    can_check = anki_request("canAddNotes", notes=notes)
    if can_check is None or can_check.get("error") is not None:
        return {"success": 0, "failed": len(notes), "skipped": 0}

    can_add = can_check.get("result") or []
    # Step 2: 只添加非重复的
    new_notes = [n for n, ok in zip(notes, can_add) if ok]
    skipped = len(notes) - len(new_notes)

    if not new_notes:
        return {"success": 0, "failed": 0, "skipped": skipped}

    result = anki_request("addNotes", notes=new_notes)
    if result is None:
        return {"success": 0, "failed": len(new_notes), "skipped": skipped}

    note_ids = result.get("result") or []
    success = sum(1 for nid in note_ids if nid is not None)
    failed = len(new_notes) - success
    return {"success": success, "failed": failed, "skipped": skipped}


# ── 主流程 ────────────────────────────────────────────────────────

def extract_all_cards() -> list[dict]:
    """从 knowledge/*.md 提取所有卡片"""
    all_cards = []

    # 1. 04-概念速查.md（简单版，4 条）
    f04 = KNOWLEDGE_DIR / "04-概念速查.md"
    if f04.exists():
        cards = parse_glossary_table(f04.read_text("utf-8"))
        print(f"  04-概念速查.md: {len(cards)} 张概念卡片")
        all_cards.extend(cards)

    # 2. 99-整合·全知识库.md
    f99 = KNOWLEDGE_DIR / "99-整合·全知识库.md"
    if f99.exists():
        text99 = f99.read_text("utf-8")

        # 2a. 扩展概念速查表（36 条，与 04 同格式但条目更多）
        expanded = parse_glossary_table(text99)
        # 去重：只保留 04 中不存在的词条
        existing_terms = {c["front"] for c in all_cards}
        new_expanded = [c for c in expanded if c["front"] not in existing_terms]
        if new_expanded:
            print(f"  99-整合概念速查: {len(new_expanded)} 张新卡片（{len(expanded)} 总 / {len(expanded) - len(new_expanded)} 重复跳过）")
            all_cards.extend(new_expanded)
        else:
            print(f"  99-整合概念速查: 0 张新卡片（{len(expanded)} 条全部已在 04 中）")

        # 2b. Q&A 附录
        qa_cards = parse_qa_section(text99)
        print(f"  99-Q&A 附录: {len(qa_cards)} 张 Q&A 卡片")
        all_cards.extend(qa_cards)

    return all_cards


def main():
    parser = argparse.ArgumentParser(description="从知识库生成 Anki 卡片")
    parser.add_argument("--deck", default=None, help="Deck 名称（默认：视频知识库::<video-stem>）")
    parser.add_argument("--dry-run", action="store_true", help="只生成卡片不上传")
    parser.add_argument("--json-only", action="store_true", help="只导出 JSON 不上传")
    args = parser.parse_args()

    print(f"知识库目录: {KNOWLEDGE_DIR}")
    if not KNOWLEDGE_DIR.exists():
        print(f"错误: 知识库目录不存在: {KNOWLEDGE_DIR}", file=sys.stderr)
        sys.exit(1)

    # 提取卡片
    print("\n提取卡片...")
    cards = extract_all_cards()
    print(f"\n总计: {len(cards)} 张卡片")

    if not cards:
        print("没有提取到任何卡片", file=sys.stderr)
        sys.exit(1)

    # 确定 deck 名称
    video_stem = ROOT.name.replace("-知识库", "")
    deck_name = args.deck or f"{DEFAULT_DECK_PREFIX}::{video_stem}"

    # 导出 JSON
    json_path = KNOWLEDGE_DIR / "anki_cards.json"
    export_data = {
        "deck": deck_name,
        "model": MODEL_NAME,
        "cards": cards,
    }
    json_path.write_text(json.dumps(export_data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"JSON 已导出: {json_path}")

    if args.json_only:
        print("（--json-only 模式，跳过上传）")
        sys.exit(0)

    if args.dry_run:
        print(f"\n[DRY RUN] 将上传 {len(cards)} 张卡片到 deck: {deck_name}")
        for i, c in enumerate(cards[:5]):
            print(f"  {i+1}. Q: {c['front'][:50]}...")
            print(f"     A: {c['back'][:80]}...")
        if len(cards) > 5:
            print(f"  ... 还有 {len(cards) - 5} 张")
        sys.exit(0)

    # 检查 AnkiConnect
    print(f"\n检查 AnkiConnect ({ANKI_CONNECT_URL})...")
    if not check_anki_connect():
        print("AnkiConnect 不可达！", file=sys.stderr)
        print("请确保：", file=sys.stderr)
        print("  1. Anki 已启动", file=sys.stderr)
        print("  2. AnkiConnect 插件已安装（addon code: 2055492159）", file=sys.stderr)
        print("  3. Anki 已重启以加载插件", file=sys.stderr)
        print(f"\n卡片已导出到: {json_path}", file=sys.stderr)
        print("可手动导入 JSON 到 Anki", file=sys.stderr)
        sys.exit(2)

    # 创建 deck 和 model
    print(f"创建 deck: {deck_name}")
    if not ensure_deck(deck_name):
        print(f"创建 deck 失败: {deck_name}", file=sys.stderr)
        sys.exit(1)

    print(f"创建 Note Type: {MODEL_NAME}")
    if not ensure_model():
        print(f"创建 Note Type 失败: {MODEL_NAME}", file=sys.stderr)
        sys.exit(1)

    # 上传卡片
    video_tag = re.sub(r"[^\w\u4e00-\u9fff]", "_", video_stem)
    print(f"\n上传 {len(cards)} 张卡片...")
    stats = add_notes(deck_name, cards, video_tag)
    print(f"\n结果: 成功 {stats['success']} / 跳过(重复) {stats['skipped']} / 失败 {stats['failed']} / 总计 {len(cards)}")

    if stats["success"] > 0 or stats["skipped"] > 0:
        print(f"\n✓ Anki 卡片已就绪！打开 Anki → deck: {deck_name}")
    elif stats["failed"] > 0:
        print(f"\n⚠ 部分卡片上传失败，JSON 备份在: {json_path}")


if __name__ == "__main__":
    main()
