// FrequencyPicker.swift — 回報頻率 2 選 1（省電／標準，預設省電）
// 綁 LocationReporter.frequency / setFrequency
import SwiftUI

struct FrequencyPicker: View {
    @Binding var frequency: ReportFrequency

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ReportFrequency.allCases, id: \.self) { f in
                Button { frequency = f } label: {
                    Text(f.label)
                        .font(.system(size: 13, weight: frequency == f ? .bold : .semibold))
                        .foregroundStyle(frequency == f ? BearTheme.ink : BearTheme.cream.opacity(0.6))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(frequency == f ? BearTheme.honeyLight.opacity(0.9) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.07)))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: frequency)
    }
}
