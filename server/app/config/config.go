package config

import "os"

type Config struct {
	DatabaseURL      string
	RedisURL         string
	// Access Token secret：签发 API + WebSocket 鉴权（2h）
	JWTAccessSecret  string
	// Refresh Token secret：仅换新 token pair 时使用（30d），与 Access 独立
	JWTRefreshSecret string
	AESKey           string
	PasswordPepper   string
	MinioEndpoint    string
	MinioAccessKey   string
	MinioSecretKey   string
	MinioBucket      string
	AppPort          string
}

var Cfg *Config

func Load() *Config {
	Cfg = &Config{
		DatabaseURL:      getenv("DATABASE_URL", "postgres://qqq:qqq123@localhost:5432/qqq?sslmode=disable"),
		RedisURL:         getenv("REDIS_URL", "redis://localhost:6379"),
		JWTAccessSecret:  getenv("JWT_ACCESS_SECRET", "qqq-access-xK9mP2nQ7rL4sT8vY1bC6dF0eJ3wH5i"),
		JWTRefreshSecret: getenv("JWT_REFRESH_SECRET", "qqq-refresh-yH3cB6fN1wD5eJ0uA8kR4sM7pT2vX9qZ"),
		AESKey:           getenv("AES_KEY", "QQQSecretKey2026QQQSecretKey2026"),
		PasswordPepper:   getenv("PASSWORD_PEPPER", "3f7a2c8d1e5b9f4a6c3d8e2f7b1a5c9d4f8e3a2b7c1d6e5f0a9b3c7d2e1f4a6b"),
		MinioEndpoint:    getenv("MINIO_ENDPOINT", "localhost:9000"),
		MinioAccessKey:   getenv("MINIO_ACCESS_KEY", "minioadmin"),
		MinioSecretKey:   getenv("MINIO_SECRET_KEY", "minioadmin123"),
		MinioBucket:      getenv("MINIO_BUCKET", "qqq-images"),
		AppPort:          getenv("APP_PORT", "8080"),
	}
	return Cfg
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
