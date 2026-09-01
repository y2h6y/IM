package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sync"
	"time"

	"qqq-gateway/crypto"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// ── WebSocket 消息协议 ──────────────────────────────────────────────

// IncomingMsg 是客户端发来的消息
type IncomingMsg struct {
	Type        string `json:"type"`         // "message" | "ping"
	To          int64  `json:"to"`           // 接收方 user_id
	Content     string `json:"content"`      // AES-GCM base64 密文
	MsgType     string `json:"msg_type"`     // "text" | "image"
	MediaURL    string `json:"media_url"`
	ClientMsgID string `json:"client_msg_id"` // 客户端去重 id
}

// OutgoingMsg 是服务端下发的消息
type OutgoingMsg struct {
	Type           string    `json:"type"`            // "message" | "ack" | "error"
	ID             int64     `json:"id,omitempty"`
	From           int64     `json:"from,omitempty"`
	FromNickname   string    `json:"from_nickname,omitempty"`
	Content        string    `json:"content,omitempty"`
	MsgType        string    `json:"msg_type,omitempty"`
	MediaURL       string    `json:"media_url,omitempty"`
	ConversationID int64     `json:"conversation_id,omitempty"`
	CreatedAt      time.Time `json:"created_at,omitempty"`
	ClientMsgID    string    `json:"client_msg_id,omitempty"`
	MessageID      int64     `json:"message_id,omitempty"`
	ErrMsg         string    `json:"error,omitempty"`
}

// ── Hub ──────────────────────────────────────────────────────────────

type Hub struct {
	mu         sync.RWMutex
	clients    map[int64]*Client // userID → Client
	register   chan *Client
	unregister chan *Client
	inbound    chan *clientMsg
	db         *pgxpool.Pool
	rdb        *redis.Client
}

type clientMsg struct {
	client *Client
	data   []byte
}

func newHub(db *pgxpool.Pool, rdb *redis.Client) *Hub {
	return &Hub{
		clients:    make(map[int64]*Client),
		register:   make(chan *Client, 16),
		unregister: make(chan *Client, 16),
		inbound:    make(chan *clientMsg, 256),
		db:         db,
		rdb:        rdb,
	}
}

func (h *Hub) run() {
	for {
		select {
		case c := <-h.register:
			h.mu.Lock()
			var zombieClient *Client
			if existing, ok := h.clients[c.userID]; ok && existing != c {
				// ── 同账号二次登录：把旧连接标记为僵尸，踢出 ──
				zombieClient = existing
			}
			h.clients[c.userID] = c
			h.mu.Unlock()

			if zombieClient != nil {
				log.Printf("[Hub] User %d: kicking zombie session (duplicate login)", c.userID)
				kicked, _ := json.Marshal(OutgoingMsg{
					Type:   "kicked",
					ErrMsg: "您的账号在另一台设备登录，当前设备已自动下线",
				})
				// 非阻塞写入踢出通知
				select {
				case zombieClient.send <- kicked:
				default:
				}
				// 300ms 后关闭旧连接并终止 writePump
				go func(old *Client) {
					time.Sleep(300 * time.Millisecond)
					old.conn.Close()    // 终止 readPump / writePump 的 IO
					old.closeSend()     // 通知 writePump 通道已关，立即退出
				}(zombieClient)
			}

			log.Printf("[Hub] User %d (%s) connected", c.userID, c.nickname)
			h.drainOffline(c)

		case c := <-h.unregister:
			h.mu.Lock()
			isCurrent := h.clients[c.userID] == c
			if isCurrent {
				delete(h.clients, c.userID)
			}
			h.mu.Unlock()
			// 无论是否是当前活跃连接，都安全关闭 send（closeSend 内部用 Once 保证幂等）
			c.closeSend()
			log.Printf("[Hub] User %d disconnected (wasCurrent=%v)", c.userID, isCurrent)

		case cm := <-h.inbound:
			h.handleInbound(cm)
		}
	}
}

func (h *Hub) handleInbound(cm *clientMsg) {
	var msg IncomingMsg
	if err := json.Unmarshal(cm.data, &msg); err != nil {
		h.sendError(cm.client, "invalid json")
		return
	}

	if msg.Type == "ping" {
		data, _ := json.Marshal(OutgoingMsg{Type: "pong"})
		select {
		case cm.client.send <- data:
		default:
		}
		return
	}

	if msg.Type != "message" {
		return
	}

	// E2EE 模式下服务端无法解密，仅存通用预览
	// msg_type="e2e"：新端到端加密消息，预览固定为"[消息]"
	// msg_type="image"：图片（兼容旧格式）
	// 其他：旧版服务端共享密钥格式，尝试解密取预览（向下兼容）
	plainPreview := "[消息]"
	switch msg.MsgType {
	case "e2e":
		plainPreview = "[消息]"   // 服务端不持有私钥，无法解密
	case "image":
		plainPreview = "[图片]"
	default:
		// 旧格式兼容：尝试用共享密钥解密
		if plain, err := crypto.Decrypt(msg.Content); err == nil {
			if len(plain) > 40 {
				plainPreview = plain[:40] + "…"
			} else {
				plainPreview = plain
			}
		}
	}

	// 获取或创建会话
	convID, err := h.getOrCreateConversation(cm.client.userID, msg.To, plainPreview)
	if err != nil {
		log.Printf("[Hub] getOrCreateConversation error: %v", err)
		h.sendError(cm.client, "server error")
		return
	}

	// 获取接收方昵称（可选，仅记录日志）
	var senderNickname string
	h.db.QueryRow(context.Background(),
		`SELECT nickname FROM users WHERE id = $1`, cm.client.userID,
	).Scan(&senderNickname)

	// ── 幂等插入：ON CONFLICT (client_msg_id) DO NOTHING ───────────────
	// 超时重传 / 断线重连重发时，同一 client_msg_id 不会重复入库。
	// ON CONFLICT DO NOTHING 时 RETURNING 返回 0 行 → pgx.ErrNoRows
	// → 说明是重复消息，查出已存的行发 ack 即可，不再转发给接收方。
	var msgID int64
	var createdAt time.Time
	insertErr := h.db.QueryRow(context.Background(), `
		INSERT INTO messages
		  (conversation_id, sender_id, receiver_id, content, msg_type, media_url, client_msg_id)
		VALUES ($1, $2, $3, $4, $5, $6, NULLIF($7,''))
		ON CONFLICT (client_msg_id) WHERE client_msg_id IS NOT NULL DO NOTHING
		RETURNING id, created_at`,
		convID, cm.client.userID, msg.To,
		msg.Content, msg.MsgType, msg.MediaURL, msg.ClientMsgID,
	).Scan(&msgID, &createdAt)

	if insertErr != nil {
		// 判断是否是"冲突无返回"（重复消息）
		if isDuplicate(insertErr) {
			// 已存在：只发 ack，不再转发
			log.Printf("[Hub] Duplicate client_msg_id=%s, ack only", msg.ClientMsgID)
			h.db.QueryRow(context.Background(),
				`SELECT id, created_at FROM messages WHERE client_msg_id = $1`,
				msg.ClientMsgID,
			).Scan(&msgID, &createdAt)
			ack, _ := json.Marshal(OutgoingMsg{
				Type: "ack", MessageID: msgID,
				ConversationID: convID, ClientMsgID: msg.ClientMsgID,
				CreatedAt: createdAt,
			})
			select {
			case cm.client.send <- ack:
			default:
			}
			return
		}
		log.Printf("[Hub] insert message error: %v", insertErr)
		h.sendError(cm.client, "failed to save message")
		return
	}

	// 构造下发消息
	out := OutgoingMsg{
		Type:           "message",
		ID:             msgID,
		From:           cm.client.userID,
		FromNickname:   senderNickname,
		Content:        msg.Content, // 下发原始密文，客户端负责解密
		MsgType:        msg.MsgType,
		MediaURL:       msg.MediaURL,
		ConversationID: convID,
		CreatedAt:      createdAt,
		ClientMsgID:    msg.ClientMsgID,
	}
	outData, _ := json.Marshal(out)

	// ack 给发送方
	ack, _ := json.Marshal(OutgoingMsg{
		Type:           "ack",
		MessageID:      msgID,
		ConversationID: convID,
		ClientMsgID:    msg.ClientMsgID,
		CreatedAt:      createdAt,
	})
	select {
	case cm.client.send <- ack:
	default:
	}

	// 转发给接收方
	h.mu.RLock()
	recipient, online := h.clients[msg.To]
	h.mu.RUnlock()

	if online {
		select {
		case recipient.send <- outData:
		default:
			log.Printf("[Hub] Recipient %d send buffer full, pushing to offline queue", msg.To)
			h.pushOffline(msg.To, outData)
		}
	} else {
		// 离线存储，等对方上线补拉
		h.pushOffline(msg.To, outData)
	}
}

// getOrCreateConversation 获取或新建 C2C 会话（user_a < user_b）
func (h *Hub) getOrCreateConversation(userA, userB int64, lastMsg string) (int64, error) {
	a, b := userA, userB
	if a > b {
		a, b = b, a
	}
	var convID int64
	err := h.db.QueryRow(context.Background(), `
		INSERT INTO conversations (user_a_id, user_b_id, last_message, last_message_at)
		VALUES ($1, $2, $3, NOW())
		ON CONFLICT (user_a_id, user_b_id) DO UPDATE
		  SET last_message = EXCLUDED.last_message,
		      last_message_at = NOW()
		RETURNING id`,
		a, b, lastMsg,
	).Scan(&convID)
	return convID, err
}

func (h *Hub) pushOffline(userID int64, data []byte) {
	key := fmt.Sprintf("offline:%d", userID)
	ctx := context.Background()
	h.rdb.RPush(ctx, key, data)
	h.rdb.Expire(ctx, key, 7*24*time.Hour)
}

func (h *Hub) drainOffline(c *Client) {
	key := fmt.Sprintf("offline:%d", c.userID)
	ctx := context.Background()
	msgs, err := h.rdb.LRange(ctx, key, 0, -1).Result()
	if err != nil || len(msgs) == 0 {
		return
	}
	h.rdb.Del(ctx, key)
	log.Printf("[Hub] Delivering %d offline messages to user %d", len(msgs), c.userID)
	for _, m := range msgs {
		select {
		case c.send <- []byte(m):
		default:
		}
	}
}

func (h *Hub) sendError(c *Client, msg string) {
	data, _ := json.Marshal(OutgoingMsg{Type: "error", ErrMsg: msg})
	select {
	case c.send <- data:
	default:
	}
}

// isDuplicate 判断是否是 ON CONFLICT DO NOTHING 后的"无行返回"错误
// pgx 在没有行返回时返回 pgx.ErrNoRows
func isDuplicate(err error) bool {
	if err == nil {
		return false
	}
	return err.Error() == "no rows in result set"
}
