package main

import (
	"context"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"qqq-gateway/config"
	"qqq-gateway/crypto"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
	"golang.org/x/time/rate"
)

var (
	pool *pgxpool.Pool
	rdb  *redis.Client
)

// ── WS 新连接 IP 频率控制（防连接洪泛）─────────────────────────────────
// 每个 IP 每分钟最多建 10 个新连接，突发上限 10
var (
	connLimitMu  sync.Mutex
	connLimiters = make(map[string]*rate.Limiter)
)

func getConnLimiter(ip string) *rate.Limiter {
	connLimitMu.Lock()
	defer connLimitMu.Unlock()
	if l, ok := connLimiters[ip]; ok {
		return l
	}
	l := rate.NewLimiter(rate.Every(6*time.Second), 10)
	connLimiters[ip] = l
	return l
}

func initPostgres(url string) {
	var err error
	for i := range 12 {
		pool, err = pgxpool.New(context.Background(), url)
		if err == nil {
			if err = pool.Ping(context.Background()); err == nil {
				log.Println("[Gateway] PostgreSQL connected")
				return
			}
		}
		log.Printf("[Gateway] Waiting for PostgreSQL... (%d/12)", i+1)
		time.Sleep(3 * time.Second)
	}
	log.Fatalf("[Gateway] PostgreSQL connection failed: %v", err)
}

func initRedis(url string) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		log.Fatalf("[Gateway] Redis URL parse error: %v", err)
	}
	rdb = redis.NewClient(opt)
	for i := range 10 {
		if err = rdb.Ping(context.Background()).Err(); err == nil {
			log.Println("[Gateway] Redis connected")
			return
		}
		log.Printf("[Gateway] Waiting for Redis... (%d/10)", i+1)
		time.Sleep(2 * time.Second)
	}
	log.Fatalf("[Gateway] Redis connection failed: %v", err)
}

func parseToken(tokenStr string) (int64, string, error) {
	token, err := jwt.Parse(tokenStr, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return []byte(config.Cfg.JWTAccessSecret), nil
	})
	if err != nil || !token.Valid {
		return 0, "", jwt.ErrSignatureInvalid
	}
	claims := token.Claims.(jwt.MapClaims)
	if tokenType, _ := claims["token_type"].(string); tokenType != "access" {
		return 0, "", jwt.ErrSignatureInvalid
	}
	userID := int64(claims["user_id"].(float64))
	username := claims["username"].(string)
	return userID, username, nil
}

func serveWS(hub *Hub, w http.ResponseWriter, r *http.Request) {
	// ── 新连接 IP 频率检查 ─────────────────────────────────────────────
	ip := r.RemoteAddr
	if fwd := r.Header.Get("X-Forwarded-For"); fwd != "" {
		ip = fwd
	}
	if !getConnLimiter(ip).Allow() {
		log.Printf("[Gateway] WS connect rate limit: %s", ip)
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}

	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		http.Error(w, "missing token", http.StatusUnauthorized)
		return
	}
	userID, username, err := parseToken(tokenStr)
	if err != nil {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}

	var nickname string
	pool.QueryRow(context.Background(),
		`SELECT nickname FROM users WHERE id = $1`, userID,
	).Scan(&nickname)
	if nickname == "" {
		nickname = username
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[Gateway] Upgrade error: %v", err)
		return
	}

	client := &Client{
		hub:        hub,
		conn:       conn,
		send:       make(chan []byte, 256),
		userID:     userID,
		nickname:   nickname,
		msgLimiter: rate.NewLimiter(msgRateLimit, msgBurst),
	}
	hub.register <- client

	go client.writePump()
	go client.readPump()
}

func main() {
	_ = godotenv.Load("../.env")
	cfg := config.Load()
	crypto.Init(cfg.AESKey)

	initPostgres(cfg.DatabaseURL)
	initRedis(cfg.RedisURL)

	hub := newHub(pool, rdb)
	go hub.run()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		serveWS(hub, w, r)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok","connections":` + strconv.Itoa(len(hub.clients)) + `}`))
	})

	log.Printf("✅ Gateway running on WSS :%s", cfg.GatewayPort)
	certFile := "../certs/localhost+2.pem"
	keyFile  := "../certs/localhost+2-key.pem"
	if err := http.ListenAndServeTLS(":"+cfg.GatewayPort, certFile, keyFile, mux); err != nil {
		log.Fatal(err)
	}
}
