import Foundation
import Security

/// iOS Keychain 封装
/// 用于安全存储 JWT Token、用户信息等敏感数据
/// 使用 kSecAttrAccessibleAfterFirstUnlock — 设备首次解锁后可访问，支持 App 后台读取
enum KeychainService {

    // MARK: - Keys

    enum Keys {
        static let authToken    = "qqq_auth_token"
        static let refreshToken = "qqq_refresh_token"
        static let currentUser  = "qqq_current_user"
        /// X25519 私钥 raw bytes base64（永不离开设备）
        static let e2ePrivateKey = "qqq_e2e_private_key"
    }

    private static let service = "com.yuan.QQQ"

    // MARK: - CRUD

    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 先尝试更新已有条目
        let searchQuery: [String: Any] = [
            kSecClass    as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let updateAttr: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(searchQuery as CFDictionary, updateAttr as CFDictionary) == errSecSuccess {
            return true
        }

        // 条目不存在，新增
        var addQuery = searchQuery
        addQuery[kSecValueData as String]   = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - JWT 过期检查（无需网络，本地解析 payload）

    /// 检查 JWT 是否已过期（本地解析 exp claim，避免用过期 token 自动登录）
    static func isTokenExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }

        // base64url → base64 标准
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem != 0 { base64 += String(repeating: "=", count: 4 - rem) }

        guard let payloadData = Data(base64Encoded: base64),
              let dict = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let exp  = dict["exp"] as? TimeInterval else { return true }

        // 提前 60 秒判为过期，给网络请求留出余量
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 60
    }
}
