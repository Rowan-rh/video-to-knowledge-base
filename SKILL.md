---
name: video-to-knowledge-base
description: >
  Convert a video file (mp4/mov/mkv) into a complete local knowledge base:
  audio transcript + keyframe extraction + visual understanding + structured
  notes + mindmap + concept glossary. Audio/visual processing is 100% local
  on Apple Silicon (Metal GPU). Structured notes can use local LLM or remote
  model (QoderWork). Optionally push the knowledge base to Feishu wiki.
  Optionally generate Anki flashcards from extracted knowledge points and
  upload to local Anki via AnkiConnect.
  Use when the user says any of:
  - "把这个视频转成知识库" / "转录这个视频" / "视频转录+笔记"
  - "做一份视频学习资料" / "做视频笔记" / "提取视频要点" / "视频摘要"
  - "把视频做成 Markdown 笔记" / "Obsidian 笔记" / "思维导图"
  - "推送到飞书知识库" / "同步到飞书 wiki" / "飞书云文档"
  - "生成 Anki 卡片" / "Anki 闪卡" / "记忆卡片"
  - "视频转 PPT 大纲" / "导出课程讲义" / "讲座整理"
  - ingest a lecture / meeting / tutorial video into markdown notes,
    sync to Feishu, or create Anki flashcards.
  Triggers on any video file path passed as argument.
allowed-tools: Bash Read Write Edit Glob Grep Task
---

# Video → Knowledge Base

把任意视频文件转换成本地知识库。音视频处理全部本地执行，结构化笔记可选本地或远程模型。

## What you get

输出目录（默认在视频同名的 `*-知识库/` 文件夹）：

```
<video-stem>-知识库/
├── README.md                          入口
├── audio/full.wav                     16kHz 单声道 wav
├── captions/
│   ├── full.srt / .vtt / .txt / .csv / .lrc / .json   whisper.cpp 字幕
├── frames/                            关键画面 jpg（场景切换 + 间隔保底）
├── vision/frame_manifest.json        每张图的多模态描述
├── knowledge/
│   ├── 00-帧索引.md                   46 张图按时间排序
│   ├── 01-完整转录稿.md               912 段逐句转录
│   ├── 02-结构化笔记.md               N 个主题章节
│   ├── 03-思维导图.md                 Mermaid mindmap
│   ├── 04-概念速查.md                 词条名词表
│   ├── 99-整合·全知识库.md            ★ 整合版
│   └── anki_cards.json               Anki 卡片导出（自动生成）
└── scripts/                           处理用脚本（可重跑）
```

## Quick start

```bash
# 1. 装依赖（一次性）
brew install ffmpeg whisper-cpp

# 2. 下载 whisper 模型（一次性）
mkdir -p ~/.cache/whisper.cpp
# medium（默认，514MB，质量+速度平衡，推荐）
curl -L -o ~/.cache/whisper.cpp/ggml-medium-q5_0.bin \
  "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin"
# large（最高质量，1GB，按需）
# curl -L -o ~/.cache/whisper.cpp/ggml-large-v3-q5_0.bin \
#   "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"

# 3. 跑本地 pipeline（Steps 1-4：环境检查→抽音轨→转录→抽帧）
./scripts/pipeline.sh /path/to/video.mp4 --to-step 4 --skip-feishu --skip-anki
```

**推荐后续**：在 QoderWork 中让远程模型处理 Steps 5-7（视觉理解+结构化笔记+整合），质量远超本地小模型。

> 如需完全离线运行（fallback），额外安装 ollama + 模型：
> ```bash
> brew install --cask ollama
> ollama serve &
> ollama pull llava-phi3        # 视觉理解 fallback（~3GB）
> ollama pull qwen3:8b          # 文本改写 fallback（~5GB）
> ```

处理时间参考（41 分钟 1080p 视频，M1 Pro，medium 默认）：
- 抽音轨：~3 秒
- whisper.cpp 转录：~4.5 分钟（~9× 实时）
- 抽帧：~30 秒
- 视觉理解（80 张图）：~13 分钟
- 笔记整理：~10 分钟
- **总计：~28 分钟**

完整流程对比 67 分钟视频：
- large（最高质量）：~40 分钟
- medium（默认推荐）：~28 分钟 ⭐
- small（极速，质量降）：~15 分钟

## Pipeline 9 步

| Step | 工具 | 脚本 | 输入 | 输出 |
|---|---|---|---|---|
| 1. 环境检查 | bash | `env_check.sh` | — | 缺什么/提示装什么（含飞书+Anki检测） |
| 2. 抽音轨 | ffmpeg | `extract_audio.sh` | mp4 | wav 16kHz mono |
| 3. whisper.cpp 转录 | whisper-cli (Metal GPU, `-p 4 -t 8`) | `transcribe.sh` | wav | srt/vtt/txt/csv/lrc/json |
| 4. 抽帧 | ffmpeg | `extract_frames.sh` | mp4 | 80 jpg |
| 5. 视觉理解 | **外部模型**（QoderWork 远程） | `describe_frames.py` | jpg | frame_manifest.json |
| 6. 结构化笔记 | **外部模型**（QoderWork 远程） | `compose_notes.py` | json + manifest | 6 个 md |
| 7. 整合 | python | `compose_notes.py` + `index_frames.py` | 全部 | 99-整合·全知识库.md |
| 8. 飞书推送 | lark-cli | `push_to_feishu.sh` | knowledge/*.md | 飞书知识库节点 |
| 9. Anki 闪卡 | python + AnkiConnect | `create_anki_cards.py` | knowledge/*.md | Anki deck + 卡片 |

> Steps 1-4 为纯本地工具（ffmpeg/whisper.cpp），不依赖任何模型。
> Steps 5-7 推荐使用外部模型（QoderWork 远程模式），本地 ollama 仅作离线 fallback。

## QoderWork 模式（推荐）

在 QoderWork 中执行时，**Steps 1-4 走本地 pipeline**（音视频处理必须本地），**Steps 5-7 由 QoderWork 远程模型生成**，质量远优于本地小模型。

**推荐流程**：

1. 运行 `pipeline.sh --to-step 4 --skip-feishu --skip-anki` 完成本地处理（环境检查→抽音轨→转录→抽帧）
2. QoderWork 读取 `captions/full.json` + `frames/*.jpg`
3. 用 Task 子任务并行生成：视觉理解（逐帧描述）、结构化笔记、思维导图、概念速查、完整转录稿、帧索引
4. 再生成整合版 `99-整合·全知识库.md`
5. 可选：`pipeline.sh --from-step 8` 推送飞书 / 生成 Anki 卡片

**何时用本地 ollama**：仅在无网络或需要完全离线的场景。本地 llava-phi3 (3.8B) 有严重幻觉，qwen3:8b 的 JSON 输出不稳定。

**并行优化**：Step 2（抽音轨）和 Step 4（抽帧）可并行执行，节省约 30 秒。

## Usage

### 完整跑（推荐）

```bash
./scripts/pipeline.sh /path/to/video.mp4
```

输出在 `<video-dir>/<video-stem>-知识库/`。

### 自定义参数

```bash
./scripts/pipeline.sh /path/to/video.mp4 \
  --output /custom/output/dir \
  --model-size balanced \      # fast|balanced|quality（默认 balanced = medium-q5_0）
  --processors 4 \             # whisper 并行 processor（默认 4）
  --frames 100 \                # 总帧数
  --scene-threshold 0.25 \      # 场景切换阈值
  --skip-frames \               # 跳过抽帧和视觉理解
  --skip-notes \                # 跳过笔记整理
  --skip-feishu \               # 跳过飞书推送
  --feishu-space <SPACE_ID>     # 指定飞书知识库空间 ID（默认自动检测第一个）
  --skip-anki \                 # 跳过 Anki 闪卡生成
  --anki-deck <NAME>            # 指定 Anki deck 名称（默认：视频知识库::<video-stem>）
```

或显式指定模型名：

```bash
./scripts/pipeline.sh video.mp4 --whisper-model ggml-large-v3-q5_0  # 最高质量
./scripts/pipeline.sh video.mp4 --whisper-model ggml-small-q5_1     # 极速
```

### 单步执行

每个子脚本可独立运行：

```bash
# 仅转录音频（默认 medium-q5_0, -p 4 -t 8）
./scripts/transcribe.sh audio/full.wav captions/

# 指定模型和并行度
./scripts/transcribe.sh audio/full.wav captions/ ggml-large-v3-q5_0 4 8 zh

# 仅抽帧
./scripts/extract_frames.sh video.mp4 frames/

# 仅视觉理解
python3 scripts/describe_frames.py --frames-dir frames --output vision/

# 仅生成笔记
python3 scripts/compose_notes.py --captions captions/full.json --vision vision/frame_manifest.json --output knowledge/
```

## Critical implementation notes (避坑)

### 1. Python whisper 不要用！

CPU 上 Python whisper large-v3 跑 50 分钟无输出。**用 whisper.cpp + ggml-large-v3-q5_0 + Metal GPU**，4.7× 实时。

### 2. Python urllib 调 ollama 会 502

长 prompt 时 Python `urllib` 在 macOS sandbox 下会 502 Bad Gateway。**用 `subprocess + curl`**。

### 3. qwen3:8b 必须用 chat API + `think:false`

默认 qwen3:8b 会进入 thinking 模式，把 tokens 全吃完，`response` 字段空。

```bash
# 错（generate API，response 为空）：
POST /api/generate {"model":"qwen3:8b","prompt":"..."}

# 对（chat API + think:false）：
POST /api/chat    {"model":"qwen3:8b","messages":[...], "think":false}
```

### 4. whisper.cpp 输出在内存累积

大文件输出要等到结束才 flush。如果中断会全丢。**一次跑完别 Ctrl-C**。

### 5. 章节切分用 chunk+合成，不要整段灌

912 段一次性给 LLM 会让它输出自己的"思考过程"而非结构化 JSON。**先 chunk 提取局部主题点，再合成章节**。

### 6. 视觉模型小模型有幻觉

llava-phi3 (3.8B) 在某些空白帧会杜撰内容（如重复占位文字）。**手动 review** 重要内容。

### 7. qwen3:8b JSON 输出不稳定

qwen3:8b 经常返回 JSON 对象而非数组，或输出格式错误的 JSON。`compose_notes.py` 已内置 `_try_parse_json_array()` 健壮解析器（支持对象→数组转换、尾部逗号修复、代码块提取），并在完全失败时自动降级为时间等分策略（每 ~8 分钟一章）。**在 QoderWork 中建议跳过本地 LLM，直接用远程模型生成笔记。**

### 8. pipeline.sh 自动拷贝脚本到输出目录

Python 脚本（describe_frames.py / compose_notes.py / index_frames.py）用 `Path(__file__).parent.parent` 定位数据目录。pipeline.sh 在 Step 1 后自动拷贝脚本到 `OUT_DIR/scripts/`，确保 `ROOT` 指向知识库根目录而非 skill 安装目录。使用 `--from-step` 跳过 Step 1 时也会自动检查并拷贝。

### 9. 飞书推送使用 docs +update（非 docs +create）

`wiki +node-create` 创建知识库节点时会自动生成关联的 docx 文档（`obj_token`）。写入内容用 `docs +update --command overwrite --doc-format markdown`（通过 stdin 传入内容），而非 `docs +create`（后者需要额外的 `docx:document:create` scope）。

### 10. Anki 卡片去重用 canAddNotes 预检

AnkiConnect `addNotes` 遇到重复时整个 batch 返回 error（而非逐条跳过）。`create_anki_cards.py` 使用 `canAddNotes` 预检 → 过滤掉重复 → 再 `addNotes` 只添加新卡片。

## 性能调优

| 调整 | 提速 | 质量损失 |
|---|---|---|
| `-t 8` 线程全开 | 1.3-1.5x | 无 |
| `-p 2` 多 processor | 1.5-2x | 无（但 RAM 翻倍） |
| 模型从 large-v3-q5_0 换 medium-q5_0 | ~1.8x | 中文错字略增（仍可用）⭐ 默认 |
| 模型从 large-v3-q5_0 换 small-q5_1 | ~4x | 中文显著降（漏段、错字）|
| 模型从 large-v3-q5_0 换 base-q5_1 | ~8x | 中文几乎不可用 ❌ |

推荐配置（M1 Pro 16GB RAM，默认 medium-q5_0）：
```bash
whisper-cli -m ggml-medium-q5_0.bin -t 8 -p 4 -l zh ...
```

## 故障排查

| 问题 | 原因 | 解决 |
|---|---|---|
| whisper.cpp 一直 0 输出 | Python whisper 在 buffering | 用 whisper-cli 二进制 |
| `ollama run llava-phi3` 502 | urllib 在 sandbox 下挂 | 用 curl 调 `/api/generate` |
| qwen3:8b response 为空 | 默认 thinking 模式 | 用 `/api/chat` + `think:false` |
| 抽帧时间戳乱 | ffmpeg 输出名不携带 pts | 加 `-frame_pts true` + 解析 showinfo |
| 视觉描述幻觉 | llava-phi3 3.8B 太小 | 升 llava-llama3 或 qwen2-vl |
| 磁盘不足 | 模型 5GB+ | 至少 15GB 空闲 |
| CUDA 不可用 | macOS 无 NVIDIA GPU | 已用 Metal GPU 加速，正常 |
| 飞书推送报权限错误 | 缺少 wiki scope | `lark-cli auth login` 重新授权（确保 wiki:node:create 等 scope） |
| 飞书推送"未找到知识库空间" | 无可用空间 | `lark-cli wiki +space-create --name '知识库' --as user` |
| 飞书推送内容截断 | 单文件超 2000 行 | 正常行为，截断部分可在飞书中手动补充 |
| AnkiConnect 不可达 | Anki 未启动或插件未加载 | 启动 Anki + 安装 AnkiConnect (2055492159) + 重启 Anki |
| Anki 卡片上传失败 | deck 或 model 创建权限问题 | 确认 Anki 正常运行，手动 `--dry-run` 检查卡片内容 |
| Anki 重复卡片 | 重跑 Step 9 | 正常行为，canAddNotes 预检自动跳过已存在的卡片 |

## 关键参数对照

whisper.cpp 推荐参数（默认 medium-q5_0 + `-p 4 -t 8`）：
```bash
/opt/homebrew/bin/whisper-cli \
  -m ~/.cache/whisper.cpp/ggml-medium-q5_0.bin \
  -f audio.wav \
  -l zh \
  -pp -t 8 -p 4 \
  --prompt "本视频是关于..." \
  -osrt -ovtt -otxt -olrc -ocsv \
  -of captions/full
```

ffmpeg 抽帧推荐参数：
```bash
# 场景切换
ffmpeg -i input.mp4 -vf "select='gt(scene,0.25)',showinfo" \
       -vsync vfr -frame_pts true -q:v 3 frames/scene_%015d.000000.jpg

# 间隔保底
ffmpeg -i input.mp4 -vf "fps=1/90" -frame_pts true -q:v 3 frames/tick_%015d.000000.jpg
```

## Re-running

所有步骤都是**幂等的**：
- 抽帧：覆盖式，删 `frames/` 即可重抽
- 转录：覆盖式
- 视觉描述：跳过已 OK 的帧
- 笔记整理：覆盖式

可重跑任意子步骤而不破坏其他产物。

## 飞书知识库推送

Step 8 将 `knowledge/*.md` 自动推送到用户的飞书知识库。推送是**可选的**，不影响本地 pipeline。

### 前置条件

1. `lark-cli` 已安装（`npm install -g lark-cli`）
2. 用户已完成认证（`lark-cli auth login`）
3. 至少有一个可写的飞书知识库空间

`env_check.sh` 的第 9 节会自动检测以上条件，未满足时仅打印提示，不阻断 pipeline。

### 推送逻辑

1. 在飞书知识库空间根目录下创建**父节点**（标题 = 知识库目录名，如"Agent架构选型-知识库"）
2. 为 `knowledge/` 下每个 `.md` 文件创建**子节点**，并用 `docs +update --command overwrite --doc-format markdown` 写入内容
3. 已存在的节点自动跳过（幂等），可安全重跑

### 手动推送

```bash
# 对已有知识库手动推送
./scripts/push_to_feishu.sh /path/to/video-知识库/

# 指定知识库空间
./scripts/push_to_feishu.sh /path/to/video-知识库/ --space-id <SPACE_ID>
```

### 飞书推送限制

- 单个文件超过 2000 行时会自动截断推送（飞书 API 有内容长度限制）
- Mermaid 思维导图（`03-思维导图.md`）在飞书中无法直接渲染，以 Markdown 源码形式展示
- 帧图片（`frames/`）不推送，仅推送 `.md` 文件

## Anki 闪卡生成

Step 9 从 `knowledge/*.md` 自动提取知识点并生成 Anki 闪卡。闪卡生成是**可选的**，不影响其他 pipeline 步骤。

### 前置条件

1. Anki 26.x 已安装并运行
2. AnkiConnect 插件已安装（addon code: `2055492159`）
3. Anki 已重启以加载插件

`env_check.sh` 的第 10 节会自动检测以上条件，未满足时仅打印提示，不阻断 pipeline。

### 卡片来源

| 来源文件 | 提取方式 | 卡片数量 |
|----------|---------|---------|
| `04-概念速查.md` | Markdown 表格解析 | ~4 张（基础版） |
| `99-整合·全知识库.md` 概念速查表 | 表格解析 + 去重 | ~33 张（扩展版） |
| `99-整合·全知识库.md` Q&A 附录 | `###` 标题 + bullet points | ~6 张 |

### 卡片格式

自定义 Note Type `视频知识库`：4 字段（问题/回答/来源/分类），中文友好 CSS（PingFang SC）。

### 离线回退

AnkiConnect 不可达时自动导出 `knowledge/anki_cards.json`，可手动导入或稍后重跑 `--from-step 9`。

### 手动生成

```bash
# 对已有知识库手动生成闪卡
python3 scripts/create_anki_cards.py

# 指定 deck 名称
python3 scripts/create_anki_cards.py --deck "我的Deck"

# 只导出 JSON 不上传
python3 scripts/create_anki_cards.py --json-only

# 预览不上传
python3 scripts/create_anki_cards.py --dry-run
```

## End-to-End Workflow (含第二大脑)

本 skill 是流水线第一步；推荐再串联到 `second-brain-*` 系列形成完整知识管理闭环：

```
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  视频源文件       │──▶│  video-to-        │──▶│  笔记/字幕/帧    │
│  .mp4 / .mov    │    │  knowledge-base   │    │  knowledge/*.md  │
└──────────────────┘    └──────────────────┘    └────────┬─────────┘
                                                         │
                                                         ▼
                                              ┌──────────────────────┐
                                              │  second-brain-ingest  │
                                              │  (摄取到 wiki)        │
                                              └────────┬─────────────┘
                                                       │
                                                       ▼
                                              ┌──────────────────────┐
                                              │  vault/wiki/          │
                                              │  - entities/  实体    │
                                              │  - concepts/  概念    │
                                              │  - synthesis/ 综述    │
                                              │  - sources/   源      │
                                              └────────┬─────────────┘
                                                       │
                                                       ▼
                                              ┌──────────────────────┐
                                              │  second-brain-query   │
                                              │  (RAG 问答检索)       │
                                              └────────┬─────────────┘
                                                       │
                                                       ▼
                                              ┌──────────────────────┐
                                              │  second-brain-lint    │
                                              │  (健康检查)           │
                                              └──────────────────────┘
```

**实际触发顺序**（在 QoderWork 里）：

```
"用 video-to-knowledge-base 处理 /path/to/video.mp4"
"再把生成的 knowledge/ 目录用 second-brain-ingest 摄入到我的第二大脑"
"用 second-brain-query 问：Hermes 资金化机制的核心创新是什么？"
"跑 second-brain-lint 体检"
```

**vault 位置约定**（建议）：在知识库同级的 `vault/` 目录。

```
视频-知识库/
├── audio/         ← 第 1 层（原始处理产物）
├── captions/
├── frames/
├── knowledge/     ← 第 2 层（人读笔记）
└── vault/         ← 第 3 层（第二大脑 wiki）
    └── wiki/
```

## 相关 Skills

- **`lark-wiki`** — 飞书知识库管理（空间/节点/成员）
- **`lark-doc`** — 飞书文档创建和编辑
- **`second-brain-ingest`** — 把 `knowledge/*.md` 摄取到本地 wiki（强烈推荐）
- **`second-brain-query`** — RAG 问答检索
- **`second-brain-lint`** — wiki 健康检查
- **`source-management`** — MCP 来源管理（标注转录来源）
