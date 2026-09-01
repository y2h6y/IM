import Foundation
import Combine

class WebSocketService: ObservableObject {
    static let shared = WebSocketService()

    @Published var latestIncoming: WSIncoming?
    @Published var isConnected    = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var currentToken: String?
    private let gatewayURL = "ws://localhost:8081/ws"

    // ── 重连控制 ──────────────────────────────────────────────────────
    private var reconnectTask:  Task<Void, Never>?
    private var heartbeatTask:  Task<Void, Never>?
    private var retryCount      = 0
    private let maxRetryCount   = 8        // 最多重试 8 次
    private let maxRetryDelay   = 30.0     // 最长退避 30s
    private var isKicked        = false    // 被踢出时不重连

    // ── 心跳参数 ──────────────────────────────────────────────────────
    private let pingInterval    = 25.0     // 每 25s 发一次 ping
    private let pongTimeout     = 8.0      // 8s 内没收到 pong 判为断线

    // MARK: - Connect / Disconnect ─────────────────────────────────────

    func connect(token: String) {
        isKicked   = false
        retryCount = 0
        currentToken = token
        doConnect(token: token)
    }

    private func doConnect(token: String) {
        guard let url = URL(string: "\(gatewayURL)?token=\(token)") else { return }
        disconnect(clearToken: false)

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true

        startReceiving()
        startHeartbeat()
        print("[WS] Connected (retry=\(retryCount))")
    }

    func disconnect(clearToken: Bool = true) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        if clearToken { currentToken = nil; retryCount = 0 }
    }

    // MARK: - Heartbeat ────────────────────────────────────────────────

    /// 每 25s 向服务端发一次应用层 ping（JSON）。
    /// 服务端收到 {"type":"ping"} 后回 {"type":"pong"}。
    /// 8s 内未收到 pong → 判为断线 → 触发重连。
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled, isConnected else { break }

                // 发送 ping
                let ping = #"{"type":"ping"}"#
                webSocketTask?.send(.string(ping)) { _ in }

                // pongTimeout 内没收到 pong → 主动断线并重连
                try? await Task.sleep(for: .seconds(pongTimeout))
                guard !Task.isCancelled else { break }
                if isConnected {
                    // 检查：如果心跳对应的 pong 已通过 receiveLoop 更新了 isConnected
                    // 此处只在 isConnected 仍为 true 但 pong 超时的情况下处理
                    // （pong 消息通过 handleText 更新 lastPong；这里用时间差判断）
                    if let last = lastPongTime, Date().timeIntervalSince(last) < pongTimeout + pingInterval + 1 {
                        continue // pong 正常
                    }
                    print("[WS] Heartbeat timeout — reconnecting")
                    await MainActor.run { self.isConnected = false }
                    scheduleReconnect()
                    break
                }
            }
        }
    }

    private var lastPongTime: Date?

    // MARK: - Receive Loop ─────────────────────────────────────────────

    private func startReceiving() {
        Task { await receiveLoop() }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }
        do {
            while true {
                let message = try await task.receive()
                switch message {
                case .string(let text):   handleText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleText(text) }
                @unknown default: break
                }
            }
        } catch {
            await MainActor.run { isConnected = false }
            if isKicked {
                print("[WS] Kicked — no reconnect")
                return
            }
            print("[WS] Lost: \(error.localizedDescription)")
            scheduleReconnect()
        }
    }

    // MARK: - Reconnect（指数退避）─────────────────────────────────────

    /// 断线后指数退避重连：1s → 2s → 4s → 8s → … → 30s 封顶
    private func scheduleReconnect() {
        guard let token = currentToken, !isKicked else { return }
        guard retryCount < maxRetryCount else {
            print("[WS] Max retries reached, giving up")
            return
        }

        let delay = min(pow(2.0, Double(retryCount)), maxRetryDelay)
        retryCount += 1
        print("[WS] Retry #\(retryCount) in \(Int(delay))s…")

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            doConnect(token: token)
        }
    }

    // MARK: - Send ─────────────────────────────────────────────────────

    func send(to userID: Int64, encryptedContent: String,
              msgType: String = "text", mediaUrl: String = "",
              clientMsgId: String = UUID().uuidString) {
        let out = WSOutgoing(
            type:        "message",
            to:          userID,
            content:     encryptedContent,
            msgType:     msgType,
            mediaUrl:    mediaUrl.isEmpty ? nil : mediaUrl,
            clientMsgId: clientMsgId
        )
        guard let data = try? JSONEncoder().encode(out),
              let str  = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(str)) { [weak self] error in
            if let error {
                print("[WS] Send error:", error)
                self?.scheduleReconnect()
            }
        }
    }

    // MARK: - Handle Text ──────────────────────────────────────────────

    private func handleText(_ text: String) {
        guard let data     = text.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(WSIncoming.self, from: data)
        else { return }

        // pong 响应：更新心跳时间，重置重试计数
        if incoming.type == "pong" {
            lastPongTime = Date()
            retryCount   = 0
            return
        }

        if incoming.type == "kicked" {
            isKicked = true
            let reason = incoming.error ?? "您的账号在另一台设备登录"
            print("[WS] Kicked:", reason)
            AppState.shared.forceLogout(reason: reason)
            return
        }

        latestIncoming = incoming
    }
}
