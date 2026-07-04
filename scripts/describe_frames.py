#!/usr/bin/env python3
"""通过 ollama HTTP API 描述每张图。

ollama 0.18 + 多模态模型用法：
  POST http://localhost:11434/api/generate
  JSON: {"model":"llava-phi3","prompt":"...","images":["<base64>"],"stream":false}

支持：
  - 单帧描述进度显示
  - 出错自动重试 2 次
  - 增量写盘（中断后可恢复）
"""
import json
import os
import sys
import time
import urllib.request
import subprocess
import tempfile
import base64
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
FRAMES_DIR = ROOT / "frames"
OUT_FILE = ROOT / "vision" / "frame_manifest.json"
OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

PROMPT = (
    "请用中文详细描述这张图片的内容。"
    "如果是 PPT 页面，请按页描述：标题、要点 bullet、表格内容、页码；"
    "如果是代码/终端截图，请保留关键代码片段；"
    "如果是架构图/流程图，请列出图中的模块名、组件和连接关系；"
    "如果是人物演讲，请描述人物外观与现场情况。"
    "输出简洁，但技术名词必须完整保留原始英文写法（如 Hermes、Function Calling、JSON、API、LLM、RAG、Agent 等）。"
)

OLLAMA_URL = "http://localhost:11434"
VISION_MODEL = os.environ.get("VISION_MODEL", "llava-phi3")


def warmup_ollama():
    """首次加载模型较慢，预热一次避免首张 502。直接用 curl。"""
    try:
        proc = subprocess.run(
            ["curl", "-sS", "-m", "120", "-X", "POST",
             f"{OLLAMA_URL}/api/generate",
             "-H", "Content-Type: application/json",
             "-d", json.dumps({"model": VISION_MODEL, "prompt": "ok", "stream": False})],
            capture_output=True, text=True, timeout=140,
        )
        if proc.returncode == 0 and '"response"' in proc.stdout:
            print("ollama warmup OK")
        else:
            print(f"warmup failed: rc={proc.returncode}, stdout={proc.stdout[:200]}", file=sys.stderr)
    except Exception as e:
        print(f"warmup exception: {e}", file=sys.stderr)


def call_ollama_vision(image_path: Path, retries: int = 3, timeout: int = 180) -> str:
    img_b64 = base64.b64encode(image_path.read_bytes()).decode()
    payload = {
        "model": VISION_MODEL,
        "prompt": PROMPT,
        "images": [img_b64],
        "stream": False,
        "options": {"num_predict": 400, "temperature": 0.2},
    }
    last_err = None
    for attempt in range(retries + 1):
        try:
            proc = subprocess.run(
                ["curl", "-sS", "-m", str(timeout), "-X", "POST",
                 f"{OLLAMA_URL}/api/generate",
                 "-H", "Content-Type: application/json",
                 "-d", json.dumps(payload)],
                capture_output=True, text=True, timeout=timeout + 30,
            )
            if proc.returncode != 0:
                last_err = f"curl rc={proc.returncode}: {proc.stderr[:200]}"
            else:
                try:
                    body = json.loads(proc.stdout)
                except Exception as e:
                    last_err = f"json parse: {e} out={proc.stdout[:200]}"
                else:
                    if "error" in body:
                        last_err = f"ollama error: {body['error'][:200]}"
                    else:
                        text = body.get("response", "").strip()
                        if text:
                            return text
                        last_err = "empty response"
        except subprocess.TimeoutExpired:
            last_err = "timeout"
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"[:200]
        print(f"  retry {attempt+1}/{retries+1}: {last_err}", file=sys.stderr)
        time.sleep(4)
    return f"[ERROR] {last_err or 'unknown'}, retries={retries+1}"


def get_video_ts_from_jsons() -> dict:
    """返回 {filename: ts_sec} 合并的 scene + tick 时间戳"""
    out = {}
    for p in [FRAMES_DIR / ".scene_timestamps.json", FRAMES_DIR / ".tick_timestamps.json"]:
        if p.exists():
            for item in json.loads(p.read_text()):
                fname = Path(item["file"]).name
                out[fname] = item["pts_time"]
    return out


def main():
    warmup_ollama()
    ts_map = get_video_ts_from_jsons()
    frames = sorted([p for p in FRAMES_DIR.glob("*.jpg") if not p.name.startswith(".")])

    existing = {}
    if OUT_FILE.exists():
        try:
            for item in json.loads(OUT_FILE.read_text()):
                fname = Path(item["path"]).name
                if "description" in item and item["description"]:
                    existing[fname] = item
        except Exception:
            pass

    result = []
    for i, p in enumerate(frames, 1):
        rel = f"frames/{p.name}"
        if p.name in existing:
            print(f"[{i}/{len(frames)}] SKIP {p.name}", flush=True)
            result.append(existing[p.name])
            continue
        print(f"[{i}/{len(frames)}] DESCRIBE {p.name} ...", flush=True)
        t0 = time.time()
        desc = call_ollama_vision(p)
        cost = time.time() - t0
        ts = ts_map.get(p.name)
        if ts is None:
            ts = -1.0
        result.append({
            "path": rel,
            "filename": p.name,
            "kind": "scene" if p.name.startswith("scene_") else "tick",
            "ts_sec": ts,
            "ts_hms": f"{int(ts//3600):02d}:{int(ts%3600//60):02d}:{int(ts%60):02d}" if ts >= 0 else None,
            "description": desc,
            "cost_sec": round(cost, 1),
            "model": VISION_MODEL,
            "at": datetime.now().isoformat(timespec="seconds"),
        })
        OUT_FILE.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        # 顺手打印一段摘要
        snippet = desc[:80].replace("\n", " ")
        print(f"    ts={result[-1]['ts_hms']} ({cost:.1f}s) :: {snippet}...")

    print(f"\nDONE {len(result)} frames. saved → {OUT_FILE}")


if __name__ == "__main__":
    main()
