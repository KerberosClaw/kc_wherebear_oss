// PrimaryButton.swift — 主要動作鈕（蜂蜜漸層）
import SwiftUI

struct PrimaryButton: View {
    var title: String
    var isLoading: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView().tint(BearTheme.ink)
                } else {
                    Text(title).font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundStyle(BearTheme.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(BearTheme.honeyGradient, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: BearTheme.honey.opacity(0.35), radius: 13, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
