// StatusPill.swift — 地圖首頁狀態列（回報中／已停／權限不足／過時／離線）
// 狀態由 MapHomeScreen 從 LocationReporter＋LocationVM 推導
import SwiftUI

enum ReportStatus: Equatable {
    case reporting(last: String, frequency: String)
    case stopped
    case permissionInsufficient
    case stale(String)   // 「42 分前」
    case offline
}

struct StatusPill: View {
    var status: ReportStatus
    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            switch status {
            case .reporting(let last, let freq):
                Circle().fill(BearTheme.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: BearTheme.green.opacity(0.8), radius: 4)
                Text("回報中 · 上次 \(last) · \(freq)").foregroundStyle(BearTheme.greenText)
            case .stopped:
                Circle().fill(BearTheme.cream.opacity(0.35)).frame(width: 7, height: 7)
                Text("已停止回報 · 點熊掌開始").foregroundStyle(BearTheme.cream.opacity(0.55))
            case .permissionInsufficient:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(BearTheme.amberText)
                Text("定位權限不足").foregroundStyle(BearTheme.amberText)
                if let onOpenSettings {
                    Button("前往設定", action: onOpenSettings)
                        .foregroundStyle(BearTheme.honeyLight).underline()
                }
            case .stale(let ago):
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 11)).foregroundStyle(BearTheme.amberText)
                Text("位置可能不是最新 · \(ago)").foregroundStyle(BearTheme.amberText)
            case .offline:
                Image(systemName: "wifi.slash").font(.system(size: 11)).foregroundStyle(BearTheme.offlineBlue)
                Text("離線 · 佇列中，有網補送").foregroundStyle(BearTheme.offlineBlue)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(background)
    }

    @ViewBuilder private var background: some View {
        switch status {
        case .permissionInsufficient, .stale:
            Capsule().fill(BearTheme.amber.opacity(0.12))
                .overlay(Capsule().strokeBorder(BearTheme.amber.opacity(0.5), lineWidth: 0.5))
        case .offline:
            Capsule().fill(BearTheme.offlineBlue.opacity(0.12))
                .overlay(Capsule().strokeBorder(BearTheme.offlineBlue.opacity(0.45), lineWidth: 0.5))
        default:
            // iOS 26 Liquid Glass（自訂浮動元件才自己上 glass）
            Color.clear.glassEffect(.regular.tint(BearTheme.surface.opacity(0.6)), in: .capsule)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StatusPill(status: .reporting(last: "3 分前", frequency: "省電"))
        StatusPill(status: .stopped)
        StatusPill(status: .permissionInsufficient, onOpenSettings: {})
        StatusPill(status: .stale("42 分前"))
        StatusPill(status: .offline)
    }
    .padding(30).background(BearTheme.bg)
}
