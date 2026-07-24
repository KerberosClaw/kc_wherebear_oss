// LongStayPromptCard.swift — 地標入口①：偵測到長停留 → 地圖首頁浮卡「幫這裡命名？」
// 由 LandmarkManager.pendingLongStay 觸發；純自訂、不逼問（可略過）
import SwiftUI

struct LongStayPromptCard: View {
    var onName: () -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image("BearMascot")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("在這裡待了一陣子")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(BearTheme.cream)
                    Text("幫這裡命名？之後足跡就用你的名字。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(BearTheme.cream.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: onName) {
                    Text("幫這裡命名")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(BearTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(BearTheme.honeyGradient, in: Capsule())
                }
                .buttonStyle(.plain)
                Button(action: onSkip) {
                    Text("略過")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(BearTheme.cream.opacity(0.55))
                        .frame(width: 76)
                        .frame(height: 38)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(BearTheme.sheet.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }
}
