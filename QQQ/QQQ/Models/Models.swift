import Foundation
import SwiftUI

// MARK: - User

struct User: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: Int64
    let username: String
    let nickname: String
    let avatarUrl: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, nickname
        case avatarUrl = "avatar_url"
        case createdAt = "created_at"
    }

    var initial: String { String(nickname.prefix(1)) }

    var avatarColor: Color {
        let palette: [Color] = [.blue, .purple, .green, .orange, .red, .teal, .indigo, .pink]
        let idx = abs(username.hashValue) % palette.count
        return palette[idx]
    }
}

// MARK: - Message (服务端模型)

struct RemoteMessage: Codable, Identifiable, Sendable {
    let id: Int64
    let conversationId: Int64
    let senderId: Int64
    let receiverId: Int64
    let content: String     // AES-GCM base64 密文
    let msgType: String     // "text" | "image"
    let mediaUrl: String
    let isRead: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case senderId       = "sender_id"
        case receiverId     = "receiver_id"
        case content
        case msgType        = "msg_type"
        case mediaUrl       = "media_url"
        case isRead         = "is_read"
        case createdAt      = "created_at"
    }
}

// MARK: - LocalMessage (本地显示用)

struct LocalMessage: Identifiable, Equatable, Sendable {
    var id: Int64
    var conversationId: Int64
    var senderId: Int64
    var senderNickname: String
    var plainContent: String    // 解密后明文
    var msgType: String         // "text" | "image"
    var mediaUrl: String        // 原图 URL
    var thumbUrl: String        // 缩略图 URL（无则空）
    var imageWidth: Int         // 原图宽度 px（0 = 未知）
    var imageHeight: Int        // 原图高度 px（0 = 未知）
    var createdAt: Date
    var isMine: Bool
}

// MARK: - Conversation

struct Conversation: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: Int64
    let otherUser: User
    let lastMessage: String
    let lastMessageAt: String
    let unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case otherUser      = "other_user"
        case lastMessage    = "last_message"
        case lastMessageAt  = "last_message_at"
        case unreadCount    = "unread_count"
    }
}

// MARK: - WebSocket 协议

struct WSOutgoing: Encodable, Sendable {
    let type: String
    let to: Int64?
    let content: String?
    let msgType: String?
    let mediaUrl: String?
    let clientMsgId: String?

    enum CodingKeys: String, CodingKey {
        case type, to, content
        case msgType     = "msg_type"
        case mediaUrl    = "media_url"
        case clientMsgId = "client_msg_id"
    }
}

struct WSIncoming: Decodable, Sendable {
    let type: String
    let id: Int64?
    let from: Int64?
    let fromNickname: String?
    let content: String?
    let msgType: String?
    let mediaUrl: String?
    let conversationId: Int64?
    let createdAt: String?
    let clientMsgId: String?
    let messageId: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, id, from, content, error
        case fromNickname   = "from_nickname"
        case msgType        = "msg_type"
        case mediaUrl       = "media_url"
        case conversationId = "conversation_id"
        case createdAt      = "created_at"
        case clientMsgId    = "client_msg_id"
        case messageId      = "message_id"
    }
}

// MARK: - API 响应

struct LoginRequest: Encodable, Sendable {
    let username: String
    let password: String
}

/// 登录响应：服务端返回 Access Token（2h）+ Refresh Token（30d）
struct LoginResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

/// 刷新响应：用 Refresh Token 换新的 token pair
struct RefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct ConversationsResponse: Decodable, Sendable {
    let conversations: [Conversation]
}

struct MessagesResponse: Decodable, Sendable {
    let messages: [RemoteMessage]
}

struct UsersResponse: Decodable, Sendable {
    let users: [User]
}

struct UploadResponse: Decodable, Sendable {
    let url: String
    let hash: String?   // SHA256 hex（内容寻址，秒传用）
}

struct FileCheckResponse: Decodable, Sendable {
    let url: String
    let thumbUrl: String
    enum CodingKeys: String, CodingKey {
        case url
        case thumbUrl = "thumb_url"
    }
}

// MARK: - E2EE

/// E2EE 消息内层载荷（加密前 / 解密后）
struct E2EPayload: Codable, Sendable {
    let t: String       // "text" | "image"
    let v: String       // 文本内容 或 原图 URL
    let thumb: String?  // 缩略图 URL（image 消息）
    let w: Int?         // 原图宽度 px（image 消息，用于气泡占位）
    let h: Int?         // 原图高度 px（image 消息）
}

struct PublicKeyResponse: Decodable, Sendable {
    let userId: Int64
    let publicKey: String
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case publicKey = "public_key"
    }
}

// MARK: - Search

/// 消息搜索结果，包含原始 LocalMessage、FTS5 片段和所属会话信息
struct SearchResult: Identifiable, Sendable {
    var id: Int64 { message.id }
    let message: LocalMessage
    let snippet: String          // FTS5 高亮片段（《词》格式）
    var conversation: Conversation?

    var conversationName: String { conversation?.otherUser.nickname ?? "未知对话" }
}

// MARK: - Notifications

extension Notification.Name {
    /// Access Token + Refresh Token 均无效时发出，AppState 收到后强制登出
    static let qqSessionExpired = Notification.Name("QQQSessionExpired")
}
