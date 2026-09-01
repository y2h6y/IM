package config

import "os"

type Config struct {
	DatabaseURL     string
	RedisURL        string
	// Gateway 只需要 Access Secret（WebSocket 握手鉴权用 Access Token）
	JWTAccessSecret string
	AESKey          string
	GatewayPort     string
}

var Cfg *Config

func Load() *Config {
	Cfg = &Config{
		DatabaseURL:     getenv("DATABASE_URL", "postgres://qqq:qqq123@localhost:5432/qqq?sslmode=disable"),
		RedisURL:        getenv("REDIS_URL", "redis://localhost:6379"),
		JWTAccessSecret: getenv("JWT_ACCESS_SECRET", "qqq-access-xK9mP2nQ7rL4sT8vY1bC6dF0eJ3wH5i"),
		AESKey:          getenv("AES_KEY", "QQQSecretKey2026QQQSecretKey2026"),
		GatewayPort:     getenv("GATEWAY_PORT", "8081"),
	}
	return Cfg
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
