import Foundation
import Combine

@MainActor
class AppState: ObservableObject {
    static let shared = AppState()

    @Published var currentUser: User?
    @Published var isLoggedIn  = false
    @Published var token: String = ""

    @Published var conversations: [Conversation] = []
    @Published var contacts: [User] = []

    /// 被踢出时的提示（非 nil 时 ContentView 弹 alert）
    @Published var kickedOutReason: String? = nil

    /// 当前正在查看的会话 ID
    var activeConversationId: Int64? = nil

    private let api = APIService.shared
    private let ws  = WebSocketService.shared
    private var wsCancellables = Set<AnyCancellable>()

    // MARK: - Init（自动登录）

    init() {
        observeSessionExpiry()   // 先挂通知，再尝试登录
        tryAutoLogin()
    }

    /// 监听 session 过期通知（API refresh 失败时由 APIService 发出）
    private func observeSessionExpiry() {
        NotificationCenter.default.addObserver(
            forName: .qqSessionExpired,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isLoggedIn else { return }
            self.forceLogout(reason: "登录已过期，请重新登录")
        }
    }

    /// 启动时尝试恢复登录态：
    ///  - 有 refresh_token（新格式）且 access_token 有效 → 直接恢复
    ///  - 有 refresh_token 但 access_token 过期 → 后台 silentRefresh
    ///  - 没有 refresh_token（旧格式 / 首次启动） → 清 Keychain，回登录页
    private func tryAutoLogin() {
        guard let userJson     = KeychainService.load(key: KeychainService.Keys.currentUser),
              let userJsonData = userJson.data(using: .utf8),
              let user         = try? JSONDecoder().decode(User.self, from: userJsonData) else {
            clearKeychain(); return
        }

        // 必须有 refresh token（新双 Token 格式），否则视为过期旧格式
        guard KeychainService.load(key: KeychainService.Keys.refreshToken) != nil else {
            print("[AppState] No refresh token (old format) — clearing Keychain")
            clearKeychain(); return
        }

        if let accessToken = KeychainService.load(key: KeychainService.Keys.authToken),
           !KeychainService.isTokenExpired(accessToken) {
            // Access Token 仍有效，直接恢复会话
            restoreSession(token: accessToken, user: user)
        } else {
            // Access Token 过期，静默 Refresh
            Task { await silentRefresh(cachedUser: user) }
        }
    }

    /// 用 Refresh Token 静默换取新 token pair，成功后恢复会话
    private func silentRefresh(cachedUser: User) async {
        do {
            let newAccessToken = try await api.refreshAccessToken()
            // 重新读取 user（refreshAccessToken 已更新 Keychain，user 不变）
            restoreSession(token: newAccessToken, user: cachedUser)
        } catch {
            print("[AppState] Silent refresh failed:", error.localizedDescription)
            clearKeychain()   // Refresh Token 也过期，回到登录页
        }
    }

    private func restoreSession(token: String, user: User) {
        api.token   = token
        self.token  = token
        currentUser = user
        ws.connect(token: token)
        observeWebSocket()
        // E2EE：加载/生成密钥对，上传公钥（后台，不阻塞登录）
        Task {
            do { try await E2EEService.shared.setup() }
            catch { print("[AppState] E2EE setup failed:", error) }
        }
        isLoggedIn  = true
        print("[AppState] Session restored: \(user.nickname)")
    }

    // MARK: - Auth

    func login(username: String, password: String) async throws {
        let resp = try await api.login(username: username, password: password)
        api.token = resp.accessToken

        // ── 双 Token 存入 Keychain ──────────────────────────────
        KeychainService.save(key: KeychainService.Keys.authToken,    value: resp.accessToken)
        KeychainService.save(key: KeychainService.Keys.refreshToken, value: resp.refreshToken)
        if let userJson = try? JSONEncoder().encode(resp.user),
           let userStr  = String(data: userJson, encoding: .utf8) {
            KeychainService.save(key: KeychainService.Keys.currentUser, value: userStr)
        }

        token       = resp.accessToken
        currentUser = resp.user
        ws.connect(token: resp.accessToken)
        observeWebSocket()
        Task {
            do { try await E2EEService.shared.setup() }
            catch { print("[AppState] E2EE setup failed:", error) }
        }
        isLoggedIn  = true
    }

    func logout() {
        ws.disconnect()
        wsCancellables.removeAll()
        E2EEService.shared.clearCaches()
        clearKeychain()
        token        = ""
        currentUser  = nil
        isLoggedIn   = false
        conversations = []
        contacts      = []
        api.token    = ""
        activeConversationId = nil
    }

    func forceLogout(reason: String) {
        kickedOutReason = reason
        logout()
    }

    private func clearKeychain() {
        KeychainService.delete(key: KeychainService.Keys.authToken)
        KeychainService.delete(key: KeychainService.Keys.refreshToken)
        KeychainService.delete(key: KeychainService.Keys.currentUser)
    }

    // MARK: - Data Loading

    func loadInitialData() async {
        async let c: () = loadConversations()
        async let u: () = loadContacts()
        await c; await u
    }

    func loadConversations() async {
        do {
            conversations = try await api.listConversations()
            // 会话列表拉到后，立即后台同步所有会话的离线消息到本地 DB
            Task { await backgroundSyncAll() }
        } catch {
            print("[AppState] conversations:", error)
        }
    }

    func loadContacts() async {
        do { contacts = try await api.listUsers() }
        catch { print("[AppState] contacts:", error) }
    }

    // MARK: - Conversation Helpers

    func upsertConversation(_ conv: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0)
        }
    }

    func updateLastMessage(conversationId: Int64, preview: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        let old = conversations[idx]
        let updated = Conversation(id: old.id, otherUser: old.otherUser,
                                   lastMessage: preview,
                                   lastMessageAt: ISO8601DateFormatter().string(from: Date()),
                                   unreadCount: old.unreadCount)
        conversations.remove(at: idx)
        conversations.insert(updated, at: 0)
    }

    func clearUnread(conversationId: Int64) {
        guard let idx = conversations.firstIndex(where: { $0.id == conversationId }) else { return }
        let old = conversations[idx]
        conversations[idx] = Conversation(id: old.id, otherUser: old.otherUser,
                                          lastMessage: old.lastMessage,
                                          lastMessageAt: old.lastMessageAt,
                                          unreadCount: 0)
    }

    // MARK: - WebSocket Observation

    func observeWebSocket() {
        wsCancellables.removeAll()
        ws.$latestIncoming
            .compactMap { $0 }
            .filter { $0.type == "message" }
            .sink { [weak self] incoming in self?.handleIncomingForList(incoming) }
            .store(in: &wsCancellables)
    }

    private func handleIncomingForList(_ incoming: WSIncoming) {
        guard let convId = incoming.conversationId else {
            Task { await loadConversations() }; return
        }
        // E2EE 消息：AppState 不解密，统一显示通用预览
        let preview: String
        switch incoming.msgType {
        case "e2e":   preview = "[消息]"
        case "image": preview = "[图片]"
        default:      preview = (try? CryptoUtils.decrypt(incoming.content ?? "")) ?? "[消息]"
        }
        let now = ISO8601DateFormatter().string(from: Date())

        if let idx = conversations.firstIndex(where: { $0.id == convId }) {
            let old       = conversations[idx]
            let addUnread = (activeConversationId != convId) ? 1 : 0
            let updated   = Conversation(id: old.id, otherUser: old.otherUser,
                                         lastMessage: preview,
                                         lastMessageAt: incoming.createdAt ?? now,
                                         unreadCount: old.unreadCount + addUnread)
            conversations.remove(at: idx)
            conversations.insert(updated, at: 0)
        } else {
            Task { await loadConversations() }
        }

        // ── 无论当前是否在该聊天页，都把消息存入本地 DB ──────────────────
        // 保证离线消息在下次打开 App 时仍可搜索 / 展示
        Task { await saveIncomingToLocalDB(incoming) }
    }

    // MARK: - 后台全量同步

    /// 登录后对所有会话做增量拉取：
    ///  since_id = 本地最大 msg id（没有则全量取最新 100 条）
    ///  E2EE 解密后写入 SQLite，不阻塞 UI
    private func backgroundSyncAll() async {
        guard !conversations.isEmpty, let myId = currentUser?.id else { return }
        print("[Sync] 开始后台同步 \(conversations.count) 个会话")

        await withTaskGroup(of: Void.self) { group in
            for conv in conversations {
                group.addTask { [weak self] in
                    await self?.syncConversation(conv, myId: myId)
                }
            }
        }
        print("[Sync] 后台同步完成")
    }

    private func syncConversation(_ conv: Conversation, myId: Int64) async {
        let db = DatabaseService.shared
        let localMaxId = db.latestMessageId(conversationId: conv.id)

        do {
            let remotes = try await api.getMessages(
                conversationId: conv.id,
                sinceId: localMaxId,
                limit: 100
            )
            guard !remotes.isEmpty else { return }

            // 预拉对方公钥（E2EE 解密需要）
            await E2EEService.shared.prefetchPeerKey(conv.otherUser.id)

            var saved = 0
            for r in remotes {
                let (plain, msgType, mediaUrl, thumbUrl, imgW, imgH) =
                    await decryptForSync(r, peerID: conv.otherUser.id, myId: myId)

                // ⚠️ 解密失败保护：若 E2EE 解密失败（msgType 被降级为 text 且内容是 [解密失败]），
                // 不用坏数据覆盖本地 SQLite 里可能已有的正确记录
                if plain == "[解密失败]" && r.msgType == "e2e" {
                    continue
                }

                let local = LocalMessage(
                    id:             r.id,
                    conversationId: r.conversationId,
                    senderId:       r.senderId,
                    senderNickname: r.senderId == myId
                                        ? (currentUser?.nickname ?? "")
                                        : conv.otherUser.nickname,
                    plainContent:   plain,
                    msgType:        msgType,
                    mediaUrl:       mediaUrl,
                    thumbUrl:       thumbUrl,
                    imageWidth:     imgW,
                    imageHeight:    imgH,
                    createdAt:      ISO8601DateFormatter().date(from: r.createdAt) ?? Date(),
                    isMine:         r.senderId == myId
                )
                db.saveMessage(local)
                saved += 1
            }
            print("[Sync] 会话 \(conv.id)（\(conv.otherUser.nickname)）同步 \(saved)/\(remotes.count) 条")
        } catch {
            // 单个会话同步失败不影响其他会话
            print("[Sync] 会话 \(conv.id) 同步失败:", error.localizedDescription)
        }
    }

    /// 解密一条服务端消息（与 ChatViewModel.decryptRemote 逻辑相同，但在 AppState 层执行）
    private func decryptForSync(_ r: RemoteMessage, peerID: Int64, myId: Int64) async
        -> (plain: String, msgType: String, mediaUrl: String,
            thumbUrl: String, imgW: Int, imgH: Int) {
        switch r.msgType {
        case "e2e":
            // 双方的 ECDH 会话密钥以 peerID 为索引（无论谁发的都一样）
            if let payload = try? await E2EEService.shared.decrypt(
                ciphertext: r.content, withPeer: peerID) {
                if payload.t == "image" {
                    return ("", "image", payload.v,
                            payload.thumb ?? "", payload.w ?? 0, payload.h ?? 0)
                }
                return (payload.v, "text", "", "", 0, 0)
            }
            return ("[解密失败]", "text", "", "", 0, 0)
        case "image":
            return ("", "image", r.mediaUrl, "", 0, 0)
        default:
            return ((try? CryptoUtils.decrypt(r.content)) ?? "[解密失败]", "text", "", "", 0, 0)
        }
    }

    /// 把 WebSocket 实时消息（包括离线补拉的）存入本地 DB
    /// 即使用户没有打开该聊天页，消息也会持久化
    private func saveIncomingToLocalDB(_ incoming: WSIncoming) async {
        guard let from   = incoming.from,
              let convId = incoming.conversationId,
              let myId   = currentUser?.id else { return }

        // 找对应会话（用于获取 peerID 做 E2EE 解密）
        let conv = conversations.first { $0.id == convId }
        let peerID = from   // 发过来的消息，peer 就是 from

        var plain    = ""
        var msgType  = incoming.msgType ?? "text"
        var mediaUrl = ""
        var thumbUrl = ""
        var imgW = 0, imgH = 0

        if incoming.msgType == "e2e" {
            if let payload = try? await E2EEService.shared.decrypt(
                ciphertext: incoming.content ?? "", withPeer: peerID) {
                msgType = payload.t
                if payload.t == "image" {
                    mediaUrl = payload.v
                    thumbUrl = payload.thumb ?? ""
                    imgW     = payload.w ?? 0
                    imgH     = payload.h ?? 0
                } else {
                    plain = payload.v
                }
            }
        } else if incoming.msgType == "image" {
            mediaUrl = incoming.mediaUrl ?? ""
        } else {
            plain = (try? CryptoUtils.decrypt(incoming.content ?? "")) ?? ""
        }

        let local = LocalMessage(
            id:             incoming.id ?? Int64(Date().timeIntervalSince1970 * 1000),
            conversationId: convId,
            senderId:       from,
            senderNickname: incoming.fromNickname ?? conv?.otherUser.nickname ?? "",
            plainContent:   plain,
            msgType:        msgType,
            mediaUrl:       mediaUrl,
            thumbUrl:       thumbUrl,
            imageWidth:     imgW,
            imageHeight:    imgH,
            createdAt:      ISO8601DateFormatter().date(from: incoming.createdAt ?? "") ?? Date(),
            isMine:         from == myId
        )
        DatabaseService.shared.saveMessage(local)
    }
}
