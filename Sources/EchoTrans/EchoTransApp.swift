import SwiftUI

@main
struct EchoTransApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("EchoTrans") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(settings: model.settings)
        }
    }
}
