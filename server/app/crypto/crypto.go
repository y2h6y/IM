package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
)

var aesKey []byte

func Init(key string) {
	aesKey = []byte(key)
}

// ── AES-256-GCM（消息加密）───────────────────────────────────────────

// Encrypt 使用 AES-256-GCM 加密，返回 base64(nonce+ciphertext+tag)
// 格式与 iOS CryptoKit AES.GCM.seal().combined 完全兼容
func Encrypt(plaintext string) (string, error) {
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err = io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(gcm.Seal(nonce, nonce, []byte(plaintext), nil)), nil
}

// Decrypt 解密 AES-256-GCM base64 密文
func Decrypt(encrypted string) (string, error) {
	data, err := base64.StdEncoding.DecodeString(encrypted)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(aesKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(data) < gcm.NonceSize() {
		return "", errors.New("ciphertext too short")
	}
	nonce, ct := data[:gcm.NonceSize()], data[gcm.NonceSize():]
	pt, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return "", err
	}
	return string(pt), nil
}

// ── Password Pepper（密码哈希强化）─────────────────────────────────────

// PepperPassword 在 bcrypt 之前对密码做 SHA256(pepper ‖ password)。
//
// 安全原理：
//   - pepper 仅存在于服务端配置，不进数据库
//   - 即使攻击者拖库拿到 bcrypt hash，没有 pepper 也无法暴力破解
//   - SHA256 输出固定 32 字节 → hex 后 64 字符，适合 bcrypt 输入
//
// 使用方式：
//
//	hash, _ := bcrypt.GenerateFromPassword([]byte(PepperPassword(password, pepper)), cost)
//	bcrypt.CompareHashAndPassword(hash, []byte(PepperPassword(password, pepper)))
func PepperPassword(password, pepper string) string {
	h := sha256.New()
	h.Write([]byte(pepper))
	h.Write([]byte(password))
	return hex.EncodeToString(h.Sum(nil))
}
