package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/time/rate"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = 50 * time.Second
	maxMessageSize = 1 << 20 // 1 MB

	// 每连接消息频率上限：每秒 5 条，突发 10 条
	// 超出后返回 error 帧，不断连接
	msgRateLimit rate.Limit = 5
	msgBurst                = 10
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// Client 代表一个已连接的 WebSocket 用户
type Client struct {
	hub        *Hub
	conn       *websocket.Conn
	send       chan []byte
	userID     int64
	nickname   string
	msgLimiter *rate.Limiter // 每连接独立令牌桶
	closeOnce  sync.Once
}

func (c *Client) closeSend() {
	c.closeOnce.Do(func() { close(c.send) })
}

// readPump 持续读取客户端消息，超限时返回错误帧而非断连
func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway, websocket.CloseAbnormalClosure, websocket.CloseNormalClosure) {
				log.Printf("[Client] Read error user %d: %v", c.userID, err)
			}
			break
		}

		// ── 消息频率限制 ────────────────────────────────────────────
		if !c.msgLimiter.Allow() {
			log.Printf("[Client] User %d: message rate limit exceeded", c.userID)
			errMsg, _ := json.Marshal(OutgoingMsg{
				Type:   "error",
				ErrMsg: "发送频率过高，请稍后再试",
			})
			select {
			case c.send <- errMsg:
			default:
			}
			continue // 丢弃本条消息，继续读取（不断连接）
		}

		c.hub.inbound <- &clientMsg{client: c, data: data}
	}
}

// writePump 写消息到客户端，并定期发 WebSocket 层 ping
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)
			n := len(c.send)
			for range n {
				w.Write([]byte{'\n'})
				w.Write(<-c.send)
			}
			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}
