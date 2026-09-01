import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @State private var showLogoutAlert = false

    var body: some View {
        NavigationStack {
            List {
                // 头像信息区
                Section {
                    HStack(spacing: 16) {
                        if let user = appState.currentUser {
                            AvatarView(user: user, size: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.nickname)
                                    .font(.system(size: 20, weight: .bold))
                                Text("@\(user.username)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                        }
                        Spacer()
                        Image(systemName: "qrcode")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                // 功能列表
                Section("账号") {
                    ProfileMenuItem(icon: "person.fill", color: .blue,    label: "个人资料")
                    ProfileMenuItem(icon: "bell.fill",   color: .red,     label: "消息通知")
                    ProfileMenuItem(icon: "lock.fill",   color: .orange,  label: "隐私设置")
                }

                Section("通用") {
                    ProfileMenuItem(icon: "paintpalette.fill", color: .purple, label: "外观主题")
                    ProfileMenuItem(icon: "internaldrive.fill", color: .gray,  label: "存储空间")
                    ProfileMenuItem(icon: "questionmark.circle.fill", color: .teal, label: "帮助与反馈")
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("退出登录")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我")
            .alert("退出登录", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    appState.logout()
                }
            } message: {
                Text("确定要退出当前账号吗？")
            }
        }
    }
}

struct ProfileMenuItem: View {
    let icon: String
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
            Text(label)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
