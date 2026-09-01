-- QQQ Database Schema

CREATE TABLE IF NOT EXISTS users (
    id            BIGSERIAL    PRIMARY KEY,
    username      VARCHAR(50)  UNIQUE NOT NULL,
    nickname      VARCHAR(100) NOT NULL,
    password_hash VARCHAR(256) NOT NULL,
    avatar_url    TEXT         DEFAULT '',
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);

-- C2C 会话表，user_a_id 始终 < user_b_id
CREATE TABLE IF NOT EXISTS conversations (
    id              BIGSERIAL   PRIMARY KEY,
    user_a_id       BIGINT      NOT NULL REFERENCES users(id),
    user_b_id       BIGINT      NOT NULL REFERENCES users(id),
    last_message    TEXT        DEFAULT '',
    last_message_at TIMESTAMPTZ DEFAULT NOW(),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(user_a_id, user_b_id),
    CHECK(user_a_id < user_b_id)
);

-- 消息表（content 字段存储 AES-GCM 加密后的 base64 密文）
CREATE TABLE IF NOT EXISTS messages (
    id              BIGSERIAL    PRIMARY KEY,
    conversation_id BIGINT       NOT NULL REFERENCES conversations(id),
    sender_id       BIGINT       NOT NULL REFERENCES users(id),
    receiver_id     BIGINT       NOT NULL REFERENCES users(id),
    content         TEXT         NOT NULL DEFAULT '',
    msg_type        VARCHAR(20)  DEFAULT 'text',
    media_url       TEXT         DEFAULT '',
    is_read         BOOLEAN      DEFAULT false,
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conv_time
    ON messages(conversation_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_messages_receiver_unread
    ON messages(receiver_id) WHERE is_read = false;

-- E2EE：每位用户的 X25519 公钥（私钥永不离开设备 Keychain）
CREATE TABLE IF NOT EXISTS user_public_keys (
    user_id    BIGINT      REFERENCES users(id) PRIMARY KEY,
    public_key TEXT        NOT NULL,   -- base64(X25519 raw pubkey, 32 bytes)
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
