import SwiftUI

struct ContactsView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if appState.contacts.isEmpty {
                    ProgressView("加载中…")
                } else {
                    contactList
                }
            }
            .navigationTitle("联系人")
            .searchable(text: $searchText, prompt: "搜索联系人")
            .refreshable { await appState.loadContacts() }
            // ✅ value-based 导航
            .navigationDestination(for: User.self) { user in
                if let me = appState.currentUser {
                    StartChatView(targetUser: user, currentUser: me)
                }
            }
        }
    }

    private var contactList: some View {
        List {
            ForEach(filteredContacts) { user in
                NavigationLink(value: user) {
                    ContactRow(user: user)
                }
                .listRowBackground(Color(.systemBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filteredContacts: [User] {
        guard !searchText.isEmpty else { return appState.contacts }
        return appState.contacts.filter {
            $0.nickname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - ContactRow

struct ContactRow: View {
    let user: User
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(user: user, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.nickname).font(.system(size: 16, weight: .semibold))
                Text("@\(user.username)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - StartChatView

struct StartChatView: View {
    let targetUser: User
    let currentUser: User
    @EnvironmentObject var appState: AppState
    @State private var conversation: Conversation?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let conv = conversation {
                ChatView(conversation: conv, currentUser: currentUser)
            } else if let err = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle).foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .navigationTitle(targetUser.nickname)
            } else {
                ProgressView("准备中…").navigationTitle(targetUser.nickname)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            let conv = try await APIService.shared.getOrCreateConversation(withUserId: targetUser.id)
            conversation = conv
            appState.upsertConversation(conv)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
