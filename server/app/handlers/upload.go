package handlers

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"path/filepath"

	"qqq-app/db"

	"github.com/gin-gonic/gin"
	"github.com/minio/minio-go/v7"
)

// UploadImage POST /api/upload
// 内容寻址存储（SHA256 作 MinIO object name）：
//   - 相同内容秒返回已有 URL，不重复存储（服务端秒传）
//   - 缩略图与原图通过 {hash}_t.jpg 命名区分
func UploadImage(c *gin.Context) {
	file, header, err := c.Request.FormFile("image")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "missing image field"})
		return
	}
	defer file.Close()

	// 读取全部字节（图片通常 < 10MB，内存可接受）
	fileBytes, err := io.ReadAll(file)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to read file"})
		return
	}

	ext := filepath.Ext(header.Filename)
	if ext == "" {
		ext = ".jpg"
	}

	// SHA256 内容寻址：相同图片 → 相同 hash → 相同 URL
	sum := sha256.Sum256(fileBytes)
	hash := hex.EncodeToString(sum[:])
	objectName := hash + ext

	contentType := header.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "image/jpeg"
	}

	url := fmt.Sprintf("http://localhost:9000/%s/%s", db.MinioBucket, objectName)

	// ── 秒传检查：对象已存在则直接返回 ──────────────────────────────
	_, statErr := db.Minio.StatObject(
		context.Background(), db.MinioBucket, objectName,
		minio.StatObjectOptions{},
	)
	if statErr == nil {
		// 已存在，内容完全一致，直接返回
		c.JSON(http.StatusOK, gin.H{"url": url, "hash": hash})
		return
	}

	// ── 新对象：上传到 MinIO ────────────────────────────────────────
	_, err = db.Minio.PutObject(
		context.Background(),
		db.MinioBucket,
		objectName,
		bytes.NewReader(fileBytes),
		int64(len(fileBytes)),
		minio.PutObjectOptions{ContentType: contentType},
	)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "upload failed: " + err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": url, "hash": hash})
}

// CheckFile GET /api/files/:hash
// 跨设备秒传检查：客户端先查，存在则直接用 URL，不再上传
func CheckFile(c *gin.Context) {
	hash := c.Param("hash")

	// 检查原图
	originalName := hash + ".jpg"
	_, err := db.Minio.StatObject(
		context.Background(), db.MinioBucket, originalName,
		minio.StatObjectOptions{},
	)
	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "file not found"})
		return
	}

	originalURL := fmt.Sprintf("http://localhost:9000/%s/%s", db.MinioBucket, originalName)

	// 检查缩略图（可能不存在）
	thumbURL := ""
	thumbName := hash + "_t.jpg"
	_, thumbErr := db.Minio.StatObject(
		context.Background(), db.MinioBucket, thumbName,
		minio.StatObjectOptions{},
	)
	if thumbErr == nil {
		thumbURL = fmt.Sprintf("http://localhost:9000/%s/%s", db.MinioBucket, thumbName)
	}

	c.JSON(http.StatusOK, gin.H{"url": originalURL, "thumb_url": thumbURL})
}
