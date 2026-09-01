package handlers

import (
	"context"
	"net/http"
	"strconv"

	"qqq-app/db"
	"qqq-app/models"

	"github.com/gin-gonic/gin"
)

// GetOrCreateConversation POST /api/conversations
// 获取或创建与某用户的 C2C 会话，打开联系人聊天时调用，保证会话 ID 真实存在
func GetOrCreateConversation(c *gin.Context) {
	userID := c.GetInt64("user_id")

	var req struct {
		OtherUserID int64 `json:"other_user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request"})
		return
	}

	otherID := req.OtherUserID
	if otherID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot chat with yourself"})
		return
	}

	a, b := userID, otherID
	if a > b {
		a, b = b, a
	}

	// ON CONFLICT DO UPDATE 触发 RETURNING（no-op update 只是为了让 RETURNING 生效）
	var convID int64
	err := db.DB.QueryRow(context.Background(), `
		INSERT INTO conversations (user_a_id, user_b_id)
		VALUES ($1, $2)
		ON CONFLICT (user_a_id, user_b_id) DO UPDATE
		  SET last_message_at = conversations.last_message_at
		RETURNING id`,
		a, b,
	).Scan(&convID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	// 查询完整会话信息
	var conv models.Conversation
	conv.ID = convID

	err = db.DB.QueryRow(context.Background(),
		`SELECT id, username, nickname, avatar_url, created_at FROM users WHERE id = $1`,
		otherID,
	).Scan(&conv.OtherUser.ID, &conv.OtherUser.Username, &conv.OtherUser.Nickname,
		&conv.OtherUser.AvatarURL, &conv.OtherUser.CreatedAt)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	db.DB.QueryRow(context.Background(),
		`SELECT COALESCE(last_message,''), last_message_at FROM conversations WHERE id = $1`,
		convID,
	).Scan(&conv.LastMessage, &conv.LastMessageAt)

	c.JSON(http.StatusOK, conv)
}

// ListConversations 获取当前用户的所有会话列表
func ListConversations(c *gin.Context) {
	userID := c.GetInt64("user_id")

	rows, err := db.DB.Query(context.Background(), `
		SELECT
			conv.id,
			conv.last_message,
			conv.last_message_at,
			u.id, u.username, u.nickname, u.avatar_url,
			COUNT(m.id) FILTER (WHERE m.receiver_id = $1 AND m.is_read = false) AS unread
		FROM conversations conv
		JOIN users u ON u.id = CASE
			WHEN conv.user_a_id = $1 THEN conv.user_b_id
			ELSE conv.user_a_id
		END
		LEFT JOIN messages m ON m.conversation_id = conv.id
		WHERE conv.user_a_id = $1 OR conv.user_b_id = $1
		GROUP BY conv.id, u.id
		ORDER BY conv.last_message_at DESC
	`, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query failed"})
		return
	}
	defer rows.Close()

	var convs []models.Conversation
	for rows.Next() {
		var conv models.Conversation
		err := rows.Scan(
			&conv.ID, &conv.LastMessage, &conv.LastMessageAt,
			&conv.OtherUser.ID, &conv.OtherUser.Username,
			&conv.OtherUser.Nickname, &conv.OtherUser.AvatarURL,
			&conv.UnreadCount,
		)
		if err != nil {
			continue
		}
		convs = append(convs, conv)
	}
	if convs == nil {
		convs = []models.Conversation{}
	}
	c.JSON(http.StatusOK, gin.H{"conversations": convs})
}

// GetMessages 获取指定会话的消息列表。
//
// 查询参数：
//   - since_id=N  增量拉取：只返回 id > N 的消息（用于进入聊天页后补拉新消息）
//   - limit=N     每页条数，默认 60，最大 200
//
// 无 since_id 时：取最新 limit 条（DESC 后在客户端按时间正序显示）
// 有 since_id 时：取 id > since_id 的所有消息（全量增量，上限 200）
func GetMessages(c *gin.Context) {
	userID := c.GetInt64("user_id")
	convIDStr := c.Param("id")
	convID, err := strconv.ParseInt(convIDStr, 10, 64)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid conversation id"})
		return
	}

	// 鉴权：必须是会话参与者
	var exists bool
	err = db.DB.QueryRow(context.Background(),
		`SELECT EXISTS(SELECT 1 FROM conversations
		 WHERE id = $1 AND (user_a_id = $2 OR user_b_id = $2))`,
		convID, userID,
	).Scan(&exists)
	if err != nil || !exists {
		c.JSON(http.StatusForbidden, gin.H{"error": "no permission"})
		return
	}

	// 解析 since_id（增量模式）和 limit
	sinceIDStr := c.Query("since_id")
	sinceID, _ := strconv.ParseInt(sinceIDStr, 10, 64)

	limitStr := c.DefaultQuery("limit", "60")
	limit, _ := strconv.Atoi(limitStr)
	if limit <= 0 || limit > 200 {
		limit = 60
	}

	// 构造查询 SQL（两种模式）
	var query string
	var args []any
	if sinceID > 0 {
		// 增量模式：id > since_id，已按 ASC 顺序
		query = `
			SELECT id, conversation_id, sender_id, receiver_id,
			       content, msg_type, media_url, is_read, created_at
			FROM messages
			WHERE conversation_id = $1 AND id > $2
			ORDER BY id ASC
			LIMIT $3`
		args = []any{convID, sinceID, limit}
	} else {
		// 首次加载：取最新 N 条（子查询 DESC 取，外层 ASC 还原时间顺序）
		query = `
			SELECT id, conversation_id, sender_id, receiver_id,
			       content, msg_type, media_url, is_read, created_at
			FROM (
			    SELECT id, conversation_id, sender_id, receiver_id,
			           content, msg_type, media_url, is_read, created_at
			    FROM messages
			    WHERE conversation_id = $1
			    ORDER BY id DESC
			    LIMIT $2
			) sub
			ORDER BY id ASC`
		args = []any{convID, limit}
	}

	rows, err := db.DB.Query(context.Background(), query, args...)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query failed"})
		return
	}
	defer rows.Close()

	var msgs []models.Message
	for rows.Next() {
		var m models.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderID, &m.ReceiverID,
			&m.Content, &m.MsgType, &m.MediaURL, &m.IsRead, &m.CreatedAt); err != nil {
			continue
		}
		msgs = append(msgs, m)
	}

	// 标记已读
	db.DB.Exec(context.Background(),
		`UPDATE messages SET is_read = true
		 WHERE conversation_id = $1 AND receiver_id = $2 AND is_read = false`,
		convID, userID,
	)

	if msgs == nil {
		msgs = []models.Message{}
	}
	c.JSON(http.StatusOK, gin.H{"messages": msgs})
}
