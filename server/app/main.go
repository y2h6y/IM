package main

import (
	"log"

	"qqq-app/config"
	"qqq-app/crypto"
	"qqq-app/db"
	"qqq-app/handlers"
	"qqq-app/middleware"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
)

func main() {
	_ = godotenv.Load("../.env")

	cfg := config.Load()
	crypto.Init(cfg.AESKey)
	handlers.SetJWTAccessSecret(cfg.JWTAccessSecret)
	handlers.SetJWTRefreshSecret(cfg.JWTRefreshSecret)
	handlers.SetPasswordPepper(cfg.PasswordPepper)

	db.InitPostgres(cfg.DatabaseURL)
	db.InitRedis(cfg.RedisURL)
	db.InitMinIO(cfg.MinioEndpoint, cfg.MinioAccessKey, cfg.MinioSecretKey, cfg.MinioBucket)
	db.EnsureMessageDedup()
	db.EnsureE2ETables()
	db.SeedUsers(cfg.PasswordPepper)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	// ── 全局 CORS ──────────────────────────────────────────────────────
	r.Use(func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization,Content-Type")
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	})

	// ── 全局 IP 限流（60次/分钟）——防 DDoS / 爬虫 ────────────────────
	r.Use(middleware.IPRateLimit())

	api := r.Group("/api")
	{
		api.GET("/health", func(c *gin.Context) { c.JSON(200, gin.H{"status": "ok"}) })

		// 登录：严格限流（5次/分钟）——防暴力破解
		api.POST("/login", middleware.LoginRateLimit(), handlers.Login)
		api.POST("/refresh", handlers.Refresh)

		auth := api.Group("", middleware.JWTAuth(cfg.JWTAccessSecret))
		{
			auth.GET("/users/me", handlers.GetMe)
			auth.GET("/users", handlers.ListUsers)
			auth.PUT("/users/me/public-key", handlers.UploadPublicKey)
			auth.POST("/users/me/public-key", handlers.UploadPublicKey)
			auth.GET("/users/:id/public-key", handlers.GetPublicKey)
			auth.POST("/conversations", handlers.GetOrCreateConversation)
			auth.GET("/conversations", handlers.ListConversations)
			auth.GET("/conversations/:id/messages", handlers.GetMessages)
			// 上传：独立限流（10次/分钟）——防图片轰炸
			auth.POST("/upload", middleware.UploadRateLimit(), handlers.UploadImage)
			auth.GET("/files/:hash", handlers.CheckFile)
		}
	}

	log.Printf("✅ App Server running on HTTPS :%s", cfg.AppPort)
	certFile := "../certs/localhost+2.pem"
	keyFile  := "../certs/localhost+2-key.pem"
	if err := r.RunTLS(":"+cfg.AppPort, certFile, keyFile); err != nil {
		log.Fatal(err)
	}
}
