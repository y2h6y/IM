package handlers

import (
	"context"
	"net/http"

	"qqq-app/db"
	"qqq-app/models"

	"github.com/gin-gonic/gin"
)

// ListUsers 返回除自己以外的所有用户，用于联系人列表
func ListUsers(c *gin.Context) {
	userID := c.GetInt64("user_id")

	rows, err := db.DB.Query(context.Background(),
		`SELECT id, username, nickname, avatar_url, created_at
		 FROM users WHERE id != $1 ORDER BY nickname`,
		userID,
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query failed"})
		return
	}
	defer rows.Close()

	var users []models.User
	for rows.Next() {
		var u models.User
		if err := rows.Scan(&u.ID, &u.Username, &u.Nickname, &u.AvatarURL, &u.CreatedAt); err != nil {
			continue
		}
		users = append(users, u)
	}
	c.JSON(http.StatusOK, gin.H{"users": users})
}
