// PawPinView.swift — 地圖當前位置 pin：熊掌＋呼吸圈。
// 點一下＝切換 跟隨(羅盤) / 正北（onTap 回呼給地圖頁），帶一次縮放回饋動畫；active 時邊框換色高亮。
import SwiftUI

struct PawPinView: View {
    var active: Bool = false          // 跟隨(羅盤)模式 → 邊框換色高亮
    var onTap: () -> Void = {}
    @State private var pulse = false
    @State private var bounce = false

    var body: some View {
        ZStack {
            Circle()
                .fill(BearTheme.honey.opacity(0.25))
                .frame(width: 120, height: 120)
                .scaleEffect(pulse ? 1.15 : 0.4)
                .opacity(pulse ? 0 : 0.9)
                .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false), value: pulse)
            Circle()
                .fill(BearTheme.honeyGradient)
                .frame(width: 54, height: 54)
                .overlay(Circle().strokeBorder(active ? BearTheme.green : BearTheme.cream, lineWidth: 3))
                .overlay(PawGlyph(size: 28))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                .scaleEffect(bounce ? 1.18 : 1.0)
                .contentShape(Circle())
                .onTapGesture {
                    onTap()
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.4)) { bounce = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(170))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
                    }
                }
        }
        .onAppear { pulse = true }
    }
}

#Preview { PawPinView(active: true).padding(80).background(BearTheme.bg) }
