// LandmarkRow.swift — 地標清單列（名稱＋半徑；編輯／刪除）
import SwiftUI

struct LandmarkRow: View {
    var landmark: Landmark
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(BearTheme.honey.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay(PawGlyph(color: BearTheme.honeyLight, size: 17))
            VStack(alignment: .leading, spacing: 3) {
                Text(landmark.alias)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(BearTheme.cream)
                Text("半徑 \(landmark.radius) m")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
            }
            Spacer()
            Button("編輯", action: onEdit)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BearTheme.honeyLight)
            Button("刪除", action: onDelete)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BearTheme.salmon)
                .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
