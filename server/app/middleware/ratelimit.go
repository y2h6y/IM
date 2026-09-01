package middleware

import (
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"golang.org/x/time/rate"
)

// ── 通用 IP 限流器存储 ─────────────────────────────────────────────────

type entry struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

type store struct {
	mu      sync.Mutex
	entries map[string]*entry
	r       rate.Limit
	burst   int
}

func newStore(r rate.Limit, burst int) *store {
	s := &store{
		entries: make(map[string]*entry),
		r:       r,
		burst:   burst,
	}
	go s.cleanup()
	return s
}

// get 取出（或新建）IP 对应的令牌桶
func (s *store) get(ip string) *rate.Limiter {
	s.mu.Lock()
	defer s.mu.Unlock()
	e, ok := s.entries[ip]
	if !ok {
		e = &entry{limiter: rate.NewLimiter(s.r, s.burst)}
		s.entries[ip] = e
	}
	e.lastSeen = time.Now()
	return e.limiter
}

// cleanup 每 5 分钟清理超过 10 分钟未活跃的条目，防止内存泄漏
func (s *store) cleanup() {
	for range time.Tick(5 * time.Minute) {
		s.mu.Lock()
		for ip, e := range s.entries {
			if time.Since(e.lastSeen) > 10*time.Minute {
				delete(s.entries, ip)
			}
		}
		s.mu.Unlock()
	}
}

// ── 预建三档限流器 ────────────────────────────────────────────────────

var (
	// 全局 IP 限流：60次/分钟（1次/秒），突发 20次
	globalStore = newStore(rate.Every(time.Second), 20)

	// 登录严格限流：每 IP 每分钟最多 5 次，突发 3 次
	// 防止密码暴力破解
	loginStore = newStore(rate.Every(12*time.Second), 3)

	// 上传限流：每 IP 每分钟最多 10 次，突发 5 次
	// 防止图片轰炸
	uploadStore = newStore(rate.Every(6*time.Second), 5)
)

// ── 中间件函数 ────────────────────────────────────────────────────────

// IPRateLimit 全局限流——所有请求共用，防止 DDoS / 爬虫
func IPRateLimit() gin.HandlerFunc {
	return rateLimitMiddleware(globalStore, "Too many requests, please slow down")
}

// LoginRateLimit 登录接口严格限流——防暴力破解
func LoginRateLimit() gin.HandlerFunc {
	return rateLimitMiddleware(loginStore, "Too many login attempts, please try again later")
}

// UploadRateLimit 上传接口限流——防图片轰炸
func UploadRateLimit() gin.HandlerFunc {
	return rateLimitMiddleware(uploadStore, "Upload rate limit exceeded")
}

func rateLimitMiddleware(s *store, msg string) gin.HandlerFunc {
	return func(c *gin.Context) {
		ip := c.ClientIP()
		if !s.get(ip).Allow() {
			c.Header("Retry-After", "60")
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"error": msg,
				"code":  429,
			})
			return
		}
		c.Next()
	}
}
