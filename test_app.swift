import SwiftUI

class AppState: ObservableObject {
    static let shared = AppState()
    @Published var count = 0
}

@main
struct TestApp: App {
    @StateObject var appState = AppState.shared
    @Environment(\.openWindow) var openWindow
    var body: some Scene {
        MenuBarExtra("Test", systemImage: "star") {
            Text("Menu")
        }
        .onChange(of: appState.count) { _ in
            openWindow(id: "test")
        }
    }
}
