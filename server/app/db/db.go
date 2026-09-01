package db

import (
	"context"
	"fmt"
	"log"
	"time"

	"qqq-app/crypto"
	"qqq-app/models"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/bcrypt"
)

var (
	DB          *pgxpool.Pool
	Redis       *redis.Client
	Minio       *minio.Client
	MinioBucket string
)

func InitPostgres(url string) {
	var err error
	for i := range 12 {
		DB, err = pgxpool.New(context.Background(), url)
		if err == nil {
			if err = DB.Ping(context.Background()); err == nil {
				log.Println("[DB] Connected to PostgreSQL")
				return
			}
		}
		log.Printf("[DB] Waiting for PostgreSQL... (%d/12): %v", i+1, err)
		time.Sleep(3 * time.Second)
	}
	log.Fatalf("[DB] Failed to connect to PostgreSQL: %v", err)
}

func InitRedis(url string) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		log.Fatalf("[Redis] Parse URL error: %v", err)
	}
	Redis = redis.NewClient(opt)
	for i := range 10 {
		if err = Redis.Ping(context.Background()).Err(); err == nil {
			log.Println("[Redis] Connected")
			return
		}
		log.Printf("[Redis] Waiting... (%d/10)", i+1)
		time.Sleep(2 * time.Second)
	}
	log.Fatalf("[Redis] Failed to connect: %v", err)
}

func InitMinIO(endpoint, accessKey, secretKey, bucket string) {
	MinioBucket = bucket
	var err error
	Minio, err = minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: false,
	})
	if err != nil {
		log.Fatalf("[MinIO] Init error: %v", err)
	}
	ctx := context.Background()
	exists, err := Minio.BucketExists(ctx, bucket)
	if err != nil {
		log.Printf("[MinIO] Check bucket error: %v", err)
		return
	}
	if !exists {
		if err = Minio.MakeBucket(ctx, bucket, minio.MakeBucketOptions{}); err != nil {
			log.Printf("[MinIO] Create bucket error: %v", err)
			return
		}
		// 设置公开读策略
		policy := fmt.Sprintf(
			`{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::%s/*"}]}`,
			bucket,
		)
		if err = Minio.SetBucketPolicy(ctx, bucket, policy); err != nil {
			log.Printf("[MinIO] Set policy error: %v", err)
		}
	}
	log.Printf("[MinIO] Ready, bucket: %s", bucket)
}

// EnsureMessageDedup 给 messages 表加 client_msg_id 列和部分唯一索引。
// 部分索引（WHERE client_msg_id IS NOT NULL）允许旧消息的 NULL，
// 同时保证新消息的 client_msg_id 全局唯一，防止超时重传导致重复入库。
func EnsureMessageDedup() {
	sqls := []string{
		// 加列（幂等：PostgreSQL 14+ 支持 IF NOT EXISTS）
		`ALTER TABLE messages ADD COLUMN IF NOT EXISTS client_msg_id VARCHAR(64)`,
		// 部分唯一索引：只约束非 NULL 值，不影响旧数据
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_client_msg_id
		 ON messages (client_msg_id)
		 WHERE client_msg_id IS NOT NULL`,
	}
	for _, s := range sqls {
		if _, err := DB.Exec(context.Background(), s); err != nil {
			log.Printf("[DB] EnsureMessageDedup step error: %v", err)
		}
	}
	log.Println("[DB] Message dedup index ready")
}

// EnsureE2ETables 确保 E2EE 相关表存在（幂等）
func EnsureE2ETables() {
	_, err := DB.Exec(context.Background(), `
		CREATE TABLE IF NOT EXISTS user_public_keys (
			user_id    BIGINT      REFERENCES users(id) PRIMARY KEY,
			public_key TEXT        NOT NULL,
			updated_at TIMESTAMPTZ DEFAULT NOW()
		)`)
	if err != nil {
		log.Printf("[DB] EnsureE2ETables error: %v", err)
	} else {
		log.Println("[DB] E2E tables ready")
	}
}

// SeedUsers 初始化预设用户。
// 采用 bcrypt(SHA256(pepper ‖ password)) 存储，pepper 不入库。
// 使用 ON CONFLICT DO UPDATE，保证 pepper 变更后重启即自动刷新哈希。
func SeedUsers(pepper string) {
	seedList := []models.SeedUser{
		{Username: "yehangyuan", Nickname: "叶航远", Password: "123456"},
		{Username: "yuhaohe", Nickname: "俞昊赫", Password: "123456"},
		{Username: "alice", Nickname: "Alice", Password: "123456"},
		{Username: "bob", Nickname: "Bob", Password: "123456"},
		{Username: "charlie", Nickname: "Charlie", Password: "123456"},
	}
	for _, u := range seedList {
		// 1. SHA256(pepper ‖ password) → hex（固定 64 字符，符合 bcrypt 输入限制）
		peppered := crypto.PepperPassword(u.Password, pepper)
		// 2. bcrypt（每次启动都重新 hash，成本高但只有 5 个种子用户，可以接受）
		hash, err := bcrypt.GenerateFromPassword([]byte(peppered), bcrypt.DefaultCost)
		if err != nil {
			log.Printf("[Seed] bcrypt error for %s: %v", u.Username, err)
			continue
		}
		_, err = DB.Exec(context.Background(),
			`INSERT INTO users (username, nickname, password_hash)
			 VALUES ($1, $2, $3)
			 ON CONFLICT (username) DO UPDATE
			   SET password_hash = EXCLUDED.password_hash`,
			u.Username, u.Nickname, string(hash),
		)
		if err != nil {
			log.Printf("[Seed] Upsert user %s error: %v", u.Username, err)
		} else {
			log.Printf("[Seed] User ready: %s (%s)", u.Username, u.Nickname)
		}
	}
}
