import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var settings: AppSettings

    init(model: AppModel) {
        self.model = model
        self._settings = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    controlsCard
                    transcriptCard
                    if !model.translationResults.isEmpty {
                        translationsCard
                    }
                }
                .padding(16)
            }
            Divider()
            footerBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 顶部状态栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("EchoTrans")
                    .font(.headline)
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            phaseBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var phaseBadge: some View {
        switch model.phase {
        case .idle:
            Label("空闲", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .capturing:
            Label("采集中", systemImage: "record.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case .finalizing:
            Label("生成中", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 控制区

    private var controlsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("识别语言：", selection: $settings.recognitionLocale) {
                    ForEach(AppSettings.availableRecognitionLocales, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
                .frame(width: 280, alignment: .leading)
                .disabled(model.phase != .idle)
                .onChange(of: settings.recognitionLocale) { _, _ in settings.save() }

                VStack(alignment: .leading, spacing: 6) {
                    Text("翻译目标语言：")
                        .font(.callout)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 100), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(AppSettings.availableTargetLanguages, id: \.self) { language in
                            languageChip(language)
                        }
                    }
                    .disabled(model.phase != .idle)
                }

                HStack(spacing: 12) {
                    Button {
                        if model.phase == .capturing {
                            model.stop()
                        } else if model.phase == .idle {
                            model.start()
                        }
                    } label: {
                        Label(
                            model.phase == .capturing ? "停止采集" : "开始采集",
                            systemImage: model.phase == .capturing ? "stop.circle.fill" : "record.circle"
                        )
                        .frame(minWidth: 150)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(model.phase == .capturing ? .red : .green)
                    .disabled(model.phase == .finalizing)

                    Spacer()

                    Text("每次开始采集会新建一个会话目录，停止后自动保存文字版并翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Label("控制", systemImage: "slider.horizontal.3")
        }
    }

    private func languageChip(_ language: String) -> some View {
        let isSelected = settings.targetLanguages.contains(language)
        return Button {
            if isSelected {
                settings.targetLanguages.removeAll { $0 == language }
            } else {
                settings.targetLanguages.append(language)
            }
            settings.save()
        } label: {
            Text(language)
                .font(.callout)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 实时转写（原文/译文双列）

    private var transcriptCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                liveColumn(
                    title: "原文（实时识别）",
                    text: liveTranscript,
                    placeholder: "（开始采集后，这里会实时显示识别出的文字…）"
                )
                Divider()
                liveColumn(
                    title: "译文（\(liveTranslationLanguage)）",
                    text: model.liveTranslation,
                    placeholder: liveTranslationPlaceholder
                )
            }
            .padding(6)
        } label: {
            HStack {
                Label("实时对照", systemImage: "character.bubble")
                Spacer()
                Text("停止采集后：本地引擎重转写 + 全部目标语言落盘")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var liveTranslationLanguage: String {
        settings.targetLanguages.first ?? "未选择"
    }

    private var liveTranslationPlaceholder: String {
        if !settings.needsTranslationAPI {
            return "（在设置中配置 API Key 后，这里会实时显示第一个目标语言的译文…）"
        }
        return "（识别出的完整句子会实时翻译到这里…）"
    }

    private func liveColumn(title: String, text: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? placeholder : text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .onChange(of: text) { _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 230, alignment: .topLeading)
    }

    private var liveTranscript: String {
        var parts: [String] = []
        if !model.finalizedText.isEmpty { parts.append(model.finalizedText) }
        if !model.partialText.isEmpty { parts.append(model.partialText + " ▍") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 翻译结果

    @ViewBuilder private var translationsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.translationResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.language)
                                .font(.callout)
                                .bold()
                            Spacer()
                            if let url = result.fileURL {
                                Button("打开文件") {
                                    NSWorkspace.shared.open(url)
                                }
                                .controlSize(.small)
                            }
                        }
                        if let error = result.error {
                            Text("翻译失败：\(error)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(result.text)
                                .font(.callout)
                                .lineLimit(8)
                                .foregroundStyle(.primary)
                        }
                        Divider()
                    }
                }
            }
            .padding(6)
        } label: {
            Label("翻译结果", systemImage: "globe")
        }
    }

    // MARK: - 底部栏

    private var footerBar: some View {
        HStack {
            if model.phase == .capturing {
                levelMeter
                Text("已采集 \(captureTimeText)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if model.audioLevel < 0.02 {
                    Text("⚠️ 电平过低：确认有 App 在播放声音")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if let url = model.lastSessionDirectory {
                Button("打开会话目录") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("输出目录：\(settings.outputDirectoryPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("⌘, 打开设置")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var captureTimeText: String {
        let seconds = Int(model.capturedSeconds)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 简易电平表：5 段方块，实时反映系统音量 RMS
    private var levelMeter: some View {
        let bars = 5
        let active = Int((model.audioLevel * Double(bars)).rounded(.up))
        return HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < active ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(6 + i * 2))
            }
        }
    }
}
