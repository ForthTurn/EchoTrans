import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var models: ModelManager

    init(model: AppModel) {
        self.model = model
        self._settings = ObservedObject(wrappedValue: model.settings)
        self._models = ObservedObject(wrappedValue: model.modelManager)
    }

    var body: some View {
        Form {
            Section("转写引擎") {
                Picker("最终文字版引擎", selection: engineBinding) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Text("""
                采集过程中始终用苹果系统识别做实时预览；\
                选择 Whisper / SenseVoice 时，停止采集后会对 audio.wav 重新转写生成更高质量的最终文字版（完全本地、不联网）。\
                会议记录建议二选一，SenseVoice 对中文最快，Whisper 综合最稳。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

                Picker("识别语言", selection: $settings.recognitionLocale) {
                    ForEach(AppSettings.availableRecognitionLocales, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
            }

            Section("本地模型") {
                modelRow(
                    title: "Whisper large-v3-turbo",
                    subtitle: "约 1.6GB · 综合准确率最高，中英日混合场景最佳",
                    statusText: models.whisperStatusText(),
                    progress: models.whisperProgress(),
                    error: models.whisperError,
                    installed: models.whisperInstalled,
                    busy: models.whisperState.isBusy,
                    download: { models.downloadWhisperModel() }
                )
                modelRow(
                    title: "SenseVoice Small (int8)",
                    subtitle: "约 230MB · 中日韩英，速度极快，自带标点",
                    statusText: models.senseVoiceStatusText(),
                    progress: models.senseVoiceProgress(),
                    error: models.senseVoiceError,
                    installed: models.senseVoiceInstalled,
                    busy: models.senseVoiceState.isBusy,
                    download: { models.downloadSenseVoiceModel() }
                )
                Toggle("使用 HuggingFace 镜像（国内网络）", isOn: $settings.useHFMirror)
                Text("模型保存在 ~/Library/Application Support/EchoTrans/models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("翻译大模型（OpenAI 兼容接口）") {
                TextField("API Base URL（如 https://api.openai.com/v1）", text: $settings.apiBaseURL)
                SecureField("API Key", text: $settings.apiKey)
                TextField("模型（如 gpt-4o-mini）", text: $settings.apiModel)
                Text("兼容 OpenAI / new-api / one-api 等任何实现了 /chat/completions 的服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("输出") {
                TextField("会话输出目录", text: $settings.outputDirectoryPath)
                Text("每次采集会在该目录下新建「日期时间」子目录，保存 audio.wav、transcript.txt 与各语言翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("设置在关闭本窗口时自动保存到 ~/Library/Application Support/EchoTrans/settings.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(width: 560, height: 640)
        .onDisappear { settings.save() }
    }

    private var engineBinding: Binding<TranscriptionEngine> {
        Binding(
            get: { settings.transcriptionEngine },
            set: { settings.transcriptionEngine = $0; settings.save() }
        )
    }

    @ViewBuilder
    private func modelRow(
        title: String,
        subtitle: String,
        statusText: String,
        progress: Double?,
        error: String?,
        installed: Bool,
        busy: Bool,
        download: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed {
                    Text("已安装 ✓").font(.callout).foregroundStyle(.green)
                } else if busy {
                    ProgressView(value: progress ?? 0)
                        .frame(width: 90)
                } else {
                    Button("下载") { download() }.controlSize(.small)
                }
            }
            if let progress, busy {
                Text("下载中 \(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
