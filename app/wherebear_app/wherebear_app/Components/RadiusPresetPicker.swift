// RadiusPresetPicker.swift — 地標半徑 preset（精確點／一般場所／大範圍／自訂公尺）
import SwiftUI

enum RadiusPreset: CaseIterable, Equatable {
    case precise, place, area, custom
    var label: String {
        switch self {
        case .precise: "精確點"
        case .place:   "一般場所"
        case .area:    "大範圍"
        case .custom:  "自訂"
        }
    }
    var meters: Int? {
        switch self {
        case .precise: 30
        case .place:   100
        case .area:    500
        case .custom:  nil
        }
    }
    static func matching(_ radius: Int) -> RadiusPreset {
        allCases.first { $0.meters == radius } ?? .custom
    }
}

struct RadiusPresetPicker: View {
    @Binding var preset: RadiusPreset
    @Binding var customRadius: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(RadiusPreset.allCases, id: \.self) { p in
                    Button { preset = p } label: {
                        VStack(spacing: 1) {
                            Text(p.label)
                                .font(.system(size: 12.5, weight: preset == p ? .bold : .semibold))
                            if let m = p.meters {
                                Text("\(m) m").font(.system(size: 10))
                                    .opacity(0.7)
                            }
                        }
                        .foregroundStyle(preset == p ? BearTheme.ink : BearTheme.cream.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(preset == p ? BearTheme.honeyLight.opacity(0.9) : .white.opacity(0.07))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if preset == .custom {
                HStack(spacing: 12) {
                    Slider(value: $customRadius, in: 30...1000, step: 10)
                        .tint(BearTheme.honeyLight)
                    Text("\(Int(customRadius)) m")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(BearTheme.honeyLight)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: preset)
    }
}
