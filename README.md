# EchoTrans

> macOS 原生应用：一键采集系统音频 → 实时语音转写 → 调用大模型翻译成所选语言，每次采集自动生成文字版记录。

## 功能特性

- 🔊 **系统音频采集**：基于 ScreenCaptureKit 捕获系统正在播放的音频（自动排除本 App 自身的声音）
- 📝 **双阶段转写**：
  - 采集过程中：默认使用 **Cloudflare Nova-3** WebSocket 输出低延迟实时字幕，也可选择本地 Whisper / SenseVoice
  - 停止采集后：默认使用 **本地 Whisper** 对完整音频重新转写生成高质量最终文字版
  - 实时转写模型与最终转写模型可在设置中分别选择
- 🌐 **实时翻译**：自动调用 OpenAI 兼容接口（OpenAI / new-api / one-api / 自建网关均可），翻译成用户选择的一种目标语言
- 📁 **会话落盘**：手动开始/停止，每次开始采集新建一个会话目录，自动保存 `audio.wav` + `transcript.txt`（文字版）和各语言翻译文件
- 🖥 **原生界面**：SwiftUI 编写，实时原文/译文双列对照，设置（⌘,）可配置引擎、模型、API、语言与输出目录

## 转写引擎

推荐组合是 **Cloudflare Nova-3 实时转写 + 本地 Whisper 最终转写**。Nova-3 通过 Cloudflare AI Gateway 接收 16kHz 单声道音频；Account ID、Gateway ID 和 API Token 由用户自行填写，并以明文保存在本机：

```text
~/Library/Application Support/EchoTrans/settings.json
```

请使用权限受限的 Cloudflare API Token。选择 Nova-3 时，采集到的音频会发送到 Cloudflare；最终 Whisper 转写仍完全在本机执行。

### 本地引擎

| 引擎 | 模型 | 体积 | 特点 |
| --- | --- | --- | --- |
| Whisper (whisper.cpp) | large-v3-turbo | ~1.6GB | 综合准确率最高，中英日混合会议最佳，Metal GPU 加速 |
| SenseVoice (sherpa-onnx) | small int8 | ~230MB | 中文、英文低延迟场景，速度极快（约 0.04x 实时率），自带标点；日语效果较差 |

模型可在 App 设置（⌘,）中一键下载（支持 HuggingFace 镜像），保存在 `~/Library/Application Support/EchoTrans/models`。

## 架构

```
SystemAudioCaptureEngine        ScreenCaptureKit（系统音频 → 16kHz 单声道 PCM）
        │
        ├────────────► CloudflareNovaTranscriber Nova-3 WebSocket（默认实时预览）
        ├────────────► LocalLiveTranscriber      Whisper / SenseVoice（可选实时预览）
        ├────────────► WavFileWriter             audio.wav 逐帧落盘
        ▼
AppModel                        会话状态机（idle / capturing / finalizing）
        │ 停止后
        ├────────────► LocalTranscriber          whisper.cpp / sherpa-onnx（C 桥接，重转写最终稿）
        │                                  │
        ▼                                  ▼
SessionStore                    TranslationService
（transcript.txt + audio.wav）   （OpenAI 兼容 /chat/completions → translations/*.md）
```

## 权限说明

首次运行时系统会请求以下权限：

| 权限 | 用途 |
| --- | --- |
| 屏幕录制 | ScreenCaptureKit 复用该权限来捕获系统音频（只采集声音，不录画面） |

需要在「系统设置 → 隐私与安全性」中授权。

本机反复重建时，必须保持同一个代码签名身份，否则 macOS 会把新构建当成新应用并再次要求屏幕录制授权。`make-app.sh` 默认使用固定的 `EchoTrans Dev` 开发签名；首次构建如果没有该身份，会自动运行 `scripts/setup-dev-signing.sh` 创建。不要在本机开发构建中使用 ad-hoc 签名（`-`）。

## 构建与运行

要求：macOS 13+、Xcode 15+ / CommandLineTools（cmake、git）

```bash
# 1. 拉取依赖（whisper.cpp 源码 + sherpa-onnx 预编译库）
./scripts/fetch-dependencies.sh

# 2. 构建可运行的 App
./scripts/make-app.sh
open build/EchoTrans.app

# 3. 生成轻量 DMG 安装包（不内置模型，用户首次运行后自行下载）
./scripts/make-dmg.sh
# 默认构建同样不内置模型：
./scripts/make-app.sh release                    # 轻量包（模型外置，约几十 MB）
# 仅内部测试/离线分发时才显式内置模型：
./scripts/make-app.sh release --with-models

# 可选：引擎冒烟测试（不启动 GUI，验证 Whisper / SenseVoice 桥接）
./scripts/test-engines.sh
```

### 模型下载说明

- **引擎**：whisper.cpp 与 sherpa-onnx 均直接编进/打入 App 二进制，无需额外安装
- **模型**：不打包进安装包，首次运行后在设置（⌘,）中下载 Whisper 或 SenseVoice；
  模型保存在用户目录 `~/Library/Application Support/EchoTrans/models`
- `./scripts/fetch-dependencies.sh --models` 仅供开发者预下载模型，发布构建不会自动打包

> 注：部分版本的 CommandLineTools 存在 SwiftPM ManifestAPI 损坏的已知问题，
> `swift build` 会报 "Undefined symbols ... Package.__allocating_init"；
> 本项目构建脚本不依赖 SwiftPM，始终可用。装完整版 Xcode 后也可用 Xcode 打开 Package.swift 开发。

首次使用：按 `⌘,` 打开设置：

1. **实时转写**：默认 Cloudflare Nova-3；填写 Account ID、AI Gateway ID 和 API Token
2. **最终转写**：默认本地 Whisper；实时和最终引擎也可分别改选本地 Whisper / SenseVoice
3. **下载所选本地引擎的模型**（Whisper 约 1.6GB，SenseVoice 约 230MB）
4. **识别语言**（默认 zh-CN）
5. **翻译 API**：Base URL / API Key / 模型（任意 OpenAI 兼容服务；不配置则只转写不翻译）
6. **输出目录**（默认 `~/Documents/EchoTrans`）

## 输出示例

```
~/Documents/EchoTrans/
└── 2025-06-01 14-30-00/          # 每次开始采集 → 一个新会话目录
    ├── audio.wav                 # 原始采集音频（16kHz，供本地引擎重新转写）
    ├── transcript.txt            # 最终转写文字版（所选引擎生成）
    └── translations/
        ├── English.md
        └── 日本語.md
```

## 项目结构

```
Sources/EchoTrans/
├── EchoTransApp.swift            # App 入口
├── ContentView.swift             # 主界面
├── SettingsView.swift            # 设置界面（引擎 / 模型下载 / API）
├── AppModel.swift                # 会话状态机
├── Audio/SystemAudioCaptureEngine.swift   # ScreenCaptureKit 系统音频采集
├── Transcription/CloudflareNovaTranscriber.swift # Nova-3 WebSocket 实时引擎
├── Transcription/LocalTranscriptionEngine.swift  # Whisper / SenseVoice 本地引擎
├── Transcription/ModelManager.swift       # 模型下载与解压
├── Translation/TranslationService.swift   # OpenAI 兼容翻译
├── Storage/SessionStore.swift             # 会话目录与文件落盘
├── Storage/WavFile.swift                  # WAV 增量写入 / 读取
├── Settings/AppSettings.swift             # 设置持久化
Bridge/
├── EchoTransBridge.h/.c          # whisper.cpp + sherpa-onnx C 桥接
scripts/
├── fetch-dependencies.sh         # 拉取 whisper.cpp 源码 + sherpa-onnx 库
├── make-app.sh                   # 编译打包 App
└── test-engines.sh               # 引擎 CLI 冒烟测试
```

## 路线图

- [x] 本地引擎实时分块转写（Whisper / SenseVoice，模型常驻内存）
- [x] Cloudflare Nova-3 WebSocket 实时转写
- [ ] VAD 语音活动检测（减少 SenseVoice 分块切词）
- [ ] 麦克风输入模式
- [ ] 历史会话列表与回看 / 重新转写
- [ ] 导出 SRT 字幕
- [ ] 多翻译引擎（DeepL / Google / 本地模型）
- [ ] 菜单栏常驻 / 全局快捷键
- [ ] Speaker diarization（说话人分离）

## License

GPL-3.0
