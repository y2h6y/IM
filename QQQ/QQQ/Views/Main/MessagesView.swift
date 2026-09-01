import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                if appState.conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("消息")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 搜索历史消息（全文检索）
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.loadConversations() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索会话")
            .refreshable { await appState.loadConversations() }
            .navigationDestination(for: Conversation.self) { conv in
                if let user = appState.currentUser {
                    ChatView(conversation: conv, currentUser: user)
                }
            }
            // 全文搜索历史消息 sheet
            .sheet(isPresented: $showSearch) {
                SearchView()
                    .environmentObject(appState)
            }
        }
    }

    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conv in
                NavigationLink(value: conv) {
                    ConversationRow(conversation: conv)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color(.systemBackground))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("暂无消息")
                .foregroundStyle(.secondary)
            Text("去联系人页面开始对话吧")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var filteredConversations: [Conversation] {
        guard !searchText.isEmpty else { return appState.conversations }
        return appState.conversations.filter {
            $0.otherUser.nickname.localizedCaseInsensitiveContains(searchText) ||
            $0.lastMessage.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(user: conversation.otherUser, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.otherUser.nickname)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(formatTime(conversation.lastMessageAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(conversation.lastMessage.isEmpty ? "开始聊天" : conversation.lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text("\(min(conversation.unreadCount, 99))")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"; return fmt.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "昨天"
        } else {
            let fmt = DateFormatter(); fmt.dateFormat = "MM/dd"; return fmt.string(from: date)
        }
    }
}
