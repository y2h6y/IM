import SwiftUI
import PhotosUI

struct ChatView: View {
    let conversation: Conversation
    let currentUser: User
    /// 从搜索结果进入时指定要滚动并高亮的消息 ID
    var highlightMsgId: Int64? = nil

    @StateObject private var vm: ChatViewModel
    @State private var selectedPhoto: PhotosPickerItem?
    @FocusState private var inputFocused: Bool
    @State private var flashedMsgId: Int64?   // 当前高亮闪烁的消息 ID

    init(conversation: Conversation, currentUser: User, highlightMsgId: Int64? = nil) {
        self.conversation   = conversation
        self.currentUser    = currentUser
        self.highlightMsgId = highlightMsgId
        _vm = StateObject(wrappedValue: ChatViewModel(
            conversation: conversation,
            currentUser: currentUser
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── E2EE 状态栏（key 未就绪时显示）──────────────
            if !vm.peerE2EReady {
                E2EStatusBanner(vm: vm)
            }

            // ── 消息列表 ─────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(message: msg,
                                          isHighlighted: flashedMsgId == msg.id)
                                .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    // 正常聊天模式：新消息到来自动滚底
                    if highlightMsgId == nil, let last = vm.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if highlightMsgId == nil, let last = vm.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // 搜索定位：消息加载后滚动到目标并高亮
                .task {
                    await vm.loadMessages()
                    if let targetId = highlightMsgId, !vm.messages.isEmpty {
                        try? await Task.sleep(for: .milliseconds(200))
                        scrollAndFlash(proxy: proxy, id: targetId)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))

            Divider()

            // ── 输入框 ───────────────────────────────────
            inputBar
        }
        .navigationTitle(conversation.otherUser.nickname)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                AvatarView(user: conversation.otherUser, size: 32)
            }
        }
        .onAppear {
            AppState.shared.activeConversationId = vm.conversationId
            AppState.shared.clearUnread(conversationId: vm.conversationId)
        }
        .onDisappear {
            AppState.shared.activeConversationId = nil
        }
        .onChange(of: vm.conversationId) { _, newId in
            AppState.shared.activeConversationId = newId
            AppState.shared.clearUnread(conversationId: newId)
        }
        .alert("发送失败", isPresented: Binding(
            get: { vm.errorMsg != nil },
            set: { if !$0 { vm.errorMsg = nil } }
        )) {
            Button("好", role: .cancel) { vm.errorMsg = nil }
        } message: {
            Text(vm.errorMsg ?? "")
        }
    }

    // MARK: - Scroll & Flash

    /// 滚动到指定消息并短暂高亮 1.5 秒
    private func scrollAndFlash(proxy: ScrollViewProxy, id: Int64) {
        withAnimation(.easeInOut(duration: 0.4)) {
            proxy.scrollTo(id, anchor: .center)
        }
        flashedMsgId = id
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.easeOut(duration: 0.4)) {
                flashedMsgId = nil
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            // 图片选择
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        vm.sendImage(data)
                    }
                    selectedPhoto = nil
                }
            }

            // 文本输入
            TextField("发消息…", text: $vm.inputText, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .focused($inputFocused)
                .onSubmit { vm.sendText() }

            // 发送按钮
            Button {
                vm.sendText()
                inputFocused = false
            } label: {
                Image(systemName: vm.inputText.isEmpty ? "mic.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.blue.opacity(vm.inputText.isEmpty ? 0.4 : 1.0))
                    .animation(.spring(duration: 0.2), value: vm.inputText.isEmpty)
            }
            .disabled(vm.inputText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: LocalMessage
    var isHighlighted: Bool = false
    @State private var showFullImage  = false
    @State private var useOriginalUrl = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isMine { Spacer(minLength: 60) }

            if !message.isMine {
                Circle()
                    .fill(colorForName(message.senderNickname))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Text(String(message.senderNickname.prefix(1)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }

            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                if !message.isMine {
                    Text(message.senderNickname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                bubbleContent

                Text(formatTime(message.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if !message.isMine { Spacer(minLength: 60) }
        }
        .padding(.vertical, 3)
        // 高亮背景（搜索定位时闪烁）
        .background(
            isHighlighted
                ? Color.orange.opacity(0.18).clipShape(RoundedRectangle(cornerRadius: 12))
                : nil
        )
        .animation(.easeInOut(duration: 0.3), value: isHighlighted)
        .sheet(isPresented: $showFullImage) {
            FullImageViewer(url: message.mediaUrl)
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        if message.msgType == "image", !message.mediaUrl.isEmpty {
            imageBubble
        } else {
            textBubble
        }
    }

    // ── 图片气泡 ──────────────────────────────────────────────────
    private var imageBubble: some View {
        let (bw, bh) = bubbleSize
        let displayUrl = (!message.thumbUrl.isEmpty && !useOriginalUrl)
            ? message.thumbUrl : message.mediaUrl

        return AsyncImage(url: URL(string: displayUrl)) { phase in
            switch phase {
            case .empty:
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray5))
                    ProgressView()
                }
                .frame(width: bw, height: bh)

            case .success(let img):
                img.resizable()
                    .scaledToFill()
                    .frame(width: bw, height: bh)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        if !message.thumbUrl.isEmpty && !useOriginalUrl {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(4)
                                .background(.black.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                        }
                    }

            case .failure:
                if !useOriginalUrl && !message.thumbUrl.isEmpty {
                    Color.clear
                        .frame(width: bw, height: bh)
                        .onAppear { useOriginalUrl = true }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray5))
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                            Text("图片加载失败").font(.caption2).foregroundStyle(.secondary)
                            Text("点击重试").font(.caption2).foregroundStyle(.blue)
                        }
                    }
                    .frame(width: bw, height: bh)
                    .onTapGesture {
                        useOriginalUrl = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(100))
                            useOriginalUrl = false
                        }
                    }
                }

            @unknown default: EmptyView()
            }
        }
        .onTapGesture { if !message.mediaUrl.isEmpty { showFullImage = true } }
    }

    private var bubbleSize: (CGFloat, CGFloat) {
        let maxW: CGFloat = 200; let maxH: CGFloat = 280
        guard message.imageWidth > 0, message.imageHeight > 0 else { return (maxW, maxW * 0.75) }
        let ratio = CGFloat(message.imageWidth) / CGFloat(message.imageHeight)
        if ratio >= 1 {
            let w = min(maxW, CGFloat(message.imageWidth)); return (w, w / ratio)
        } else {
            let h = min(maxH, maxW / ratio); return (h * ratio, h)
        }
    }

    // ── 文字气泡 ──────────────────────────────────────────────────
    private var textBubble: some View {
        Text(message.plainContent)
            .font(.system(size: 16))
            .foregroundStyle(message.isMine ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.isMine
                    ? AnyView(LinearGradient(colors: [Color(hex: "4776E6"), Color(hex: "8E54E9")],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyView(Color(.systemBackground))
            )
            .clipShape(BubbleShape(isMe: message.isMine))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    private func colorForName(_ name: String) -> Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .red, .teal]
        return palette[abs(name.hashValue) % palette.count]
    }
    private func formatTime(_ date: Date) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"; return fmt.string(from: date)
    }
}

// MARK: - FullImageViewer

struct FullImageViewer: View {
    let url: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .empty:
                        ProgressView().tint(.white)
                    default:
                        Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.white)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - BubbleShape（QQ 风格气泡）

struct BubbleShape: Shape {
    let isMe: Bool
    private let radius: CGFloat = 18
    private let tailSize: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width; let h = rect.height
        let r = min(radius, h / 2)

        if isMe {
            path.move(to: CGPoint(x: w - tailSize, y: h - r))
            path.addLine(to: CGPoint(x: w - tailSize, y: r))
            path.addArc(center: CGPoint(x: w - tailSize - r, y: r),
                        radius: r, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addArc(center: CGPoint(x: r, y: r),
                        radius: r, startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
            path.addLine(to: CGPoint(x: 0, y: h - r))
            path.addArc(center: CGPoint(x: r, y: h - r),
                        radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: w - tailSize, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w - tailSize, y: h - r))
        } else {
            path.move(to: CGPoint(x: tailSize, y: r))
            path.addLine(to: CGPoint(x: tailSize, y: h - r))
            path.addLine(to: CGPoint(x: tailSize, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: tailSize, y: h - r))
            path.addArc(center: CGPoint(x: tailSize + r, y: h - r),
                        radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            path.addLine(to: CGPoint(x: w - r, y: h))
            path.addArc(center: CGPoint(x: w - r, y: h - r),
                        radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            path.addLine(to: CGPoint(x: w, y: r))
            path.addArc(center: CGPoint(x: w - r, y: r),
                        radius: r, startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
            path.addLine(to: CGPoint(x: tailSize + r, y: 0))
            path.addArc(center: CGPoint(x: tailSize + r, y: r),
                        radius: r, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - E2EStatusBanner

struct E2EStatusBanner: View {
    @ObservedObject var vm: ChatViewModel
    @State private var isRetrying = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange).font(.system(size: 14))

            Text("加密通道未就绪，对方需重新登录")
                .font(.caption).foregroundStyle(.secondary)

            Spacer()

            Button {
                isRetrying = true
                vm.retryPeerKey()
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    isRetrying = false
                }
            } label: {
                if isRetrying { ProgressView().scaleEffect(0.7) }
                else { Text("重试").font(.caption.bold()).foregroundStyle(.blue) }
            }
            .disabled(isRetrying)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.2)), alignment: .bottom)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: vm.peerE2EReady)
    }
}

// MARK: - AvatarView

struct AvatarView: View {
    let user: User
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(user.avatarColor.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(user.initial)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
