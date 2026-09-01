import SwiftUI

struct DiscoveryView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    DiscoveryCard(icon: "newspaper.fill",   color: .orange,  title: "热点",   subtitle: "每日精选")
                    DiscoveryCard(icon: "flame.fill",       color: .red,     title: "趋势",   subtitle: "大家都在看")
                    DiscoveryCard(icon: "photo.on.rectangle.angled", color: .blue, title: "动态", subtitle: "朋友圈")
                    DiscoveryCard(icon: "gamecontroller.fill", color: .purple, title: "游戏",  subtitle: "小游戏中心")
                    DiscoveryCard(icon: "music.note",       color: .pink,    title: "音乐",   subtitle: "听歌识曲")
                    DiscoveryCard(icon: "star.fill",        color: .yellow,  title: "收藏",   subtitle: "我的收藏")
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("公台")
        }
    }
}

struct DiscoveryCard: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}
