import SwiftUI

@main
struct QQQApp: App {
    @StateObject private var appState  = AppState.shared
    @StateObject private var wsService = WebSocketService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(wsService)
        }
    }
}
