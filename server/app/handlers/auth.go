package handlers

import (
	"context"
	"net/http"
	"time"

	"qqq-app/crypto"
	"qqq-app/db"
	"qqq-app/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

var (
	jwtAccessSecret  string
	jwtRefreshSecret string
	passwordPepper   string
)

func SetJWTAccessSecret(s string)  { jwtAccessSecret = s }
func SetJWTRefreshSecret(s string) { jwtRefreshSecret = s }
func SetPasswordPepper(p string)   { passwordPepper = p }

// ── Token Pair ────────────────────────────────────────────────────────

type tokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

// issueTokenPair 签发一对 Token：
//   - Access Token：2h，用 ACCESS_SECRET 签名，token_type=access
//   - Refresh Token：30d，用 REFRESH_SECRET 签名，token_type=refresh
//
// 两种 Token 使用不同 Secret + token_type claim，防止类型混淆攻击：
// Access Token 无法当 Refresh Token 用，反之亦然。
func issueTokenPair(userID int64, username string) (tokenPair, error) {
	now := time.Now()

	access := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"user_id":    userID,
		"username":   username,
		"token_type": "access",
		"exp":        now.Add(2 * time.Hour).Unix(),
	})
	accessStr, err := access.SignedString([]byte(jwtAccessSecret))
	if err != nil {
		return tokenPair{}, err
	}

	refresh := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"user_id":    userID,
		"username":   username,
		"token_type": "refresh",
		"exp":        now.Add(30 * 24 * time.Hour).Unix(),
	})
	refreshStr, err := refresh.SignedString([]byte(jwtRefreshSecret))
	if err != nil {
		return tokenPair{}, err
	}

	return tokenPair{AccessToken: accessStr, RefreshToken: refreshStr}, nil
}

// ── Login ─────────────────────────────────────────────────────────────

func Login(c *gin.Context) {
	var req models.LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	var user models.User
	var pwdHash string
	err := db.DB.QueryRow(context.Background(),
		`SELECT id, username, nickname, avatar_url, created_at, password_hash
		 FROM users WHERE username = $1`,
		req.Username,
	).Scan(&user.ID, &user.Username, &user.Nickname, &user.AvatarURL, &user.CreatedAt, &pwdHash)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "user not found"})
		return
	}

	peppered := crypto.PepperPassword(req.Password, passwordPepper)
	if err := bcrypt.CompareHashAndPassword([]byte(pwdHash), []byte(peppered)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "wrong password"})
		return
	}

	pair, err := issueTokenPair(user.ID, user.Username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "token issue failed"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"access_token":  pair.AccessToken,
		"refresh_token": pair.RefreshToken,
		"user":          user,
	})
}

// ── Refresh ───────────────────────────────────────────────────────────

// Refresh 用 Refresh Token 换新的 Token Pair（token rotation）。
// 每次 refresh 都签发全新的 access + refresh，旧 refresh token 自然失效（iOS Keychain 覆盖）。
func Refresh(c *gin.Context) {
	var req struct {
		RefreshToken string `json:"refresh_token" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "missing refresh_token"})
		return
	}

	// 用 REFRESH_SECRET 校验，防止拿 Access Token 来换
	token, err := jwt.Parse(req.RefreshToken, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return []byte(jwtRefreshSecret), nil
	})
	if err != nil || !token.Valid {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired refresh token"})
		return
	}

	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok || claims["token_type"] != "refresh" {
		// token_type 不是 refresh：类型混淆攻击拦截
		c.JSON(http.StatusUnauthorized, gin.H{"error": "token type mismatch"})
		return
	}

	userID := int64(claims["user_id"].(float64))
	username := claims["username"].(string)

	pair, err := issueTokenPair(userID, username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "token issue failed"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"access_token":  pair.AccessToken,
		"refresh_token": pair.RefreshToken,
	})
}

// ── GetMe ─────────────────────────────────────────────────────────────

func GetMe(c *gin.Context) {
	userID := c.GetInt64("user_id")
	var user models.User
	err := db.DB.QueryRow(context.Background(),
		`SELECT id, username, nickname, avatar_url, created_at FROM users WHERE id = $1`,
		userID,
	).Scan(&user.ID, &user.Username, &user.Nickname, &user.AvatarURL, &user.CreatedAt)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	c.JSON(http.StatusOK, user)
}
