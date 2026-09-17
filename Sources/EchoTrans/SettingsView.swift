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
            // ── 转写流程 ──────────────────────────────────────────────
            Section {
                LabeledContent("实时转写") {
                    Picker("", selection: $settings.realtimeTranscriptionEngine) {
                        ForEach(RealtimeTranscriptionEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.realtimeTranscriptionEngine) { _, _ in settings.save() }
                }
                LabeledContent("最终转写") {
                    Picker("", selection: $settings.finalTranscriptionEngine) {
                        ForEach(FinalTranscriptionEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: settings.finalTranscriptionEngine) { _, _ in settings.save() }
                }

                if (settings.realtimeTranscriptionEngine == .senseVoice
                    || settings.finalTranscriptionEngine == .senseVoice),
                   Locale(identifier: settings.recognitionLocale).language.languageCode?.identifier == "ja" {
                    Label("当前为日语：SenseVoice 可能出现中文音近字，准确率优先建议手动选择 Whisper。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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
                .help("选择具体语言可提高准确率；自动检测时由本地模型自行判断")
            } header: {
                sectionHeader("转写流程", systemImage: "waveform")
            } footer: {
                Text("推荐：Nova-3 负责低延迟实时字幕，本地 Whisper 在停止后重新转写生成高质量终稿。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── Cloudflare Nova-3 ────────────────────────────────────
            if settings.realtimeTranscriptionEngine == .cloudflareNova3 {
                Section {
                    LabeledContent("Account ID") {
                        TextField("Cloudflare Account ID", text: $settings.cloudflareAccountID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Gateway ID") {
                        TextField("AI Gateway 名称", text: $settings.cloudflareGatewayID)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API Token") {
                        SecureField("Cloudflare API Token", text: $settings.cloudflareAPIToken)
                            .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    sectionHeader("Cloudflare Nova-3", systemImage: "cloud")
                } footer: {
                    Text("凭证仅保存在本机 EchoTrans/settings.json。请使用权限受限的 Cloudflare Token；音频将发送到 Cloudflare Workers AI 实时转写。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
                    subtitle: "中文、英文低延迟场景 · 速度极快 · 日语准确率较差",
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
                Text("模型保存在 ~/Library/Application Support/EchoTrans/models；安装包不内置模型，请首次使用前下载所需引擎")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // ── 翻译 API ─────────────────────────────────────────────
            Section {
                LabeledContent("Base URL") {
                    TextField("", text: $settings.apiBaseURL, prompt: Text("https://api.openai.com/v1"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API Key") {
                    SecureField("", text: $settings.apiKey, prompt: Text("sk-..."))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型") {
                    TextField("", text: $settings.apiModel, prompt: Text("gpt-4o-mini"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                sectionHeader("翻译大模型（OpenAI 兼容）", systemImage: "globe")
            } footer: {
                Text("兼容 OpenAI / new-api / one-api 等任何 /chat/completions 服务。实时与最终译文使用同一个目标语言。")
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
