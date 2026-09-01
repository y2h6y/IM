# QQQ — C2C 即时通讯 App

> 面向 iOS 平台的端到端加密即时通讯应用，支持文字/图片消息、离线同步、全文历史检索。

---

## 技术栈

### iOS 客户端

| 模块 | 技术 |
|------|------|
| UI 框架 | Swift + SwiftUI（声明式，iOS 26.5+）|
| 状态管理 | MVVM：`AppState`（全局）+ `ChatViewModel`（会话级）|
| 网络 | `URLSession`（HTTP REST）+ `URLSessionWebSocketTask`（WSS 实时）|
| 本地数据库 | SQLite via **GRDB 6.29.3**（Swift Package Manager）|
| 全文检索 | SQLite **FTS5** 虚表 + 触发器自动维护 |
| 本地加密 | iOS **Data Protection**（`NSFileProtectionCompleteUnlessOpen`，AES-256 Secure Enclave）|
| E2EE 加密 | Apple **CryptoKit**（X25519 / HKDF-SHA256 / AES-256-GCM）|
| 安全存储 | iOS **Keychain**（JWT Token、E2EE 私钥，`kSecAttrAccessibleAfterFirstUnlock`）|
| 图片选择 | `PhotosUI.PhotosPicker` |

### 后端（Go）

| 模块 | 技术 |
|------|------|
| App Server | Go 标准库 `net/http` + **Gin** 路由，`:8080` |
| Gateway | Go 标准库 `net/http` + **gorilla/websocket**，`:8081` |
| 认证 | **JWT**（`golang-jwt/jwt/v5`），双 Token（Access 2h / Refresh 30d）|
| 密码安全 | `bcrypt`（cost=12）+ SHA256 Pepper 双重保护 |
| 限流 | **`golang.org/x/time/rate`** Token Bucket，三档（全局/登录/上传）|
| 关系数据库 | **PostgreSQL 15**（消息持久化、会话管理、E2EE 公钥存储）|
| 缓存/消息 | **Redis 7**（离线消息队列、在线状态、双进程 Pub/Sub 解耦）|
| 对象存储 | **MinIO**（图片存储，S3 兼容，SHA256 内容寻址）|
| 容器编排 | **Docker Compose**（一键启动全部基础设施）|

---

## 重点考察项说明

---

### 一、消息通道与传输安全

#### 端到端加密（E2EE）架构

```
Alice 设备                  服务端（零知识）                Bob 设备
──────                      ──────────────                  ──────
X25519 私钥（Keychain）      仅存 publicKey                  X25519 私钥（Keychain）
ECDH(priv_A, pub_B) ──────────────────────────── ECDH(priv_B, pub_A)
         └─── 相同 SharedSecret ─── HKDF-SHA256 ─── AES-256-GCM 会话密钥 ───┘
                    │                                              │
              加密消息密文 ──► 服务端只转发密文，无法解密 ──► 解密还原明文
```

| 环节 | 算法 | 选型理由 |
|------|------|---------|
| 密钥协商 | **X25519 ECDH** | 前向安全、TLS 1.3 首选、CryptoKit 原生 |
| 密钥派生 | **HKDF-SHA256** | 防 DH 输出弱随机性，输出均匀 AES 密钥 |
| 消息加密 | **AES-256-GCM** | 认证加密，篡改后 AuthTag 校验失败即拒绝 |
| 密钥存储 | **iOS Keychain** | 私钥永不离设备，Secure Enclave 保护 |

#### 前后端架构选型——双进程分离

```
iOS ──HTTP REST──► App Server (:8080) ──► PostgreSQL（消息落库）
                        │
                   Redis PUBLISH
                        │
iOS ──WebSocket──► Gateway (:8081) ◄── Redis SUBSCRIBE
```

- **App Server**：处理所有 REST 接口、JWT 鉴权、消息持久化
- **Gateway**：专注 WebSocket 长连接管理、实时消息路由
- **Redis Pub/Sub**：解耦两个进程，独立扩展互不影响

#### 限流控制（防攻击）

| 位置 | 策略 | 参数 |
|------|------|------|
| HTTP 全局（IP） | Token Bucket | 60次/分钟，突发 20 |
| POST /login（IP） | Token Bucket | 5次/分钟，突发 3 |
| POST /upload（IP） | Token Bucket | 10次/分钟，突发 5 |
| WS 新连接（IP） | Token Bucket | 10次/分钟，突发 10 |
| WS 消息（每连接） | Token Bucket | 5条/秒，突发 10 |

#### WebSocket 可靠性

- 服务端：gorilla/websocket 原生 Ping/Pong，60s 超时踢出
- 客户端：应用层 JSON ping（25s），8s 无 pong 判断断线
- 重连：指数退避（1→2→4→8→16→30s 封顶，最多 8 次）

---

### 二、登录协议安全设计

#### 密码存储：双重哈希防脱库

```
用户密码 "123456"
    │
    ▼
SHA256( PEPPER + "123456" )        ← PEPPER 存服务器环境变量，不入库
    │
    ▼
bcrypt( 上述哈希, cost=12 )         ← 自带随机 salt，算力保护
    │
    ▼
存入数据库                           ← 即使数据库泄露，没有 PEPPER 无法暴力破解
```

#### JWT 双 Token——防类型混淆攻击

```
ACCESS_SECRET  ──签名──► Access Token（2h）   ← 用于所有业务接口
REFRESH_SECRET ──签名──► Refresh Token（30d）  ← 仅用于换新 Token Pair

两套独立密钥：Refresh Token 无法通过 ACCESS_SECRET 验签
              彻底防止"用 Refresh Token 冒充 Access Token"的类型混淆攻击
```

#### 客户端安全存储

```
存储位置           保护级别                    存储内容
──────────────────────────────────────────────────────────
iOS Keychain     kSecAttrAccessibleAfterFirstUnlock
                 设备重启未解锁时不可访问        Access Token
                                               Refresh Token
                                               X25519 私钥（E2EE）
```

#### 静默续期 + 强制登出

- App 启动时本地解析 JWT `exp` 字段（无网络），判断 Token 是否即将过期
- Access 过期 → 静默用 Refresh Token 换新 Token Pair（用户无感知）
- Refresh 也过期 → 清空 Keychain，跳转登录页
- 同账号二次登录 → Gateway 强制踢出旧连接，推送 `kicked` 事件，客户端强制登出

---

### 三、本地 DB 设计、索引与安全加密

#### Schema 设计

```sql
-- 主消息表
CREATE TABLE local_messages (
    id              INTEGER PRIMARY KEY,    -- 服务端消息 ID，全局唯一
    conversation_id INTEGER NOT NULL,
    sender_id       INTEGER NOT NULL,
    sender_nickname TEXT,
    plain_content   TEXT,                   -- E2EE 解密后明文（本地存储）
    msg_type        TEXT,                   -- 'text' | 'image'
    media_url       TEXT,                   -- 原图 URL
    thumb_url       TEXT,                   -- 缩略图 URL
    img_width       INTEGER,                -- 图片原始宽度（气泡预占位）
    img_height      INTEGER,                -- 图片原始高度
    created_at      REAL NOT NULL,
    is_mine         INTEGER
);

-- 索引：会话内按时间排序查询
CREATE INDEX idx_lm_conv ON local_messages(conversation_id, created_at);

-- FTS5 全文索引虚表（content table，不重复存储数据）
CREATE VIRTUAL TABLE messages_fts USING fts5(
    conversation_id  UNINDEXED,             -- 不索引，仅用于过滤
    sender_nickname,                        -- 支持按发送者搜索
    plain_content,                          -- 消息正文全文索引
    content       = local_messages,         -- 外部内容表，节省存储
    content_rowid = id,
    tokenize      = 'unicode61 remove_diacritics 1'  -- 中英文均支持
);

-- 元数据表（记录 FTS 初始化状态等）
CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT);
```

#### FTS 索引自动维护（触发器）

```sql
-- INSERT 时自动写 FTS（仅文本消息，跳过空内容和解密失败）
CREATE TRIGGER messages_ai AFTER INSERT ON local_messages
WHEN new.msg_type IN ('text','e2e') AND new.plain_content != ''
     AND new.plain_content NOT LIKE '[解密失败]%'
BEGIN
    INSERT INTO messages_fts(rowid, conversation_id, sender_nickname, plain_content)
    VALUES (new.id, new.conversation_id, new.sender_nickname, new.plain_content);
END;
-- DELETE / UPDATE 触发器类似，保证索引与主表始终一致
```

**初始化全量索引**：首次启动执行 FTS5 专用 rebuild 命令
```sql
INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
-- 注：content table 不支持 DELETE，只能用 rebuild 重建
```

#### 安全加密：iOS Data Protection

```
数据库文件加密方案选型

SQLCipher（应用层 AES-256）   → 需额外编译链，GRDB 6.x 已移除产品
iOS Data Protection（系统层） → 一行代码，Secure Enclave 硬件密钥管理 ✅

NSFileProtectionCompleteUnlessOpen：
- App 运行时透明读写（支持后台消息同步）
- 设备锁屏后文件加密，不解锁无法访问
- 即使物理拆机，密钥在 Secure Enclave 中无法提取
```

---

### 四、文本与图片收发流程及图片存储

#### 文本消息收发

```
发送方                App Server / Gateway               接收方
──────                ─────────────────────              ──────
E2EE 加密（AES-GCM）
生成 client_msg_id（UUID）
WS 发送密文 ──────► 落库 PostgreSQL
                   （唯一索引去重）         ──────────► WS 推送密文
◄── ACK(conv_id)   Redis Pub/Sub 解耦                  E2EE 解密
本地乐观更新                                            saveMessage
                                                        FTS trigger 写索引
```

**消息去重**：`client_msg_id` 唯一索引 + `ON CONFLICT DO NOTHING`，网络重试不产生重复

#### 图片消息完整流程

```
① 选图 → 计算 SHA256 哈希（本地，不上传）
         │
         ▼
② HEAD /api/files/{hash}
         ├─ 200 已存在 ──► 直接复用服务端 URL（秒传，零流量）
         └─ 404 新文件
                │
                ▼
③ 生成缩略图（UIGraphicsImageRenderer, scale=1.0, 长边 ≤ 198px, ~8KB）
   multipart 上传原图 + 缩略图
         │
         ▼
④ MinIO 以 {sha256}.jpg 内容寻址命名存储（天然去重）
         │
         ▼
⑤ E2EE 加密图片载荷：{ t:"image", v:originalUrl, thumb:thumbUrl, w:W, h:H }
   WebSocket 发送密文（服务端不知道这条密文是图片还是文字）
         │
         ▼
⑥ 接收方解密 → 获得 URL/缩略图/尺寸
   气泡按 img_width/img_height 预占位（无跳动）
   AsyncImage 先加载缩略图（8KB，<100ms）
   点击后懒加载原图
```

#### 图片存储设计要点

| 要点 | 实现 | 效果 |
|------|------|------|
| 内容寻址 | SHA256 哈希命名 | 相同内容只存一份，天然去重 |
| 秒传 | 上传前 HEAD 检查 | 重复图片零流量，毫秒完成 |
| 缩略图 | `scale=1.0` 渲染 198px | 8KB vs 原图 2MB，秒显 |
| 隐私保护 | URL 纳入 E2EE 载荷 | 服务端不知图片发给谁 |
| 预占位 | 宽高随消息入库 | 加载时布局零跳动 |
| 存储服务 | MinIO（本地 S3） | 可平替生产环境 COS/OSS |

---

## 快速启动

```bash
# 1. 启动基础设施（PostgreSQL + Redis + MinIO）
cd server && docker compose up -d

# 2. 启动 App Server
cd server/app && go run . &

# 3. 启动 Gateway
cd server/gateway && go run . &

# 4. iOS 客户端
# Xcode 打开 QQQ/QQQ.xcodeproj → File → Packages → Resolve → Run
```

**预置账号**（密码均 `123456`）：

| 用户名 | 昵称 |
|--------|------|
| yehangyuan | 叶航远 |
| yuhaohe | 俞昊赫 |
| alice | Alice |
| bob | Bob |
| charlie | Charlie |

---

## 目录结构

```
QQQ/
├── QQQ/                          # iOS 客户端
│   ├── Models/Models.swift       # 数据模型 + SearchResult
│   ├── Services/
│   │   ├── APIService.swift      # HTTP REST + SHA256 秒传
│   │   ├── WebSocketService.swift # WS 心跳 + 指数退避重连
│   │   ├── E2EEService.swift     # X25519 + HKDF + AES-GCM
│   │   ├── DatabaseService.swift # GRDB + FTS5 + Data Protection
│   │   └── KeychainService.swift # JWT / E2E 私钥安全存储
│   ├── ViewModels/
│   │   ├── AppState.swift        # 全局状态 + 后台同步 + WS 监听
│   │   ├── ChatViewModel.swift   # 会话状态 + 消息收发 + 解密
│   │   └── SearchViewModel.swift # FTS 搜索 + 防抖
│   └── Views/
│       ├── Chat/ChatView.swift   # 聊天页 + 消息高亮定位
│       └── Main/
│           ├── MessagesView.swift     # 会话列表
│           ├── SearchView.swift       # 全文搜索 UI
│           └── ContactsView.swift     # 联系人列表
│
└── server/                       # Go 后端
    ├── app/                      # App Server (:8080)
    │   ├── middleware/
    │   │   ├── auth.go           # JWT 鉴权（类型混淆防护）
    │   │   └── ratelimit.go      # Token Bucket 三档限流
    │   └── handlers/             # 业务处理器
    └── gateway/                  # Gateway (:8081)
        ├── hub.go                # WS Hub + 互踢 + 离线队列
        └── client.go             # WS Client + 消息频率限制
```
