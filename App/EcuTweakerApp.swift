import SwiftUI

@main
struct EcuTweakerApp: App {
    @StateObject var model = AppModel()
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.connection)
                .environmentObject(model.log)
                .onOpenURL { url in
                    Task { await model.importDatabase(from: url) }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.connection.reconnectIfNeeded() }
        }
    }
}

enum Route: Hashable {
    case function(String)
    case screen(href: String, name: String)
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            MainView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .function(let f):
                        EcuListView(function: f)
                    case .screen(let href, let name):
                        ScreenView(href: href, title: name)
                    }
                }
        }
    }
}
