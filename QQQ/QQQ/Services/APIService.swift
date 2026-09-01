import Foundation
import CryptoKit
import UIKit

class APIService {
    static let shared = APIService()
    private let baseURL = "https://localhost:8080"
    var token: String = ""   // Access Token，每次请求注入 Authorization header

    // MARK: - Auth

    func login(username: String, password: String) async throws -> LoginResponse {
        return try await post("/api/login",
                              body: LoginRequest(username: username, password: password),
                              auth: false)
    }

    func getMe() async throws -> User {
        return try await get("/api/users/me")
    }

    // MARK: - E2EE 公钥

    func uploadPublicKey(_ base64: String) async throws {
        struct Req: Encodable {
            let publicKey: String
            enum CodingKeys: String, CodingKey { case publicKey = "public_key" }
        }
        // 使用 PUT（RESTful 语义：更新资源），服务端同时接受 PUT 和 POST
        let _: [String: String] = try await put("/api/users/me/public-key", body: Req(publicKey: base64))
    }

    // MARK: - Private PUT helper

    private func put<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        try checkStatus(resp, data)
        return try decode(T.self, from: data)
    }

    func getPublicKey(userID: Int64) async throws -> String {
        let r: PublicKeyResponse = try await get("/api/users/\(userID)/public-key")
        return r.publicKey
    }

    // MARK: - Token Refresh（内部使用）

    /// 用 Keychain 里的 Refresh Token 换新的 token pair。
    /// 成功后自动更新 Keychain 和 self.token；失败抛 APIError.sessionExpired 并通知登出。
    func refreshAccessToken() async throws -> String {
        guard let rt = KeychainService.load(key: KeychainService.Keys.refreshToken),
              !KeychainService.isTokenExpired(rt) else {
            notifySessionExpired()
            throw APIError.sessionExpired
        }
        struct RefreshReq: Encodable {
            let refreshToken: String
            enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
        }
        do {
            let resp: RefreshResponse = try await post("/api/refresh",
                                                       body: RefreshReq(refreshToken: rt),
                                                       auth: false)
            token = resp.accessToken
            KeychainService.save(key: KeychainService.Keys.authToken,    value: resp.accessToken)
            KeychainService.save(key: KeychainService.Keys.refreshToken, value: resp.refreshToken)
            return resp.accessToken
        } catch {
            notifySessionExpired()
            throw APIError.sessionExpired
        }
    }

    private func notifySessionExpired() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .qqSessionExpired, object: nil)
        }
    }

    // MARK: - Users

    func listUsers() async throws -> [User] {
        let r: UsersResponse = try await get("/api/users")
        return r.users
    }

    // MARK: - Conversations

    func getOrCreateConversation(withUserId userId: Int64) async throws -> Conversation {
        struct Req: Encodable {
            let otherUserId: Int64
            enum CodingKeys: String, CodingKey { case otherUserId = "other_user_id" }
        }
        return try await post("/api/conversations", body: Req(otherUserId: userId))
    }

    func listConversations() async throws -> [Conversation] {
        let r: ConversationsResponse = try await get("/api/conversations")
        return r.conversations
    }

    // MARK: - Messages

    /// 拉取消息历史
    /// - sinceId: 增量模式，只返回 id > sinceId 的消息（0 = 首次全量）
    /// - limit:   每次最多返回条数（默认 60）
    func getMessages(conversationId: Int64, sinceId: Int64 = 0, limit: Int = 60) async throws -> [RemoteMessage] {
        var path = "/api/conversations/\(conversationId)/messages?limit=\(limit)"
        if sinceId > 0 { path += "&since_id=\(sinceId)" }
        let r: MessagesResponse = try await get(path)
        return r.messages
    }

    // MARK: - Image Upload（带秒传 + 缩略图）

    struct ImageUploadResult {
        let originalUrl: String
        let thumbUrl: String
        let width: Int
        let height: Int
    }

    /// 本地 SHA256 → URL 缓存（本次 session 内秒传）
    private var imageHashCache: [String: ImageUploadResult] = [:]

    /// 完整图片上传流程：
    ///  1. 计算 SHA256 → 查本地缓存（秒传）
    ///  2. 查服务端 GET /api/files/{hash}（跨设备秒传）
    ///  3. 都没有 → 并发上传原图 + 缩略图
    func uploadImageWithThumbnail(_ imageData: Data) async throws -> ImageUploadResult {
        guard let uiImage = UIImage(data: imageData) else {
            throw APIError.serverError("Invalid image data")
        }
        let width  = Int(uiImage.size.width  * uiImage.scale)
        let height = Int(uiImage.size.height * uiImage.scale)

        // ── SHA256 ────────────────────────────────────────
        let hash = sha256Hex(imageData)

        // ── 本地缓存：session 内秒传 ────────────────────────
        if let cached = imageHashCache[hash] {
            print("[Upload] 本地秒传 hash:", hash.prefix(8))
            return ImageUploadResult(originalUrl: cached.originalUrl, thumbUrl: cached.thumbUrl,
                                     width: width, height: height)
        }

        // ── 服务端检查：跨设备秒传 ──────────────────────────
        if let existing = try? await checkFileExists(hash: hash) {
            let result = ImageUploadResult(originalUrl: existing.url, thumbUrl: existing.thumbUrl,
                                           width: width, height: height)
            imageHashCache[hash] = result
            print("[Upload] 服务端秒传 hash:", hash.prefix(8))
            return result
        }

        // ── 生成缩略图（198px max dimension）────────────────
        let thumbData = generateThumbnail(from: imageData, maxDimension: 198)

        // ── 上传原图 ─────────────────────────────────────────
        let originalUrl = try await uploadRawImage(imageData, filename: hash + ".jpg")

        // ── 上传缩略图（失败不影响原图）────────────────────────
        var thumbUrl = ""
        if let td = thumbData {
            thumbUrl = (try? await uploadRawImage(td, filename: hash + "_t.jpg")) ?? ""
        }

        let result = ImageUploadResult(originalUrl: originalUrl, thumbUrl: thumbUrl,
                                       width: width, height: height)
        imageHashCache[hash] = result
        return result
    }

    // MARK: - Private Image Helpers

    private func checkFileExists(hash: String) async throws -> FileCheckResponse {
        return try await get("/api/files/\(hash)")
    }

    private func uploadRawImage(_ data: Data, filename: String) async throws -> String {
        let url = URL(string: baseURL + "/api/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (respData, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(UploadResponse.self, from: respData).url
    }

    /// SHA256(data) → lowercase hex string
    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    /// 生成缩略图：max dimension = maxDimension 物理像素（不是逻辑点）
    /// 修复：强制 scale=1 避免 UIGraphicsImageRenderer 按屏幕 3x 放大
    func generateThumbnail(from imageData: Data, maxDimension: CGFloat = 198) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        // size 是逻辑点（points），乘以 scale 得到像素
        let pixelW = image.size.width  * image.scale
        let pixelH = image.size.height * image.scale
        let maxPx  = max(pixelW, pixelH)
        guard maxPx > 0 else { return nil }

        if maxPx <= maxDimension {
            // 已经足够小，直接压缩
            return image.jpegData(compressionQuality: 0.75)
        }

        let ratio = maxDimension / maxPx
        // scale=1：输出 size 直接代表像素（不再被 3× 放大）
        let thumbPx = CGSize(width: (pixelW * ratio).rounded(),
                             height: (pixelH * ratio).rounded())

        let format        = UIGraphicsImageRendererFormat()
        format.scale      = 1.0    // ← 关键：强制 1:1 像素输出
        format.opaque     = true
        let renderer = UIGraphicsImageRenderer(size: thumbPx, format: format)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbPx))
        }
        return thumb.jpegData(compressionQuality: 0.75)
    }

    // MARK: - Upload（旧接口保留向下兼容）

    func uploadImage(_ imageData: Data, filename: String = "image.jpg") async throws -> String {
        return try await uploadRawImage(imageData, filename: filename)
    }

    // MARK: - Private Helpers

    /// GET 请求；如遇 401 会自动刷新 token 后重试一次
    private func get<T: Decodable>(_ path: String, retried: Bool = false) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: request)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401, !retried {
            _ = try await refreshAccessToken()      // 换新 access token
            return try await get(path, retried: true) // 重试一次
        }
        try checkStatus(resp, data)
        return try decode(T.self, from: data)
    }

    /// POST 请求；如遇 401（且需要 auth）会自动刷新后重试一次
    private func post<B: Encodable, T: Decodable>(_ path: String,
                                                  body: B,
                                                  auth: Bool = true,
                                                  retried: Bool = false) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if auth && !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: request)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401, auth, !retried {
            _ = try await refreshAccessToken()
            return try await post(path, body: body, auth: auth, retried: true)
        }
        try checkStatus(resp, data)
        return try decode(T.self, from: data)
    }

    private func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, http.statusCode >= 400 else { return }
        let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            ?? "HTTP \(http.statusCode)"
        if http.statusCode == 401 { throw APIError.sessionExpired }
        throw APIError.serverError(msg)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    enum APIError: Error, LocalizedError {
        case serverError(String)
        case sessionExpired      // Refresh Token 也过期，需重新登录

        var errorDescription: String? {
            switch self {
            case .serverError(let m): return m
            case .sessionExpired:     return "登录已过期，请重新登录"
            }
        }
    }
}
