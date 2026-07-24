// DateChips.swift — 時間軸日期選擇（今天／昨天／選日期）
import SwiftUI

struct DateChips: View {
    var items: [String]
    @Binding var selected: Int
    var onTap: ((Int) -> Void)? = nil   // 每次點都觸發（即使 index 沒變）→「選日期」可重開 picker

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Button { selected = i; onTap?(i) } label: {
                    Text(items[i])
                        .font(.system(size: 13.5, weight: selected == i ? .bold : .semibold))
                        .foregroundStyle(selected == i ? BearTheme.ink : BearTheme.cream.opacity(0.6))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 17)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(selected == i ? BearTheme.honeyLight.opacity(0.9) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassEffect(.regular.tint(Color(hex: 0x282018).opacity(0.6)), in: .capsule)
    }
}
