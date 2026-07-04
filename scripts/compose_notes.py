#!/usr/bin/env python3
"""把 whisper 转录稿 + 帧描述 → 结构化笔记。

两轮 prompt 调本地 qwen3:8b：
  第 1 轮：把转录按主题分段，给出 chapter 列表（标题/起止时间/要点）
  第 2 轮：对每个 chapter 重新组织成书面笔记 + 插入图片引用
  同时：生成 Mermaid 思维导图、概念速查表
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import subprocess
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
CAPTIONS_DIR = ROOT / "captions"
VISION_DIR = ROOT / "vision"
KNOWLEDGE_DIR = ROOT / "knowledge"
KNOWLEDGE_DIR.mkdir(exist_ok=True)
TRANSCRIPT_JSON = CAPTIONS_DIR / "full.json"
TRANSCRIPT_TXT = CAPTIONS_DIR / "full.txt"
VISION_MANIFEST = VISION_DIR / "frame_manifest.json"

OLLAMA_URL = "http://localhost:11434"
MODEL = os.environ.get("TEXT_MODEL", "qwen3:8b")


def ollama_chat(prompt: str, system: str = "", format_json: bool = False,
                timeout: int = 300, model: str = None, retries: int = 3) -> str:
    """通过 ollama chat API 调本地模型（关键：think:false 关闭 qwen3 thinking 模式）"""
    model = model or MODEL
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = {
        "model": model,
        "messages": messages,
        "stream": False,
        "think": False,  # 关键：关闭 qwen3 thinking 模式
        "options": {"temperature": 0.4, "num_ctx": 8192, "num_predict": 4000},
    }
    if format_json:
        payload["format"] = "json"
    last_err = None
    for attempt in range(retries + 1):
        try:
            proc = subprocess.run(
                ["curl", "-sS", "-m", str(timeout), "-X", "POST",
                 f"{OLLAMA_URL}/api/chat",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(payload)],
                capture_output=True, text=True, timeout=timeout + 60,
            )
            if proc.returncode != 0:
                last_err = f"curl rc={proc.returncode}: {proc.stderr[:200]}"
                time.sleep(4)
                continue
            try:
                body = json.loads(proc.stdout)
            except Exception as e:
                last_err = f"json: {e} out={proc.stdout[:200]}"
                time.sleep(4)
                continue
            if "error" in body:
                last_err = f"ollama error: {body['error'][:200]}"
                time.sleep(4)
                continue
            msg = body.get("message", {})
            text = (msg.get("content") or "").strip()
            if text:
                return text
            last_err = "empty response"
        except subprocess.TimeoutExpired:
            last_err = "timeout"
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"[:200]
        print(f"  ollama_chat retry {attempt+1}/{retries+1}: {last_err}", file=sys.stderr)
        time.sleep(4)
    raise RuntimeError(f"ollama_chat failed: {last_err}")


def load_transcript() -> list:
    """返回 [{start, end, text}] 段级时间戳"""
    if TRANSCRIPT_JSON.exists():
        data = json.loads(TRANSCRIPT_JSON.read_text())
        # whisper json 格式：{"text":..., "segments":[{start,end,text,...}]}
        if "segments" in data:
            return [
                {"start": seg["start"], "end": seg["end"], "text": seg["text"].strip()}
                for seg in data["segments"] if seg.get("text","").strip()
            ]
    if TRANSCRIPT_TXT.exists():
        # fallback: 无时间戳
        text = TRANSCRIPT_TXT.read_text().strip()
        return [{"start": 0.0, "end": 0.0, "text": text}]
    return []


def load_vision_manifest() -> list:
    if VISION_MANIFEST.exists():
        return json.loads(VISION_MANIFEST.read_text())
    return []


def align_vision_to_chapters(chapters: list, vision: list) -> dict:
    """把帧描述按时间分配到 chapter"""
    result = {i: [] for i in range(len(chapters))}
    for v in vision:
        ts = v.get("ts_sec", -1.0)
        if ts is None or ts < 0:
            continue
        # 找第一个 start ≤ ts ≤ end 的 chapter
        for i, ch in enumerate(chapters):
            if ch["start_sec"] <= ts <= ch["end_sec"]:
                result[i].append(v)
                break
    return result


SYSTEM_BRIEF = (
    "你是一位资深 AI 技术编辑，专门把口语化讲座视频改写成结构化技术笔记。"
    "要求：保留讲师原意但改写为书面中文，专业名词保留英文（如 Hermes、Function Calling、Agent、RAG）；"
    "使用 markdown 二级到四级标题；要点 bullet；时间戳标注章节起止。"
)


def fmt_ts(sec: float) -> str:
    if sec < 0:
        return ""
    h = int(sec // 3600); m = int(sec % 3600 // 60); s = int(sec % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def _try_parse_json_array(raw: str) -> list | None:
    """从 LLM 输出中健壮地提取 JSON 数组，支持对象→数组转换和常见格式修复"""
    # 1. 从 ```json ... ``` 代码块提取
    m = re.search(r"```(?:json)?\s*([\s\S]*?)\s*```", raw)
    if m:
        try:
            result = json.loads(m.group(1))
            if isinstance(result, list):
                return result
            if isinstance(result, dict):
                return [result]
        except json.JSONDecodeError:
            pass
    # 2. 直接 json.loads 整段
    try:
        result = json.loads(raw.strip())
        if isinstance(result, list):
            return result
        if isinstance(result, dict):
            return [result]
    except json.JSONDecodeError:
        pass
    # 3. 找最外层 [...] 或 {...}
    for pattern in [r"\[[\s\S]*\]", r"\{[\s\S]*\}"]:
        m = re.search(pattern, raw)
        if m:
            text = m.group(0)
            try:
                result = json.loads(text)
                if isinstance(result, list):
                    return result
                if isinstance(result, dict):
                    return [result]
            except json.JSONDecodeError:
                # 修复常见问题：尾部逗号、单引号
                text = re.sub(r",\s*([\]}])", r"\1", text)
                text = text.replace("'", '"')
                try:
                    result = json.loads(text)
                    if isinstance(result, list):
                        return result
                    if isinstance(result, dict):
                        return [result]
                except json.JSONDecodeError:
                    pass
    return None


def step1_segment(transcript_text: str, chunk_lines: int = 240) -> list:
    """分段策略：按 ~chunk_lines 行把转录分若干小批次，让 LLM 识别主题切换点。
    最后合并局部结果，给出全局章节切分。"""
    print("Step 1: 主题分段 (chunked) ...")
    lines = transcript_text.split("\n")
    chunks = []
    for i in range(0, len(lines), chunk_lines):
        chunks.append("\n".join(lines[i:i+chunk_lines]))
    print(f"  splitted into {len(chunks)} chunks, total {len(lines)} lines")

    # 让 LLM 给每个 chunk 提取 1-3 个"局部主题点"
    local_points = []  # {time_hms: str, topic: str, keywords: list}
    for ci, chunk in enumerate(chunks):
        prompt = f"""你是技术编辑。请阅读以下一段讲座转录（带时间戳 [HH:MM:SS]），
识别该段内 **1–3 个主题切换点**（即话题变化的位置）。

输出 JSON 数组，每项格式：
  {{"end_time_hms":"HH:MM:SS","end_time_sec":<秒>,"topic":"本段主题（5-12 字）"}}

规则：
- 只输出 JSON 数组，不要任何说明/注释
- 如果本段话题不变，只输出 1 项，end_time 取本段最后一句的时间戳
- end_time_sec 必须是从 `[HH:MM:SS]` 解析的秒数（float）

转录：
{chunk}
"""
        try:
            raw = ollama_chat(prompt, "", format_json=True, timeout=180, retries=2)
        except Exception as e:
            print(f"  chunk {ci}: ollama failed {e}; fallback to chunk-end")
            # fallback：取该 chunk 第一个时间戳 + 最后一个时间戳，输出 1 项
            ts_in_chunk = re.findall(r"\[(\d{2}:\d{2}:\d{2})\]", chunk)
            if ts_in_chunk:
                end_hms = ts_in_chunk[-1]
                end_sec = sum(int(x)*y for x,y in zip(end_hms.split(":"), (3600,60,1)))
                local_points.append({"end_time_hms": end_hms, "end_time_sec": end_sec,
                                       "topic": f"Chunk {ci+1}（fallback）"})
            continue
        arr = _try_parse_json_array(raw)
        if not arr:
            print(f"  chunk {ci}: no JSON array, raw={raw[:120]}...")
            continue
        for item in arr:
            try:
                sec = float(item.get("end_time_sec", 0))
                local_points.append({
                    "end_time_hms": item.get("end_time_hms","00:00:00"),
                    "end_time_sec": sec,
                    "topic": item.get("topic","").strip() or "(未命名)",
                })
            except (ValueError, TypeError):
                pass

    # 合并：按 end_time 升序，去重相邻 <60s 的点
    local_points.sort(key=lambda x: x["end_time_sec"])
    dedup = []
    for p in local_points:
        if not dedup or p["end_time_sec"] - dedup[-1]["end_time_sec"] >= 60:
            dedup.append(p)
    print(f"  local points: {len(local_points)} → dedup {len(dedup)}")

    # Fallback: 如果 LLM 分段失败，用时间等分策略（每 ~8 分钟一章）
    if not dedup:
        print("  ⚠ LLM 分段失败，使用时间等分策略 ...")
        ts_all = re.findall(r"\[(\d{2}:\d{2}:\d{2})\]", transcript_text)
        if ts_all:
            last_ts = ts_all[-1]
            total_sec = sum(int(x)*y for x,y in zip(last_ts.split(":"), (3600,60,1)))
        else:
            total_sec = 4000  # fallback ~67min
        chapter_count = max(6, min(10, total_sec // 480))
        interval = total_sec / chapter_count
        for i in range(chapter_count):
            s = i * interval
            e = (i + 1) * interval
            dedup.append({
                "end_time_hms": fmt_ts(e),
                "end_time_sec": e,
                "topic": f"第 {i+1} 章（{fmt_ts(s)}-{fmt_ts(e)}）",
            })
        chapters = []
        prev_end = 0
        for i, p in enumerate(dedup, 1):
            chapters.append({
                "idx": i, "title": p["topic"],
                "start_sec": prev_end, "end_sec": p["end_time_sec"],
                "bullets": [], "keywords": [],
            })
            prev_end = p["end_time_sec"]
        return chapters

    # 现在让 LLM 把这些局部点 + 上下文，整成 6-10 个章节
    points_str = "\n".join(f"- {p['end_time_hms']} ({p['end_time_sec']:.0f}s)：{p['topic']}"
                           for p in dedup)
    # 计算视频总时长（从转录最后一段的时间戳推算）
    last_ts = re.findall(r"\[(\d{2}:\d{2}:\d{2})\]", transcript_text)
    if last_ts:
        h, m, s = last_ts[-1].split(":")
        total_sec = int(h)*3600 + int(m)*60 + int(s)
    else:
        total_sec = 0
    total_min = total_sec // 60
    if total_min > 0:
        duration_desc = f"{total_min} 分钟"
    else:
        duration_desc = "一段"

    synth_prompt = f"""你是技术编辑。以下是一段 {duration_desc} 的视频讲座转录稿 **所有主题切换点的位置**。

请把这些点合并、概括为 **6–10 个章节**，每章给：
  - idx: 从 1 开始
  - title: 章节标题（突出技术点，10 字内）
  - start_sec, end_sec: 该章起止（秒），end_sec 必须取自上面的某一个时间点
  - bullets: 3–6 条核心要点（中文短句）
  - keywords: 关键技术名词（保留英文原写法，如 Hermes、Function Calling 等）

只输出 JSON 数组，不要任何额外说明：
```json
[{{"idx":1,"title":"...","start_sec":0,"end_sec":<某个切换时间>,"bullets":["..."],"keywords":["..."]}}, ...]
```

切换点列表（按时序）：
{points_str}
"""
    raw = ollama_chat(synth_prompt, SYSTEM_BRIEF, format_json=True, timeout=240, retries=3)
    chapters = _try_parse_json_array(raw)
    if not chapters:
        print(f"synthesize: no array, raw len={len(raw)}")
        # fallback：用 dedup 的点当章节
        chapters = []
        prev_end = 0
        for i, p in enumerate(dedup, 1):
            chapters.append({
                "idx": i, "title": p["topic"],
                "start_sec": prev_end, "end_sec": p["end_time_sec"],
                "bullets": [], "keywords": [],
            })
            prev_end = p["end_time_sec"]
        return chapters
    # 字段名兼容
    norm = []
    for c in chapters:
        s = c.get("start_sec", c.get("start", 0))
        e = c.get("end_sec", c.get("end", 0))
        try:
            s, e = float(s), float(e)
        except (ValueError, TypeError):
            continue
        norm.append({
            "idx": c.get("idx", len(norm)+1),
            "title": c.get("title", "").strip(),
            "start_sec": s,
            "end_sec": e,
            "bullets": c.get("bullets", []) if isinstance(c.get("bullets"), list) else [],
            "keywords": c.get("keywords", []) if isinstance(c.get("keywords"), list) else [],
        })
    # 排序 + 修正时间（end < start 处理）
    norm.sort(key=lambda c: c["start_sec"])
    for i, c in enumerate(norm):
        if i + 1 < len(norm):
            c["end_sec"] = min(c["end_sec"], norm[i+1]["start_sec"])
    return norm


def step2_write_chapter(ch, vision_in_window: list, transcript_text_window: str) -> str:
    """对单个章节改写为书面笔记 + 引用图"""
    print(f"  → 写章节 {ch['idx']}: {ch['title']}")
    images_md = ""
    if vision_in_window:
        bullets = []
        for v in vision_in_window:
            ts = v.get("ts_hms") or fmt_ts(v.get("ts_sec", 0))
            desc = v.get("description","").strip().split("\n")[0]
            bullets.append(f"![{ts}]({v['path']})  \n*{ts} 截图要点：{desc[:120]}*")
        images_md = "\n\n".join(bullets)

    prompt = f"""请把以下章节的口语化讲稿改写为结构化书面笔记。

章节信息：
 - 序号：{ch['idx']}
 - 标题：{ch['title']}
 - 时间：{fmt_ts(ch['start_sec'])} – {fmt_ts(ch['end_sec'])}
 - 关键要点：{json.dumps(ch.get('bullets', []), ensure_ascii=False)}
 - 技术名词：{json.dumps(ch.get('keywords', []), ensure_ascii=False)}

参考截图说明（按时间顺序，每张都对应当前章节内的视频帧）：
{images_md if images_md else "（本章无视觉素材）"}

对应讲稿片段（口语）：
{transcript_text_window[:6000]}

输出 markdown 格式笔记：
- 用 ## 起头（章节序号 + 标题）
- 一段概述（≤80 字）
- 核心要点 bullet（5–10 条）
- 每张参考截图用 markdown 图片语法插入合适位置，并附一句话场景注释
- 技术细节用代码块（如果讲到代码）
- 结尾给出 1–2 个"延伸思考"或"疑问"

不要输出章节标题以外的多余结构。"""
    return ollama_chat(prompt, SYSTEM_BRIEF, timeout=600)


def step3_mindmap(chapters: list) -> str:
    print("Step 3: 思维导图 ...")
    bullets = []
    for ch in chapters:
        bullets.append(f"- **{ch['title']}** ({fmt_ts(ch['start_sec'])}-{fmt_ts(ch['end_sec'])})："
                       + "; ".join(ch.get("bullets", [])[:3]))
    chapters_md = "\n".join(bullets)
    # 从目录名动态推导视频标题
    video_title = ROOT.name.replace("-知识库", "")
    prompt = f"""下面是一段视频讲座的章节大纲。请提炼出一张**两层到四层**的 Mermaid `mindmap`，
根节点是 "{video_title}"。

要求：
- 第一层：核心主题（3-6 个大分类）
- 第二层：每个核心主题下挂 2–5 个二级概念
- 第三层（可选）：再展开一两个细节
- 总节点数控制在 25–40 个
- 仅输出 ```mermaid ... ``` 代码块，不要前后说明

章节大纲：
{chapters_md}
"""
    return ollama_chat(prompt, SYSTEM_BRIEF, timeout=300)


def step4_glossary(chapters: list) -> str:
    print("Step 4: 概念速查 ...")
    kws = sorted({kw for ch in chapters for kw in ch.get("keywords", [])})
    if not kws:
        return ""
    prompt = f"""以下是从视频中提取的技术名词（按字母/拼音排序）。请生成一份**简明概念速查表**，
每条 1–2 句话定义，准确不超纲，必要时举例。

格式：markdown 表格

| 名词 | 类别 | 简明定义 |
|---|---|---|

名词列表：{', '.join(kws)}
"""
    return ollama_chat(prompt, SYSTEM_BRIEF, timeout=300)


def make_transcript_md(segments: list) -> str:
    """把 segments 转成带时间戳的 md 全文"""
    lines = ["# 01 完整转录稿（含时间戳）", "",
             f"_生成时间：{datetime.now().isoformat(timespec='seconds')}_", "",
             "<!-- 时:分:秒 — 原文 -->", ""]
    for seg in segments:
        ts = fmt_ts(seg["start"])
        lines.append(f"`{ts}` — {seg['text']}")
    return "\n".join(lines)


def main():
    print("Loading inputs ...")
    segments = load_transcript()
    vision = load_vision_manifest()
    print(f"  segments: {len(segments)}")
    print(f"  vision frames: {len(vision)}")
    if not segments:
        sys.exit("no transcript found")

    # 拼出章节用的 transcript_text（按段拼出）
    transcript_text = "\n".join(
        f"[{fmt_ts(s['start'])}] {s['text']}" for s in segments
    )

    # Step 1
    chapters = step1_segment(transcript_text)
    if not chapters:
        print("Step 1 failed; abort")
        return
    print(f"  chapters: {len(chapters)}")

    # 写完整转录稿（前置，不依赖 LLM）
    (KNOWLEDGE_DIR / "01-完整转录稿.md").write_text(
        make_transcript_md(segments), encoding="utf-8"
    )

    # 关联视觉描述到章节
    vision_map = align_vision_to_chapters(chapters, vision)

    # Step 2: 逐章改写
    body_parts = [
        "# 02 结构化笔记\n",
        f"_由 {MODEL} 自动整理自视频转录与截图_  ",
        f"_生成时间：{datetime.now().isoformat(timespec='seconds')}_\n",
        "---\n",
    ]
    for i, ch in enumerate(chapters):
        # 把窗口的 segments 文本拼出（前后 ±30s 也带上）
        s = ch["start_sec"]
        e = ch["end_sec"]
        win = [seg["text"] for seg in segments
               if seg["end"] >= s - 30 and seg["start"] <= e + 30]
        win_text = " ".join(win)
        md = step2_write_chapter(ch, vision_map.get(i, []), win_text)
        body_parts.append(md)
        body_parts.append("\n---\n")
    (KNOWLEDGE_DIR / "02-结构化笔记.md").write_text(
        "\n".join(body_parts), encoding="utf-8"
    )

    # Step 3
    mm = step3_mindmap(chapters)
    mm_doc = "# 03 思维导图\n\n支持 Mermaid 的渲染器（VS Code Markdown Preview Enhanced / GitHub / Obsidian）可直接渲染。\n\n```mermaid\n"
    m = re.search(r"```mermaid\s*(.*?)\s*```", mm, re.DOTALL)
    if m:
        mm_doc += m.group(1).strip() + "\n```\n"
    else:
        mm_doc += mm + "\n```\n"
    (KNOWLEDGE_DIR / "03-思维导图.md").write_text(mm_doc, encoding="utf-8")

    # Step 4
    gl = step4_glossary(chapters)
    gl_doc = "# 04 概念速查\n\n" + (gl or "（未生成）")
    (KNOWLEDGE_DIR / "04-概念速查.md").write_text(gl_doc, encoding="utf-8")

    print("\nDONE. Output:")
    for p in sorted(KNOWLEDGE_DIR.glob("*.md")):
        print(f"  {p.name}  ({p.stat().st_size//1024} KB)")


if __name__ == "__main__":
    main()
