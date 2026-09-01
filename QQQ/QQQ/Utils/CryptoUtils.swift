import CryptoKit
import Foundation

/// AES-256-GCM 加解密工具
/// 与 Go 端 AES-GCM 格式完全兼容：
///   combined = nonce(12) + ciphertext + tag(16)，整体 base64 编码
enum CryptoUtils {
    private static let keyData = Data("QQQSecretKey2026QQQSecretKey2026".utf8)
    private static let symmetricKey = SymmetricKey(data: keyData)

    static func encrypt(_ plaintext: String) throws -> String {
        guard let data = plaintext.data(using: .utf8) else {
            throw CryptoError.encodingFailed
        }
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw CryptoError.sealFailed
        }
        return combined.base64EncodedString()
    }

    static func decrypt(_ base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else {
            throw CryptoError.decodingFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
        guard let str = String(data: decrypted, encoding: .utf8) else {
            throw CryptoError.decodingFailed
        }
        return str
    }

    enum CryptoError: Error, LocalizedError {
        case encodingFailed, decodingFailed, sealFailed

        var errorDescription: String? {
            switch self {
            case .encodingFailed: "编码失败"
            case .decodingFailed: "解码失败"
            case .sealFailed:     "加密失败"
            }
        }
    }
}
