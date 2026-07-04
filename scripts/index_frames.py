#!/usr/bin/env python3
"""把 vision/frame_manifest.json 转成 markdown 时间索引（嵌图片）。
输出位置：knowledge/00-帧索引.md
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "vision" / "frame_manifest.json"
OUT = ROOT / "knowledge" / "00-帧索引.md"

# 如果存在 .tmp 后缀的占位文件，先删掉
tmp = OUT.with_suffix(".md.tmp")
if tmp.exists():
    tmp.unlink()

def fmt_ts(sec):
    if sec is None or sec < 0:
        return "??:??:??"
    h = int(sec // 3600); m = int(sec % 3600 // 60); s = int(sec % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

def main():
    if not MANIFEST.exists():
        print("no manifest"); return
    items = json.loads(MANIFEST.read_text())
    items.sort(key=lambda x: (x.get("ts_sec") or -1, x.get("filename","")))

    lines = [
        "# 00 视频关键帧时间索引",
        "",
        "> 自动按视频时间戳排序。点图片可放大查看；对应视频位置见 `HH:MM:SS`。",
        "",
        f"_共 {len(items)} 张图 — 场景切换 {sum(1 for x in items if x.get('kind')=='scene')} 张，间隔采样 {sum(1 for x in items if x.get('kind')=='tick')} 张_",
        "",
        "| 时间 | 类型 | 画面要点 |",
        "|---|---|---|",
    ]
    for it in items:
        ts = fmt_ts(it.get("ts_sec"))
        kind = "场景" if it.get("kind") == "scene" else "采样"
        fname = it.get("filename", "")
        rel = it.get("path", "")
        desc = (it.get("description","") or "").replace("\n"," ").replace("|","\\|").strip()
        if desc.startswith("[ERROR]"):
            desc = "_[视觉理解失败，跳过]_"
        desc_short = desc[:200] + ("..." if len(desc) > 200 else "")
        lines.append(f"| `{ts}` | {kind} | ![{ts}]({rel})<br>{desc_short} |")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT} ({len(items)} rows)")


if __name__ == "__main__":
    main()
