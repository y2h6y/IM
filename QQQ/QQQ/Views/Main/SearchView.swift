import SwiftUI

// MARK: - SearchView

/// 聊天历史搜索视图（作为 sheet 弹出）
/// 支持全文搜索 + 定位到具体消息
struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = SearchViewModel()
    @Environment(\.dismiss) private var dismiss

    // 导航到 ChatView 时传递的目标
    @State private var navTarget: SearchNavTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                resultArea
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("搜索聊天记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { vm.clear(); dismiss() }
                }
            }
            // 从搜索结果导航到聊天页并高亮指定消息
            .navigationDestination(item: $navTarget) { target in
                if let user = appState.currentUser {
                    ChatView(
                        conversation:    target.conversation,
                        currentUser:     user,
                        highlightMsgId:  target.messageId
                    )
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索消息内容…", text: $vm.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await vm.performSearch() } }

            if !vm.query.isEmpty {
                Button { vm.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    // MARK: - Result Area

    @ViewBuilder
    private var resultArea: some View {
        if vm.isSearching {
            loadingView
        } else if vm.query.isEmpty {
            promptView
        } else if vm.results.isEmpty {
            emptyView
        } else {
            resultList
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
            Text("搜索中…").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var promptView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("输入关键词搜索历史消息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("支持中英文 · 搜索范围：所有会话")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.6))
            Text("未找到 \(vm.query) 相关消息")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var resultList: some View {
        List(vm.results) { result in
            SearchResultRow(result: result)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let conv = result.conversation else { return }
                    navTarget = SearchNavTarget(conversation: conv,
                                               messageId: result.message.id)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color(.systemBackground))
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .bottomTrailing) {
            Text("\(vm.results.count) 条结果")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
        }
    }
}

// MARK: - SearchResultRow

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            // 会话头像（对方用户头像）
            if let user = result.conversation?.otherUser {
                Circle()
                    .fill(user.avatarColor.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(user.initial)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
            } else {
                Circle()
                    .fill(Color.gray.gradient)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "questionmark").foregroundStyle(.white))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(result.conversationName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    Text(formatDate(result.message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // 消息发送方
                Text((result.message.isMine ? "我：" : "\(result.message.senderNickname)："))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                // FTS5 高亮片段（《》包裹匹配词）
                Text(attributedSnippet(result.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // 把 《关键词》 渲染成橙色高亮
    private func attributedSnippet(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        var searchStr = text

        // 找出所有 《...》 区间并标红
        while let start = searchStr.range(of: "《"),
              let end   = searchStr.range(of: "》", range: start.upperBound ..< searchStr.endIndex) {

            let innerRange = start.upperBound ..< end.lowerBound
            let inner      = String(searchStr[innerRange])

            // 在 AttributedString 里定位同一段
            let fullMarked = "《\(inner)》"
            if let attrRange = result.range(of: fullMarked) {
                // 替换为不带书名号的纯文字 + 橙色
                result.replaceSubrange(attrRange, with: {
                    var a = AttributedString(inner)
                    a.foregroundColor = .orange
                    a.font = .subheadline.bold()
                    return a
                }())
                // 重新构造 searchStr 以继续查找
                searchStr = String(result.characters)
            } else {
                break
            }
        }
        return result
    }

    private func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return "昨天"
        } else {
            let f = DateFormatter(); f.dateFormat = "MM/dd"; return f.string(from: date)
        }
    }
}

// MARK: - SearchNavTarget

struct SearchNavTarget: Hashable {
    let conversation: Conversation
    let messageId:    Int64
}
