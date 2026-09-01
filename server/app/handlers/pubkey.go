package handlers

import (
	"context"
	"encoding/base64"
	"net/http"
	"strconv"

	"qqq-app/db"

	"github.com/gin-gonic/gin"
)

// UploadPublicKey PUT /api/users/me/public-key
// 客户端登录后将 X25519 公钥（32 字节 base64）上传到服务端
// 服务端只存储，不参与加解密，无法推导会话密钥
func UploadPublicKey(c *gin.Context) {
	userID := c.GetInt64("user_id")

	var req struct {
		PublicKey string `json:"public_key" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "missing public_key"})
		return
	}

	// 校验：必须是合法 base64，且解码后恰好 32 字节（X25519 公钥长度）
	raw, err := base64.StdEncoding.DecodeString(req.PublicKey)
	if err != nil || len(raw) != 32 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key: must be base64(32-byte X25519 key)"})
		return
	}

	_, err = db.DB.Exec(context.Background(), `
		INSERT INTO user_public_keys (user_id, public_key, updated_at)
		VALUES ($1, $2, NOW())
		ON CONFLICT (user_id) DO UPDATE
		  SET public_key = EXCLUDED.public_key,
		      updated_at = NOW()`,
		userID, req.PublicKey,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to store public key"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// GetPublicKey GET /api/users/:id/public-key
// 发送消息前，拉取对方的 X25519 公钥用于 ECDH 推导会话密钥
func GetPublicKey(c *gin.Context) {
	targetIDStr := c.Param("id")
	targetID, err := strconv.ParseInt(targetIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid user id"})
		return
	}

	var pubKey string
	err = db.DB.QueryRow(context.Background(),
		`SELECT public_key FROM user_public_keys WHERE user_id = $1`, targetID,
	).Scan(&pubKey)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "public key not found — user may not have logged in yet"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"user_id": targetID, "public_key": pubKey})
}
