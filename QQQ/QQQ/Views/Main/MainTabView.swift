import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            MessagesView()
                .tabItem {
                    Label("消息", systemImage: "bubble.left.and.bubble.right.fill")
                }

            ContactsView()
                .tabItem {
                    Label("联系人", systemImage: "person.2.fill")
                }

            DiscoveryView()
                .tabItem {
                    Label("公台", systemImage: "safari.fill")
                }

            ProfileView()
                .tabItem {
                    Label("我", systemImage: "person.crop.circle.fill")
                }
        }
        .task {
            await appState.loadInitialData()
        }
    }
}
