// PawReportButton.swift — 回報開關（1b 熊掌浮鈕）
// 綁 LocationReporter.isReporting / start / stop
import SwiftUI

struct PawReportButton: View {
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Button(action: action) {
                ZStack {
                    if isOn {
                        Circle()
                            .strokeBorder(BearTheme.green.opacity(0.85), lineWidth: 2)
                            .frame(width: 90, height: 90)
                        Circle().fill(BearTheme.honeyGradient)
                            .frame(width: 76, height: 76)
                        PawGlyph(size: 36)
                    } else {
                        Circle().fill(.white.opacity(0.08))
                            .frame(width: 76, height: 76)
                        Circle().strokeBorder(BearTheme.honeyLight.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 76, height: 76)
                        PawGlyph(color: BearTheme.honeyLight, size: 36)
                            .opacity(0.75)
                    }
                }
                .frame(width: 90, height: 90)
                .shadow(color: isOn ? BearTheme.honey.opacity(0.4) : .clear, radius: 16, y: 8)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact, trigger: isOn)

            Text(isOn ? "點掌暫停" : "點掌開始")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(BearTheme.cream)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular.tint(BearTheme.surfaceHi.opacity(0.6)), in: .capsule)  // 加底、好判讀（同左上座標卡）
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
    }
}

#Preview {
    HStack(spacing: 30) {
        PawReportButton(isOn: true) {}
        PawReportButton(isOn: false) {}
    }
    .padding(40).background(BearTheme.bg)
}
