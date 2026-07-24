// EmptyStateBear.swift — 熊插畫空狀態（初次無資料／該日無足跡／無金鑰）
import SwiftUI

struct EmptyStateBear: View {
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image("BearMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 84, height: 84)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.4), radius: 11, y: 4)
            Text(title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(BearTheme.cream)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(BearTheme.cream.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 7) {
                        Image(systemName: "camera").font(.system(size: 14, weight: .bold))
                        Text(actionTitle).font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(BearTheme.ink)
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Capsule().fill(BearTheme.honeyLight))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18).fill(BearTheme.bg.opacity(0.35)))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(BearTheme.honeyLight.opacity(0.3), style: .init(lineWidth: 1, dash: [5, 5]))
                )
        )
    }
}
