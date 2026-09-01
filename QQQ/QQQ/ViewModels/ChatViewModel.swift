import Foundation
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [LocalMessage] = []
    @Published var inputText  = ""
    @Published var isLoading  = false
    @Published var errorMsg: String?
    @Published var peerE2EReady = false
    @Published var conversationId: Int64

    let conversation: Conversation
    private let currentUser: User
    private let api = APIService.shared
    private let ws  = WebSocketService.shared
    private let db  = DatabaseService.shared
    private let e2e = E2EEService.shared
    private var cancellables = Set<AnyCancellable>()

    init(conversation: Conversation, currentUser: User) {
        self.conversation   = conversation
        self.currentUser    = currentUser
        self.conversationId = conversation.id
        observeIncoming()
        if conversation.id > 0 {
            messages = db.getMessages(conversationId: conversation.id)
        }
    }

    // MARK: - Load History（两阶段增量）

    func loadMessages() async {
        guard conversationId > 0 else { return }
        isLoading = true
        defer { isLoading = false }

        await e2e.prefetchPeerKey(conversation.otherUser.id)
        peerE2EReady = e2e.isPeerKeyReady(conversation.otherUser.id)

        let localMaxId = db.latestMessageId(conversationId: conversationId)

        do {
            let remotes = try await api.getMessages(
                conversationId: conversationId,
                sinceId: localMaxId,
                limit: 60
            )
            guard !remotes.isEmpty else { return }

            var newLocal: [LocalMessage] = []
            for r in remotes {
                let d = await decryptRemote(r)
                newLocal.append(LocalMessage(
                    id:             r.id,
                    conversationId: r.conversationId,
                    senderId:       r.senderId,
                    senderNickname: r.senderId == currentUser.id
                                        ? currentUser.nickname
                                        : conversation.otherUser.nickname,
                    plainContent:   d.plain,
                    msgType:        d.msgType,
                    mediaUrl:       d.mediaUrl,
                    thumbUrl:       d.thumbUrl,
                    imageWidth:     d.imgW,
                    imageHeight:    d.imgH,
                    createdAt:      ISO8601DateFormatter().date(from: r.createdAt) ?? Date(),
                    isMine:         r.senderId == currentUser.id
                ))
            }

            if localMaxId == 0 {
                messages = newLocal
            } else {
                let existingIds = Set(messages.map { $0.id })
                let fresh = newLocal.filter { !existingIds.contains($0.id) }
                messages.append(contentsOf: fresh)
            }
            newLocal.forEach { db.saveMessage($0) }
        } catch {
            print("[ChatVM] loadMessages error:", error)
        }
    }

    // MARK: - Decrypt

    private typealias DecryptResult = (plain: String, msgType: String, mediaUrl: String,
                                        thumbUrl: String, imgW: Int, imgH: Int)

    private func decryptRemote(_ r: RemoteMessage) async -> DecryptResult {
        switch r.msgType {
        case "e2e":
            let peerID = r.senderId == currentUser.id ? conversation.otherUser.id : r.senderId
            if let payload = try? await e2e.decrypt(ciphertext: r.content, withPeer: peerID) {
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

    // MARK: - Send Text

    func sendText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        Task {
            do {
                let ciphertext = try await e2e.encryptText(text, forUser: conversation.otherUser.id)
                peerE2EReady   = true
                let msg = LocalMessage(
                    id: Int64(Date().timeIntervalSince1970 * 1000),
                    conversationId: conversationId,
                    senderId: currentUser.id, senderNickname: currentUser.nickname,
                    plainContent: text, msgType: "text",
                    mediaUrl: "", thumbUrl: "", imageWidth: 0, imageHeight: 0,
                    createdAt: Date(), isMine: true
                )
                messages.append(msg); db.saveMessage(msg)
                ws.send(to: conversation.otherUser.id,
                        encryptedContent: ciphertext,
                        msgType: "e2e",
                        clientMsgId: UUID().uuidString)
            } catch {
                inputText = text
                peerE2EReady = false
                errorMsg = error.localizedDescription
            }
        }
    }

    // MARK: - Send Image

    func sendImage(_ imageData: Data) {
        Task {
            do {
                let upload = try await api.uploadImageWithThumbnail(imageData)
                let ciphertext = try await e2e.encryptImage(
                    url:      upload.originalUrl,
                    thumbUrl: upload.thumbUrl,
                    width:    upload.width,
                    height:   upload.height,
                    forUser:  conversation.otherUser.id
                )
                let msg = LocalMessage(
                    id: Int64(Date().timeIntervalSince1970 * 1000) + 1,
                    conversationId: conversationId,
                    senderId: currentUser.id, senderNickname: currentUser.nickname,
                    plainContent: "", msgType: "image",
                    mediaUrl:    upload.originalUrl,
                    thumbUrl:    upload.thumbUrl,
                    imageWidth:  upload.width,
                    imageHeight: upload.height,
                    createdAt: Date(), isMine: true
                )
                messages.append(msg); db.saveMessage(msg)
                ws.send(to: conversation.otherUser.id,
                        encryptedContent: ciphertext,
                        msgType: "e2e",
                        clientMsgId: UUID().uuidString)
            } catch {
                errorMsg = "图片发送失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Receive

    private func observeIncoming() {
        ws.$latestIncoming
            .compactMap { $0 }
            .sink { [weak self] incoming in
                guard let self else { return }
                switch incoming.type {
                case "message":
                    if incoming.from == conversation.otherUser.id {
                        Task { await self.handleIncoming(incoming) }
                    }
                case "ack":
                    handleAck(incoming)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func handleIncoming(_ incoming: WSIncoming) async {
        guard let from = incoming.from, from != currentUser.id else { return }

        var plain    = ""
        var msgType  = incoming.msgType ?? "text"
        var mediaUrl = ""
        var thumbUrl = ""
        var imgW     = 0
        var imgH     = 0

        if incoming.msgType == "e2e" {
            if let payload = try? await e2e.decrypt(ciphertext: incoming.content ?? "",
                                                     withPeer: conversation.otherUser.id) {
                msgType = payload.t
                if payload.t == "image" {
                    mediaUrl = payload.v
                    thumbUrl = payload.thumb ?? ""
                    imgW     = payload.w ?? 0
                    imgH     = payload.h ?? 0
                } else {
                    plain = payload.v
                }
            } else {
                plain   = "[解密失败]"
                msgType = "text"
            }
        } else if incoming.msgType == "image" {
            mediaUrl = incoming.mediaUrl ?? ""
        } else {
            plain = (try? CryptoUtils.decrypt(incoming.content ?? "")) ?? "[解密失败]"
        }

        if let cid = incoming.conversationId, conversationId <= 0 {
            conversationId = cid
        }

        let local = LocalMessage(
            id:             incoming.id ?? Int64(Date().timeIntervalSince1970 * 1000),
            conversationId: incoming.conversationId ?? conversationId,
            senderId:       from,
            senderNickname: incoming.fromNickname ?? conversation.otherUser.nickname,
            plainContent:   plain,
            msgType:        msgType,
            mediaUrl:       mediaUrl,
            thumbUrl:       thumbUrl,
            imageWidth:     imgW,
            imageHeight:    imgH,
            createdAt:      ISO8601DateFormatter().date(from: incoming.createdAt ?? "") ?? Date(),
            isMine:         false
        )
        guard !messages.contains(where: { $0.id == local.id }) else { return }
        messages.append(local)
        db.saveMessage(local)
    }

    private func handleAck(_ ack: WSIncoming) {
        guard let realConvId = ack.conversationId, realConvId > 0 else { return }
        let needsReload = conversationId <= 0 || conversationId != realConvId
        conversationId  = realConvId
        Task {
            await AppState.shared.loadConversations()
            if needsReload { await loadMessages() }
        }
    }

    func retryPeerKey() {
        Task {
            e2e.clearPeerCache(conversation.otherUser.id)
            await e2e.prefetchPeerKey(conversation.otherUser.id)
            peerE2EReady = e2e.isPeerKeyReady(conversation.otherUser.id)
        }
    }
}
