# video-to-knowledge-base

把任意视频文件（mp4/mov/mkv）转换成本地知识库 —— **全部本地处理**，无需云端 API。

## 适用场景

- 📚 技术讲座 / 课程视频 → 学习笔记
- 🎙️ 会议录像 / 录播分享 → 知识库
- 🎬 教程视频 → 文档化
- 🗣️ 播客录音（带视频）→ 字幕 + 笔记

## 性能

| 视频时长 | 1080p H264 | medium 默认 | large 最高质量 | 硬件 |
|---|---|---|---|---|
| 5 分钟 | 短样本 | ~1 分钟 | ~2 分钟 | M1 Pro |
| 30 分钟 | 中等 | ~7 分钟 | ~12 分钟 | M1 Pro |
| 67 分钟 | 长讲座 | ~25-30 分钟 | ~40 分钟 | M1 Pro |

**默认模型 `ggml-medium-q5_0`**：质量比 large 略降但速度快 ~1.8×，适合大多数场景。

## 快速开始

### 一键运行（本地 pipeline）

```bash
# 1. 装依赖（一次性）
brew install ffmpeg whisper-cpp

# 2. 下载 whisper 模型（一次性，默认 medium，~514MB）
mkdir -p ~/.cache/whisper.cpp
curl -L -o ~/.cache/whisper.cpp/ggml-medium-q5_0.bin \
  "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"
# 如需最高质量，下 large（~1GB）：
# curl -L -o ~/.cache/whisper.cpp/ggml-large-v3-q5_0.bin \
#   "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"

# 3. 跑本地 pipeline（Steps 1-4）
./scripts/pipeline.sh /path/to/your-video.mp4 --to-step 4 --skip-feishu --skip-anki
```

输出在 `<视频目录>/<视频名>-知识库/`。

### 通过 QoderWork 完成后续步骤

在 QoderWork 中让远程模型处理 Steps 5-7（视觉理解+结构化笔记+整合），质量远超本地小模型。

```
"帮我用 video-to-knowledge-base skill 处理 /path/to/video.mp4"
```

QoderWork 会自动调用此 skill，本地完成 Steps 1-4 后用远程模型完成 Steps 5-7。

## 输出示例

```
Agent架构选型-Hermes深度解析-知识库/
├── README.md                          入口
├── audio/full.wav                     123 MB wav
├── captions/
│   ├── full.srt / .vtt / .txt / .csv / .lrc / .json
├── frames/                            80 张 jpg
├── vision/frame_manifest.json
├── knowledge/
│   ├── 00-帧索引.md                   46 张图按时间
│   ├── 01-完整转录稿.md               912 段转录
│   ├── 02-结构化笔记.md               9 章节
│   ├── 03-思维导图.md                 Mermaid
│   ├── 04-概念速查.md
│   └── 99-整合·全知识库.md            ★ 整合版
└── scripts/                           处理脚本
```

## 9 步 Pipeline

**本地执行（不依赖任何模型）：**
1. **环境检查** - 验证 ffmpeg / whisper.cpp
2. **抽音轨** - ffmpeg → 16kHz wav
3. **转录** - whisper.cpp + Metal GPU（4.7× 实时）
4. **抽帧** - ffmpeg 场景切换 + 间隔保底

**外部模型（QoderWork 远程，推荐）：**
5. **视觉理解** - 描述每张关键帧的内容
6. **结构化笔记** - 主题切分 + 改写为书面笔记
7. **整合** - 帧索引 + 整合版

**API 集成（可选）：**
8. **飞书推送** - 推送到飞书知识库
9. **Anki 闪卡** - 生成 Anki 卡片并上传

> 如需完全离线运行，可安装 ollama + llava-phi3 + qwen3:8b 作为 fallback（质量较低）。

## 高级用法

### 自定义输出位置

```bash
./scripts/pipeline.sh video.mp4 --output /custom/path
```

### 跳过某些步骤

```bash
# 跳过抽帧和视觉理解（只想要字幕+笔记）
./scripts/pipeline.sh video.mp4 --skip-frames

# 跳过笔记（只要转录）
./scripts/pipeline.sh video.mp4 --skip-notes --skip-frames

# 跳过飞书推送和 Anki（只做本地处理）
./scripts/pipeline.sh video.mp4 --skip-feishu --skip-anki
```

### 跑中间步骤

```bash
# 只跑 step 3 (转录) 和 step 6 (笔记)
./scripts/pipeline.sh video.mp4 --from-step 3 --to-step 6
```

### 模型选择

通过 `--model-size` 简写：

```bash
# 默认（推荐）：质量+速度平衡
./scripts/pipeline.sh video.mp4 --model-size balanced

# 最高质量（速度慢 ~1.8×）
./scripts/pipeline.sh video.mp4 --model-size quality

# 极速（适合超长视频先看个大概）
./scripts/pipeline.sh video.mp4 --model-size fast
```

或显式指定模型名 + processors：

```bash
./scripts/pipeline.sh video.mp4 --whisper-model ggml-large-v3-q5_0 --processors 4 --threads 8
```

### 单步独立执行

```bash
# 抽音轨
./scripts/extract_audio.sh video.mp4 audio.wav

# 转录
./scripts/transcribe.sh audio.wav captions/

# 抽帧
./scripts/extract_frames.sh video.mp4 frames/

# 视觉理解
python3 scripts/describe_frames.py

# 笔记
python3 scripts/compose_notes.py
```

## 性能调优

| 优化 | 提速 | 副作用 |
|---|---|---|
| `-t 8` 线程全开 | 1.3-1.5x | 无 |
| `-p 4` 多 processor | 1.5-2x | RAM 翻倍（~4GB）|
| 模型 medium-q5_0（默认） | ~1.8x | 中文错字略增（仍可用）⭐ |
| 模型 small-q5_1 | ~4x | 中文显著降（漏段、错字）|
| 模型 base-q5_1 | ~8x | 中文几乎不可用 ❌ |

M1 Pro 16GB 推荐：`-t 8 -p 4` + `ggml-medium-q5_0`（默认）。

## 故障排查

跑 `./scripts/env_check.sh` 看哪个依赖缺。

| 问题 | 原因 | 解决 |
|---|---|---|
| whisper-cli 一直 0 输出 | 用了 Python whisper | 用 whisper-cli 二进制 |
| `ollama run llava-phi3` 502 | Python urllib 在 sandbox 下挂 | 用 curl 调 `/api/generate` |
| qwen3:8b response 为空 | 默认 thinking 模式 | 用 `/api/chat` + `think:false` |
| 抽帧时间戳乱 | 输出名不带 pts | 加 `-frame_pts true` + 解析 showinfo |
| 视觉描述幻觉 | llava-phi3 3.8B 太小 | 手动 review 或换更大模型 |
| 磁盘不足 | 模型 5GB+ | 至少 15GB 空闲 |

## 重跑

所有步骤**幂等**：
- 抽帧：覆盖式
- 转录：覆盖式
- 视觉描述：跳过已 OK 的帧
- 笔记：覆盖式

可单独重跑任意步骤而不破坏其他产物。

## 配合第二大脑

跑完视频后，可把 `knowledge/` 下的笔记摄取到第二大脑：

```
"用 second-brain-ingest 处理 /path/to/视频-知识库/knowledge/ 下的 markdown"
```

## 依赖版本

- macOS 14+ (Apple Silicon 强烈推荐)
- ffmpeg 8+
- whisper.cpp 1.7+
- ollama 0.18+
- Python 3.9+
- 磁盘：15GB 空闲（首次安装 + 模型）
