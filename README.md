# EchoTrans

> macOS 原生应用：一键采集系统音频 → 实时语音转写 → 调用大模型翻译成多种语言，每次采集自动生成文字版记录。

## 功能特性

- 🔊 **系统音频采集**：基于 ScreenCaptureKit 捕获系统正在播放的音频（自动排除本 App 自身的声音）
- 📝 **实时转写**：基于 Apple Speech 框架流式识别，支持中文、英文、日文、韩文等多种识别语言
- 🌐 **多语言翻译**：会话结束后自动调用 OpenAI 兼容接口（OpenAI / new-api / one-api / 自建网关均可），翻译成任意多种目标语言
- 📁 **会话落盘**：手动开始/停止，每次开始采集新建一个会话目录，自动保存 `transcript.txt`（文字版）和各语言翻译文件
- 🖥 **原生界面**：SwiftUI 编写，设置（⌘,）可配置 API、识别语言、目标语言与输出目录

## 架构

```
SystemAudioCaptureEngine        ScreenCaptureKit（系统音频 → AVAudioPCMBuffer）
        │
        ▼
TranscriptionService            Apple Speech（音频帧 → 实时文本）
        │
        ▼
AppModel                        会话状态机（idle / capturing / finalizing）
        │                                  │
        │ 开始时                            │ 停止后
        ▼                                  ▼
SessionStore                    TranslationService
（会话目录 / transcript.txt）    （OpenAI 兼容 /chat/completions → translations/*.md）
```

## 权限说明

首次运行时系统会请求以下权限：

| 权限 | 用途 |
| --- | --- |
| 屏幕录制 | ScreenCaptureKit 复用该权限来捕获系统音频（只采集声音，不录画面） |
| 语音识别 | 把采集到的音频实时转写成文字 |

需要在「系统设置 → 隐私与安全性」中授权。

## 构建与运行

要求：macOS 13+、Swift 5.9+（Xcode 15+ 或 CommandLineTools）

```bash
# 方式一（推荐）：脚本打包成独立 App（swiftc 直编，不依赖 SwiftPM）
./scripts/make-app.sh
open build/EchoTrans.app

# 方式二：标准 SwiftPM（需要完整版 Xcode）
# 注：部分版本的 CommandLineTools 存在 SwiftPM ManifestAPI 损坏的已知问题，
#     会报 "Undefined symbols ... Package.__allocating_init" 错误，
#     此时请使用方式一，或安装完整版 Xcode 后再 swift run。
swift run
```

> 首次运行请使用打包后的 App，权限弹窗（屏幕录制 / 语音识别）才能正常触发。

首次使用：按 `⌘,` 打开设置，配置：

1. **识别语言**（默认 zh-CN）
2. **API Base URL / API Key / 模型**（任意 OpenAI 兼容服务；不配置则只转写不翻译）
3. **输出目录**（默认 `~/Documents/EchoTrans`）

## 输出示例

```
~/Documents/EchoTrans/
└── 2025-06-01 14-30-00/          # 每次开始采集 → 一个新会话目录
    ├── transcript.txt            # 原始转写文字版
    └── translations/
        ├── English.md
        └── 日本語.md
```

## 项目结构

```
Sources/EchoTrans/
├── EchoTransApp.swift            # App 入口
├── ContentView.swift             # 主界面
├── SettingsView.swift            # 设置界面
├── AppModel.swift                # 会话状态机
├── Audio/SystemAudioCaptureEngine.swift   # ScreenCaptureKit 系统音频采集
├── Speech/TranscriptionService.swift      # Speech 框架实时转写
├── Translation/TranslationService.swift   # OpenAI 兼容翻译
├── Storage/SessionStore.swift             # 会话目录与文件落盘
└── Settings/AppSettings.swift             # 设置持久化
```

## 路线图

- [ ] 句级实时 final 结果（当前为整段识别，结束时一次性落定）
- [ ] 麦克风输入模式
- [ ] 历史会话列表与回看
- [ ] 导出 SRT 字幕
- [ ] 多翻译引擎（DeepL / Google / 本地模型）
- [ ] 菜单栏常驻 / 全局快捷键
- [ ] Speaker diarization（说话人分离）

## License

MIT
