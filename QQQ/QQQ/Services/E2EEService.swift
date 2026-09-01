import CryptoKit
import Foundation

/// X25519 ECDH + AES-256-GCM 端到端加密
///
/// 安全模型：
///   - 每台设备生成唯一 X25519 密钥对，私钥存 Keychain 永不上传
///   - 公钥上传服务端（服务端只做存储和转发，无法参与推导）
///   - A 和 B 会话密钥：ECDH(A.priv, B.pub) == ECDH(B.priv, A.pub)
///   - 会话密钥经 HKDF-SHA256 再派生，最终用 AES-256-GCM 加密
///   - 服务端数据库只存密文，拿到也无法解密
class E2EEService {
    static let shared = E2EEService()

    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    /// 缓存从服务端拉取的对方公钥
    private var peerPubKeyCache: [Int64: Curve25519.KeyAgreement.PublicKey] = [:]
    /// 缓存 ECDH 推导的会话对称密钥（key = peerUserID）
    private var sessionKeyCache: [Int64: SymmetricKey] = [:]

    // MARK: - Setup

    /// 登录 / 自动登录后调用：加载或生成密钥对，上传公钥到服务端
    func setup() async throws {
        let priv = loadOrGeneratePrivateKey()
        privateKey = priv
        let pubKeyBase64 = priv.publicKey.rawRepresentation.base64EncodedString()
        do {
            try await APIService.shared.uploadPublicKey(pubKeyBase64)
            print("[E2EE] ✅ Public key uploaded — prefix:", pubKeyBase64.prefix(20), "...")
        } catch {
            print("[E2EE] ❌ Public key upload FAILED:", error.localizedDescription)
            throw error   // 向上传播，让调用方知道失败
        }
    }

    // MARK: - Public Helpers

    /// 打开聊天时预拉对方公钥，避免第一条消息发送时出现延迟/报错
    func prefetchPeerKey(_ peerID: Int64) async {
        _ = try? await sessionKey(for: peerID)
    }

    /// 检查对方会话密钥是否已就绪（本地缓存中是否有）
    func isPeerKeyReady(_ peerID: Int64) -> Bool {
        sessionKeyCache[peerID] != nil
    }

    /// 清除指定 peer 的缓存（用于重试时强制重新拉取公钥）
    func clearPeerCache(_ peerID: Int64) {
        peerPubKeyCache.removeValue(forKey: peerID)
        sessionKeyCache.removeValue(forKey: peerID)
    }

    func clearCaches() {
        peerPubKeyCache.removeAll()
        sessionKeyCache.removeAll()
        privateKey = nil
    }

    // MARK: - Encrypt

    /// 加密消息载荷（JSON string），返回 base64 密文
    /// 内层 JSON 格式：{"t":"text","v":"hello"} | {"t":"image","v":"http://..."}
    func encrypt(payload: String, forUser peerID: Int64) async throws -> String {
        let key = try await sessionKey(for: peerID)
        guard let data = payload.data(using: .utf8) else {
            throw E2EError.encodingFailed
        }
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw E2EError.sealFailed }
        return combined.base64EncodedString()
    }

    /// 便捷方法：加密文本消息
    func encryptText(_ text: String, forUser peerID: Int64) async throws -> String {
        let payload = try JSONEncoder().encode(E2EPayload(t: "text", v: text, thumb: nil, w: nil, h: nil))
        return try await encrypt(payload: String(data: payload, encoding: .utf8)!, forUser: peerID)
    }

    /// 便捷方法：加密图片 payload（含缩略图和尺寸）
    func encryptImage(url: String, thumbUrl: String = "", width: Int = 0, height: Int = 0,
                      forUser peerID: Int64) async throws -> String {
        let payload = try JSONEncoder().encode(E2EPayload(t: "image", v: url,
                                                          thumb: thumbUrl.isEmpty ? nil : thumbUrl,
                                                          w: width > 0 ? width : nil,
                                                          h: height > 0 ? height : nil))
        return try await encrypt(payload: String(data: payload, encoding: .utf8)!, forUser: peerID)
    }

    // MARK: - Decrypt

    /// 解密 base64 密文，返回内层 E2EPayload
    func decrypt(ciphertext: String, withPeer peerID: Int64) async throws -> E2EPayload {
        let key = try await sessionKey(for: peerID)
        guard let data = Data(base64Encoded: ciphertext) else { throw E2EError.decodingFailed }
        let sealed = try AES.GCM.SealedBox(combined: data)
        let plain  = try AES.GCM.open(sealed, using: key)
        return try JSONDecoder().decode(E2EPayload.self, from: plain)
    }

    // MARK: - Session Key

    private func sessionKey(for peerID: Int64) async throws -> SymmetricKey {
        if let cached = sessionKeyCache[peerID] { return cached }

        let peerPub = try await fetchPeerPublicKey(peerID)
        guard let myPriv = privateKey else { throw E2EError.noPrivateKey }

        let sharedSecret = try myPriv.sharedSecretFromKeyAgreement(with: peerPub)
        // HKDF-SHA256 派生 32 字节 AES 密钥
        let symKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: "QQQ-E2E-v1".data(using: .utf8)!,
            sharedInfo: Data(),
            outputByteCount: 32
        )
        sessionKeyCache[peerID] = symKey
        return symKey
    }

    private func fetchPeerPublicKey(_ peerID: Int64) async throws -> Curve25519.KeyAgreement.PublicKey {
        if let cached = peerPubKeyCache[peerID] { return cached }

        let base64 = try await APIService.shared.getPublicKey(userID: peerID)
        guard let raw = Data(base64Encoded: base64) else { throw E2EError.invalidPublicKey }
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        peerPubKeyCache[peerID] = pub
        return pub
    }

    // MARK: - Key Management

    private func loadOrGeneratePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let stored = KeychainService.load(key: KeychainService.Keys.e2ePrivateKey),
           let raw = Data(base64Encoded: stored),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            print("[E2EE] Loaded existing private key from Keychain")
            return key
        }
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let b64 = newKey.rawRepresentation.base64EncodedString()
        KeychainService.save(key: KeychainService.Keys.e2ePrivateKey, value: b64)
        print("[E2EE] Generated new X25519 private key")
        return newKey
    }

    // MARK: - Errors

    enum E2EError: Error, LocalizedError {
        case noPrivateKey
        case invalidPublicKey
        case encodingFailed
        case decodingFailed
        case sealFailed
        case peerKeyNotFound   // 对方尚未上传公钥

        var errorDescription: String? {
            switch self {
            case .noPrivateKey:    return "本地 E2E 密钥未初始化，请重新登录"
            case .invalidPublicKey: return "无效的公钥格式"
            case .encodingFailed:  return "编码失败"
            case .decodingFailed:  return "解密失败（数据损坏或密钥不匹配）"
            case .sealFailed:      return "加密失败"
            case .peerKeyNotFound: return "对方尚未设置加密密钥，请稍后重试"
            }
        }
    }
}
