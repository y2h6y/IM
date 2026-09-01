import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        // ── 被踢出提示 ─────────────────────────────────────
        .alert("账号已在其他设备登录", isPresented: Binding(
            get: { appState.kickedOutReason != nil },
            set: { if !$0 { appState.kickedOutReason = nil } }
        )) {
            Button("确定", role: .cancel) {
                appState.kickedOutReason = nil
            }
        } message: {
            Text(appState.kickedOutReason ?? "")
        }
    }
}
