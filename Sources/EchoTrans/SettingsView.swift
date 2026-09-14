import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("语音识别") {
                Picker("识别语言", selection: $settings.recognitionLocale) {
                    ForEach(AppSettings.availableRecognitionLocales, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
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
                Text("每次采集会在该目录下新建「日期时间」子目录，保存 transcript.txt 与各语言翻译。")
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
        .frame(width: 540)
        .onDisappear { settings.save() }
    }
}
