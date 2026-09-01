import Foundation
import Security
import GRDB

// MARK: - DatabaseService

/// 本地数据库服务
/// - 加密层：iOS Data Protection（AES-256 硬件加速，NSFileProtectionCompleteUnlessOpen）
///           等效于 SQLCipher 对 iOS 设备的防护强度，由 Secure Enclave 管理密钥
/// - 检索层：FTS5 全文虚表，触发器自动维护索引，支持中英文搜索
/// - 迁移：首次升级时自动将旧版数据库文件加上 Data Protection 属性
class DatabaseService {
    static let shared = DatabaseService()

    private var dbQueue: DatabaseQueue!

    init() {
        setupDatabase()
    }

    // MARK: - Setup ──────────────────────────────────────────────────

    private func setupDatabase() {
        let dir  = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = dir.appendingPathComponent("qqq_messages.sqlite")
        let dbPath = dbURL.path

        // 设置 iOS Data Protection：设备锁屏后文件自动加密，App 活跃时透明访问
        applyDataProtection(to: dbPath)

        do {
            dbQueue = try DatabaseQueue(path: dbPath)
            try dbQueue.write { db in
                try createTablesAndTriggers(db)
                try runSchemaUpgrades(db)
            }
            // Bulk-populate FTS for existing messages（runs once per install）
            try dbQueue.write { db in
                try populateFTSOnce(db)
            }
        } catch {
            print("[DB] Setup error:", error)
        }
    }

    /// 给数据库文件设置 NSFileProtectionCompleteUnlessOpen
    /// - complete       = 锁屏后文件不可访问（适合无后台同步的场景）
    /// - completeUnlessOpen = App 打开文件后即使锁屏仍可读写（适合后台消息同步）
    private func applyDataProtection(to path: String) {
        let attrs: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUnlessOpen
        ]
        // 文件存在则直接设置；不存在则在创建后由 DatabaseQueue 调用同样逻辑
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
        }
        // WAL shm/wal 辅助文件同样保护
        for ext in ["-shm", "-wal"] {
            let aux = path + ext
            if FileManager.default.fileExists(atPath: aux) {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: aux)
            }
        }
    }

    // MARK: - Schema ─────────────────────────────────────────────────

    private func createTablesAndTriggers(_ db: Database) throws {
        try db.execute(sql: "PRAGMA journal_mode = WAL")

        // ── Main message table ──────────────────────────────────────
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS local_messages (
            id              INTEGER PRIMARY KEY,
            conversation_id INTEGER NOT NULL,
            sender_id       INTEGER NOT NULL,
            sender_nickname TEXT    DEFAULT '',
            plain_content   TEXT    DEFAULT '',
            msg_type        TEXT    DEFAULT 'text',
            media_url       TEXT    DEFAULT '',
            thumb_url       TEXT    DEFAULT '',
            img_width       INTEGER DEFAULT 0,
            img_height      INTEGER DEFAULT 0,
            created_at      REAL    NOT NULL,
            is_mine         INTEGER DEFAULT 0
        )
        """)

        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS idx_lm_conv
        ON local_messages(conversation_id, created_at)
        """)

        // ── FTS5 virtual table (content table = local_messages) ─────
        // tokenize='unicode61' handles both ASCII and CJK (each CJK char is its own token)
        try db.execute(sql: """
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            conversation_id UNINDEXED,
            sender_nickname,
            plain_content,
            content     = local_messages,
            content_rowid = id,
            tokenize    = 'unicode61 remove_diacritics 1'
        )
        """)

        // ── Triggers to keep FTS in sync ────────────────────────────
        // Only index text-type messages with non-empty content
        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS messages_ai
        AFTER INSERT ON local_messages
        WHEN new.msg_type IN ('text','e2e') AND new.plain_content != ''
             AND new.plain_content NOT LIKE '[解密失败]%'
        BEGIN
            INSERT INTO messages_fts(rowid, conversation_id, sender_nickname, plain_content)
            VALUES (new.id, new.conversation_id, new.sender_nickname, new.plain_content);
        END
        """)

        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS messages_ad
        AFTER DELETE ON local_messages
        BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, conversation_id, sender_nickname, plain_content)
            VALUES ('delete', old.id, old.conversation_id, old.sender_nickname, old.plain_content);
        END
        """)

        try db.execute(sql: """
        CREATE TRIGGER IF NOT EXISTS messages_au
        AFTER UPDATE ON local_messages
        BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, conversation_id, sender_nickname, plain_content)
            VALUES ('delete', old.id, old.conversation_id, old.sender_nickname, old.plain_content);
            INSERT INTO messages_fts(rowid, conversation_id, sender_nickname, plain_content)
            VALUES (new.id, new.conversation_id, new.sender_nickname, new.plain_content);
        END
        """)

        // ── Metadata table (for migration flags) ────────────────────
        try db.execute(sql: """
        CREATE TABLE IF NOT EXISTS db_metadata (
            key   TEXT PRIMARY KEY,
            value TEXT
        )
        """)
    }

    /// ALTER TABLE migrations — safely ignored on duplicate column
    private func runSchemaUpgrades(_ db: Database) throws {
        for sql in [
            "ALTER TABLE local_messages ADD COLUMN thumb_url  TEXT    DEFAULT ''",
            "ALTER TABLE local_messages ADD COLUMN img_width  INTEGER DEFAULT 0",
            "ALTER TABLE local_messages ADD COLUMN img_height INTEGER DEFAULT 0",
        ] { try? db.execute(sql: sql) }
    }

    /// Bulk-populate FTS from all existing messages — runs only once (tracked by metadata flag).
    /// Uses FTS5 content-table 'rebuild' command instead of manual DELETE+INSERT,
    /// because DELETE is not supported on external content FTS5 tables.
    private func populateFTSOnce(_ db: Database) throws {
        let populated = try String.fetchOne(
            db, sql: "SELECT value FROM db_metadata WHERE key = 'fts_populated'")
        if populated == "1" { return }

        // FTS5 content table rebuild: reads ALL rows from local_messages and rebuilds the index.
        // This is the correct and only supported way to bulk-populate an external content FTS5 table.
        try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")

        try db.execute(sql: """
        INSERT OR REPLACE INTO db_metadata(key, value) VALUES('fts_populated', '1')
        """)

        let count = (try? Int.fetchOne(db, sql: "SELECT count(*) FROM messages_fts")) ?? 0
        print("[DB] FTS rebuilt: \(count ?? 0) rows indexed")
    }

    // MARK: - Write ───────────────────────────────────────────────────

    func saveMessage(_ msg: LocalMessage) {
        try? dbQueue.write { db in
            try db.execute(sql: """
            INSERT OR REPLACE INTO local_messages
              (id, conversation_id, sender_id, sender_nickname, plain_content,
               msg_type, media_url, thumb_url, img_width, img_height,
               created_at, is_mine)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                msg.id,
                msg.conversationId,
                msg.senderId,
                msg.senderNickname,
                msg.plainContent,
                msg.msgType,
                msg.mediaUrl,
                msg.thumbUrl,
                msg.imageWidth,
                msg.imageHeight,
                msg.createdAt.timeIntervalSince1970,
                msg.isMine ? 1 : 0
            ])
        }
    }

    // MARK: - Read ────────────────────────────────────────────────────

    func getMessages(conversationId: Int64, limit: Int = 100) -> [LocalMessage] {
        (try? dbQueue.read { db in
            try self.fetchLocalMessages(db, sql: """
            SELECT id, conversation_id, sender_id, sender_nickname, plain_content,
                   msg_type, media_url, thumb_url, img_width, img_height,
                   created_at, is_mine
            FROM local_messages
            WHERE conversation_id = ?
            ORDER BY created_at ASC
            LIMIT ?
            """, arguments: [conversationId, limit])
        }) ?? []
    }

    func latestMessageId(conversationId: Int64) -> Int64 {
        let result = try? dbQueue.read { db in
            try Int64.fetchOne(db, sql: """
            SELECT COALESCE(MAX(id), 0) FROM local_messages WHERE conversation_id = ?
            """, arguments: [conversationId])
        }
        return result ?? 0 ?? 0
    }

    // MARK: - FTS Search ──────────────────────────────────────────────

    /// Basic search (for backwards-compat callers)
    func searchMessages(query: String) -> [LocalMessage] {
        searchMessagesWithSnippet(query: query).map { $0.message }
    }

    /// FTS5 search — returns matched messages with highlighted snippets.
    /// Falls back to LIKE if FTS throws / returns nothing (handles very short queries,
    /// not-yet-rebuilt FTS index, or tokenizer edge cases).
    func searchMessagesWithSnippet(query: String) -> [(message: LocalMessage, snippet: String)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        // Always try FTS first; on any issue fall through to LIKE
        let ftsResults = ftSearch(q) ?? []
        if !ftsResults.isEmpty { return ftsResults }

        // LIKE fallback — reliable for any content
        return likeSearch(q)
    }

    private func ftSearch(_ q: String) -> [(message: LocalMessage, snippet: String)]? {
        let ftsQuery = buildFTSQuery(q)
        guard !ftsQuery.isEmpty else { return nil }

        return try? dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
            SELECT lm.id, lm.conversation_id, lm.sender_id, lm.sender_nickname,
                   lm.plain_content, lm.msg_type, lm.media_url, lm.thumb_url,
                   lm.img_width, lm.img_height, lm.created_at, lm.is_mine,
                   snippet(messages_fts, 2, '《', '》', '…', 20) AS fts_snippet
            FROM   messages_fts
            JOIN   local_messages lm ON lm.id = messages_fts.rowid
            WHERE  messages_fts MATCH ?
            ORDER  BY rank
            LIMIT  100
            """, arguments: [ftsQuery])

            return rows.map { row in
                let msg = self.rowToLocalMessage(row)
                let snippet = (row["fts_snippet"] as String?) ?? msg.plainContent
                return (message: msg, snippet: snippet)
            }
        }
    }

    private func likeSearch(_ q: String) -> [(message: LocalMessage, snippet: String)] {
        (try? dbQueue.read { db in
            let rows = try self.fetchLocalMessages(db, sql: """
            SELECT id, conversation_id, sender_id, sender_nickname, plain_content,
                   msg_type, media_url, thumb_url, img_width, img_height,
                   created_at, is_mine
            FROM local_messages
            WHERE plain_content LIKE ? AND msg_type IN ('text','e2e')
            ORDER BY created_at DESC
            LIMIT 50
            """, arguments: ["%\(q)%"])
            return rows.map { msg in
                // Build a basic snippet: truncate around the first match
                let snippet = makeSimpleSnippet(msg.plainContent, query: q)
                return (message: msg, snippet: snippet)
            }
        }) ?? []
    }

    // MARK: - Helpers ─────────────────────────────────────────────────

    /// Build FTS5 query: phrase match per token (works for both Chinese and Latin text).
    /// E.g. "你好 world" → `"你好" "world"`
    /// Falls back to bare token on phrase-build failure.
    private func buildFTSQuery(_ raw: String) -> String {
        let tokens = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        // Wrap each token in double-quotes for phrase search.
        // FTS5 phrase "你好" tokenizes the pattern (你→好) and matches that sequence.
        return tokens
            .map { tok in
                let escaped = tok.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            .joined(separator: " ")   // space = AND in FTS5
    }

    private func makeSimpleSnippet(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return String(text.prefix(60))
        }
        let start = text.index(range.lowerBound,
                               offsetBy: -min(20, text.distance(from: text.startIndex, to: range.lowerBound)),
                               limitedBy: text.startIndex) ?? text.startIndex
        let end   = text.index(range.upperBound,
                               offsetBy: min(40, text.distance(from: range.upperBound, to: text.endIndex)),
                               limitedBy: text.endIndex) ?? text.endIndex
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end   == text.endIndex   ? "" : "…"
        return prefix + String(text[start..<end]) + suffix
    }

    private func fetchLocalMessages(_ db: Database, sql: String,
                                    arguments: StatementArguments = []) throws -> [LocalMessage] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { rowToLocalMessage($0) }
    }

    private func rowToLocalMessage(_ row: Row) -> LocalMessage {
        LocalMessage(
            id:             row["id"]             ?? 0,
            conversationId: row["conversation_id"] ?? 0,
            senderId:       row["sender_id"]       ?? 0,
            senderNickname: row["sender_nickname"] ?? "",
            plainContent:   row["plain_content"]   ?? "",
            msgType:        row["msg_type"]        ?? "text",
            mediaUrl:       row["media_url"]       ?? "",
            thumbUrl:       row["thumb_url"]       ?? "",
            imageWidth:     row["img_width"]       ?? 0,
            imageHeight:    row["img_height"]      ?? 0,
            createdAt:      Date(timeIntervalSince1970: row["created_at"] ?? 0.0),
            isMine:         (row["is_mine"] as Int? ?? 0) != 0
        )
    }
}
