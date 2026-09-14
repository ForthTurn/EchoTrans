# EchoTrans

> macOS 原生应用：一键采集系统音频 → 实时语音转写 → 调用大模型翻译成多种语言，每次采集自动生成文字版记录。

## 功能特性

- 🔊 **系统音频采集**：基于 ScreenCaptureKit 捕获系统正在播放的音频（自动排除本 App 自身的声音）
- 📝 **双阶段转写**：
  - 采集过程中：苹果系统识别**实时预览**（低延迟）
  - 停止采集后：可选 **Whisper / SenseVoice 本地引擎**对音频重新转写生成高质量最终文字版（完全离线，会议记录推荐）
- 🌐 **多语言翻译**：自动调用 OpenAI 兼容接口（OpenAI / new-api / one-api / 自建网关均可），翻译成任意多种目标语言
- 📁 **会话落盘**：手动开始/停止，每次开始采集新建一个会话目录，自动保存 `audio.wav` + `transcript.txt`（文字版）和各语言翻译文件
- 🖥 **原生界面**：SwiftUI 编写，设置（⌘,）可配置引擎、模型、API、语言与输出目录

## 本地转写引擎

| 引擎 | 模型 | 体积 | 特点 |
| --- | --- | --- | --- |
| Whisper (whisper.cpp) | large-v3-turbo | ~1.6GB | 综合准确率最高，中英日混合会议最佳，Metal GPU 加速 |
| SenseVoice (sherpa-onnx) | small int8 | ~230MB | 中日韩英，速度极快（约 0.04x 实时率），自带标点 |
| 苹果系统识别 | 系统内置 | 无 | 免下载，实时流式，准确率中等 |

模型可在 App 设置（⌘,）中一键下载（支持 HuggingFace 镜像），保存在 `~/Library/Application Support/EchoTrans/models`。

## 架构

```
SystemAudioCaptureEngine        ScreenCaptureKit（系统音频 → 16kHz 单声道 PCM）
        │
        ├────────────► TranscriptionService      Apple Speech（实时预览）
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
| 语音识别 | 实时预览转写（Apple Speech） |

需要在「系统设置 → 隐私与安全性」中授权。

## 构建与运行

要求：macOS 13+、Xcode 15+ / CommandLineTools（cmake、git）

```bash
# 1. 拉取依赖（whisper.cpp 源码 + sherpa-onnx 预编译库）
./scripts/fetch-dependencies.sh

# 2. 构建可运行的 App
./scripts/make-app.sh
open build/EchoTrans.app

# 3. 生成 DMG 安装包（模型打包进 App，拷给谁都能直接用）
./scripts/make-dmg.sh
# 或控制是否内置模型：
./scripts/make-app.sh release --no-models        # 轻量包（引擎内置、模型外置，~34MB）
./scripts/make-app.sh release --download-models  # 模型缺失时自动先下载

# 可选：引擎冒烟测试（不启动 GUI，验证 Whisper / SenseVoice 桥接）
./scripts/test-engines.sh
```

### 内置模型说明

- **引擎**：whisper.cpp 与 sherpa-onnx 均直接编进/打入 App 二进制，无需额外安装
- **模型**：默认打包到 `EchoTrans.app/Contents/Resources/models/`，App 运行时优先使用内置模型；
  用户目录 `~/Library/Application Support/EchoTrans/models` 下的模型仍可在设置里追加（内置优先）
- 生成安装包前请先确保模型已下载：`./scripts/fetch-dependencies.sh --models`

> 注：部分版本的 CommandLineTools 存在 SwiftPM ManifestAPI 损坏的已知问题，
> `swift build` 会报 "Undefined symbols ... Package.__allocating_init"；
> 本项目构建脚本不依赖 SwiftPM，始终可用。装完整版 Xcode 后也可用 Xcode 打开 Package.swift 开发。

首次使用：按 `⌘,` 打开设置：

1. **转写引擎**：默认 Whisper；会议记录推荐 Whisper（最稳）或 SenseVoice（中文最快）
2. **下载对应模型**（内置包无需此步；设置里有进度条）
3. **识别语言**（默认 zh-CN）
4. **API Base URL / API Key / 模型**（任意 OpenAI 兼容服务；不配置则只转写不翻译）
5. **输出目录**（默认 `~/Documents/EchoTrans`）

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
├── Speech/TranscriptionService.swift      # Apple Speech 实时预览
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

- [ ] 句级实时 final 结果与本地引擎实时分块转写（当前本地引擎在停止后一次性转写）
- [ ] VAD 语音活动检测（减少 SenseVoice 分块切词）
- [ ] 麦克风输入模式
- [ ] 历史会话列表与回看 / 重新转写
- [ ] 导出 SRT 字幕
- [ ] 多翻译引擎（DeepL / Google / 本地模型）
- [ ] 菜单栏常驻 / 全局快捷键
- [ ] Speaker diarization（说话人分离）

## License

MIT
