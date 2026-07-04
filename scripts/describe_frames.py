#!/usr/bin/env python3
"""通过 ollama HTTP API 描述每张图（多线程并发）。

ollama 0.18 + 多模态模型用法：
  POST http://localhost:11434/api/generate
  JSON: {"model":"llava-phi3","prompt":"...","images":["<base64>"],"stream":false}

支持：
  - 并发描述（默认 4 路线程，M1 Pro 上 Metal GPU 排队执行，IO 部分并发节省 ~50% 时间）
  - 出错自动重试 2 次
  - 增量写盘（中断后可恢复，已完成帧 SKIP）
  - 通过环境变量 MAX_WORKERS 调整并发数（默认 4）
"""
import argparse
import json
import os
import sys
import time
import urllib.request
import subprocess
import tempfile
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from datetime import datetime
import threading

ROOT = Path(__file__).resolve().parent.parent
FRAMES_DIR = ROOT / "frames"
OUT_FILE = ROOT / "vision" / "frame_manifest.json"
OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

# 写盘锁（多线程安全）
WRITE_LOCK = threading.Lock()

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
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-workers", type=int,
                        default=int(os.environ.get("MAX_WORKERS", "4")),
                        help="并发线程数（默认 4，M1 Pro 推荐；Metal GPU 上 GPU 部分排队，IO 部分真正并发）")
    parser.add_argument("--frames-dir", type=Path, default=None, help="覆盖默认 frames 目录")
    args = parser.parse_args()

    frames_dir = args.frames_dir or FRAMES_DIR
    max_workers = max(1, args.max_workers)

    warmup_ollama()
    ts_map = get_video_ts_from_jsons()
    frames = sorted([p for p in frames_dir.glob("*.jpg") if not p.name.startswith(".")])

    existing = {}
    if OUT_FILE.exists():
        try:
            for item in json.loads(OUT_FILE.read_text()):
                fname = Path(item["path"]).name
                if "description" in item and item["description"]:
                    existing[fname] = item
        except Exception:
            pass

    # 跳过已完成的帧
    todo = [p for p in frames if p.name not in existing]
    skipped = [existing[p.name] for p in frames if p.name in existing]
    for item in skipped:
        print(f"SKIP {item['filename']}", flush=True)

    if not todo:
        print(f"\nDONE 0 new frames ({len(skipped)} already done). saved → {OUT_FILE}")
        return

    print(f"并发数: {max_workers}（待处理 {len(todo)} 帧，跳过 {len(skipped)} 帧）", flush=True)

    # 维护按文件名索引的结果字典（线程安全更新）
    result_map = {item["filename"]: item for item in skipped}
    completed_count = [0]  # 列表用于闭包修改
    total = len(todo)

    def describe_one(p: Path) -> dict:
        """单帧描述 + 立即写盘 + 返回 record"""
        t0 = time.time()
        desc = call_ollama_vision(p)
        cost = time.time() - t0
        ts = ts_map.get(p.name, -1.0)
        rel = f"frames/{p.name}"
        record = {
            "path": rel,
            "filename": p.name,
            "kind": "scene" if p.name.startswith("scene_") else "tick",
            "ts_sec": ts,
            "ts_hms": f"{int(ts//3600):02d}:{int(ts%3600//60):02d}:{int(ts%60):02d}" if ts >= 0 else None,
            "description": desc,
            "cost_sec": round(cost, 1),
            "model": VISION_MODEL,
            "at": datetime.now().isoformat(timespec="seconds"),
        }
        with WRITE_LOCK:
            result_map[p.name] = record
            completed_count[0] += 1
            # 按文件名排序后写盘（保证输出顺序稳定）
            ordered = sorted(result_map.values(),
                             key=lambda r: (0 if r["kind"] == "scene" else 1, r["filename"]))
            OUT_FILE.write_text(json.dumps(ordered, ensure_ascii=False, indent=2))
            snippet = desc[:80].replace("\n", " ")
            print(f"[{completed_count[0]}/{total}] {p.name} ts={record['ts_hms']} ({cost:.1f}s) :: {snippet}...", flush=True)
        return record

    # 多线程并发（IO/网络部分真正并行，GPU 部分 Metal 排队）
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(describe_one, p): p for p in todo}
        for fut in as_completed(futures):
            p = futures[fut]
            try:
                fut.result()
            except Exception as e:
                err_record = {
                    "path": f"frames/{p.name}",
                    "filename": p.name,
                    "kind": "scene" if p.name.startswith("scene_") else "tick",
                    "ts_sec": ts_map.get(p.name, -1.0),
                    "ts_hms": None,
                    "description": f"[EXCEPTION] {type(e).__name__}: {e}"[:300],
                    "cost_sec": 0.0,
                    "model": VISION_MODEL,
                    "at": datetime.now().isoformat(timespec="seconds"),
                }
                with WRITE_LOCK:
                    result_map[p.name] = err_record
                    completed_count[0] += 1
                print(f"[{completed_count[0]}/{total}] {p.name} :: {err_record['description'][:80]}", flush=True)

    print(f"\nDONE {len(result_map)} frames (new={completed_count[0]}, skipped={len(skipped)}). saved → {OUT_FILE}")


if __name__ == "__main__":
    main()
