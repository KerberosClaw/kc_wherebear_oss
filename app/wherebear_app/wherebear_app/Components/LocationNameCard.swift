// LocationNameCard.swift — resolved_name 地名卡（glass pill）
// 注意 born-clean：resolved_name 是敏感字串，只在這裡顯示，不進 log／截圖分享
import SwiftUI

struct LocationNameCard: View {
    var name: String

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(BearTheme.honey).frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(BearTheme.cream)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular.tint(BearTheme.surfaceHi.opacity(0.6)), in: .capsule)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
    }
}

#Preview { LocationNameCard(name: "示範地點").padding(30).background(BearTheme.bg) }
