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
            // ── 转写引擎 ──────────────────────────────────────────────
            Section {
                Picker("引擎", selection: engineBinding) {
                    ForEach(TranscriptionEngine.allCases) { engine in
                        Text(engine.shortName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settings.transcriptionEngine.featureDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                LabeledContent("识别语言") {
                    Picker("", selection: $settings.recognitionLocale) {
                        ForEach(AppSettings.availableRecognitionLocales, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .trailing)
                    .onChange(of: settings.recognitionLocale) { _, _ in settings.save() }
                }
                .help("苹果实时预览需与音频语言一致（不支持自动检测）；本地引擎在“自动检测”时由模型自行判断")
            } header: {
                sectionHeader("转写引擎", systemImage: "waveform")
            }

            // ── 本地模型 ──────────────────────────────────────────────
            Section {
                modelCard(
                    title: "Whisper large-v3-turbo",
                    size: "1.6GB",
                    subtitle: "综合准确率最高 · 中英日混合会议最佳 · Metal GPU 加速",
                    statusText: models.whisperStatusText(),
                    progress: models.whisperProgress(),
                    error: models.whisperError,
                    installed: models.whisperInstalled,
                    bundled: models.whisperBundled,
                    busy: models.whisperState.isBusy,
                    download: { models.downloadWhisperModel() }
                )
                modelCard(
                    title: "SenseVoice Small (int8)",
                    size: "230MB",
                    subtitle: "中日韩英 · 速度极快 · 自带标点",
                    statusText: models.senseVoiceStatusText(),
                    progress: models.senseVoiceProgress(),
                    error: models.senseVoiceError,
                    installed: models.senseVoiceInstalled,
                    bundled: models.senseVoiceBundled,
                    busy: models.senseVoiceState.isBusy,
                    download: { models.downloadSenseVoiceModel() }
                )
                Toggle("模型下载走 HuggingFace 镜像", isOn: $settings.useHFMirror)
                    .help("国内网络建议开启；仅影响下载源，不影响识别")
            } header: {
                sectionHeader("本地模型", systemImage: "internaldrive")
            } footer: {
                Text("模型保存在 ~/Library/Application Support/EchoTrans/models；安装包内置模型时无需下载")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── 翻译 API ─────────────────────────────────────────────
            Section {
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/v1", text: $settings.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key") {
                    SecureField("sk-...", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型") {
                    TextField("gpt-4o-mini", text: $settings.apiModel)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                sectionHeader("翻译大模型（OpenAI 兼容）", systemImage: "globe")
            } footer: {
                Text("兼容 OpenAI / new-api / one-api 等任何 /chat/completions 服务。实时译文列使用第一个目标语言。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── 输出 ─────────────────────────────────────────────────
            Section {
                LabeledContent("会话输出目录") {
                    TextField("~/Documents/EchoTrans", text: $settings.outputDirectoryPath)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                sectionHeader("输出", systemImage: "folder")
            } footer: {
                Text("每次采集新建「日期时间」子目录：audio.wav + transcript.txt + translations/*.md")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 640, height: 720)
        .onDisappear { settings.save() }
    }

    // MARK: - 辅助视图

    private var engineBinding: Binding<TranscriptionEngine> {
        Binding(
            get: { settings.transcriptionEngine },
            set: { settings.transcriptionEngine = $0; settings.save() }
        )
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func modelCard(
        title: String,
        size: String,
        subtitle: String,
        statusText: String,
        progress: Double?,
        error: String?,
        installed: Bool,
        bundled: Bool,
        busy: Bool,
        download: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(installed ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(size)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    if bundled {
                        Text("App 内置")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let progress, busy {
                    ProgressView(value: progress)
                        .frame(height: 6)
                    Text("下载中 \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if !busy && !installed {
                    Button("下载") { download() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .padding(.vertical, 2)
    }
}
