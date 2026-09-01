import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMsg: String?
    @State private var animateGradient = false

    var body: some View {
        ZStack {
            // ── 动态渐变背景 ────────────────────────────────
            AnimatedBackground()

            // ── 毛玻璃登录卡片 ──────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 80)

                    // Logo
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(0.25))
                                .frame(width: 90, height: 90)
                            Text("QQQ")
                                .font(.system(size: 28, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Text("欢迎回来")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.bottom, 40)

                    // ── 卡片 ────────────────────────────────
                    VStack(spacing: 20) {
                        // 用户名
                        HStack(spacing: 12) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            TextField("用户名", text: $username)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )

                        // 密码
                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            SecureField("密码", text: $password)
                                .textContentType(.password)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(.white.opacity(0.25), lineWidth: 1)
                        )

                        // 错误信息
                        if let err = errorMsg {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.9))
                                .multilineTextAlignment(.center)
                        }

                        // 登录按钮
                        Button {
                            doLogin()
                        } label: {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("登 录")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                LinearGradient(
                                    colors: [Color(hex: "4776E6"), Color(hex: "8E54E9")],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .purple.opacity(0.4), radius: 8, y: 4)
                        }
                        .disabled(isLoading)

                        // 快速填充提示
                        VStack(spacing: 4) {
                            Text("预设账号（密码均为 123456）")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                            HStack(spacing: 12) {
                                quickFillButton("yehangyuan")
                                quickFillButton("yuhaohe")
                                quickFillButton("alice")
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
                    .padding(.horizontal, 28)

                    Spacer(minLength: 80)
                }
            }
        }
    }

    private func quickFillButton(_ name: String) -> some View {
        Button {
            username = name
            password = "123456"
        } label: {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private func doLogin() {
        guard !username.isEmpty, !password.isEmpty else {
            errorMsg = "请填写用户名和密码"
            return
        }
        isLoading = true
        errorMsg = nil
        Task {
            do {
                try await appState.login(username: username, password: password)
            } catch {
                errorMsg = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - AnimatedBackground

struct AnimatedBackground: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "0f0c29"),
                    Color(hex: "302b63"),
                    Color(hex: "24243e")
                ],
                startPoint: phase ? .topLeading : .bottomTrailing,
                endPoint: phase ? .bottomTrailing : .topLeading
            )
            .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }

            // 装饰光晕
            Circle()
                .fill(Color(hex: "4776E6").opacity(0.3))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: -60, y: -200)

            Circle()
                .fill(Color(hex: "8E54E9").opacity(0.3))
                .frame(width: 250, height: 250)
                .blur(radius: 80)
                .offset(x: 80, y: 200)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double(rgb & 0xFF)          / 255
        self.init(red: r, green: g, blue: b)
    }
}
