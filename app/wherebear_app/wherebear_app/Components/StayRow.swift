// StayRow.swift — 時間軸 stay 列（垂直時間線）
// v2：dwellSeconds(int 秒)＋confidence(0..1) 顯示層格式化；onName → 地標命名入口②
import SwiftUI

struct StayRow: View {
    var stay: Stay
    var index: Int
    var isLast: Bool = false
    var onName: (() -> Void)? = nil
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(spacing: 3) {
                marker
                if !isLast {
                    Rectangle()
                        .fill(BearTheme.honey.opacity(stay.isLowConfidence ? 0.2 : 0.35))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stay.name)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(BearTheme.cream)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    // 時間欄固定寬：進行中的停留只有起始時間（"21:07"）、已結束的有區間
                    // （"21:07 – 21:38"），寬度不同會讓左邊的名字拿到不一樣的空間 →
                    // **同一個長別名在兩列斷在不同位置**。固定寬度後每一列的名字欄一樣寬、斷行一致。
                    // 寬度取「已結束」那種格式在 12pt 下的實測寬度並留一點餘裕。
                    Text(timeRangeText)
                        .font(.system(size: 12))
                        .foregroundStyle(BearTheme.cream.opacity(0.5))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 84, alignment: .trailing)
                }
                HStack(spacing: 8) {
                    Text(detailText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(stay.source == .photoImport ? BearTheme.honeyLight : BearTheme.cream.opacity(0.55))
                    if let onName {
                        Button(action: onName) {
                            HStack(spacing: 3) {
                                Image(systemName: "tag").font(.system(size: 9, weight: .bold))
                                Text("命名").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(BearTheme.honeyLight)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().strokeBorder(BearTheme.honeyLight.opacity(0.4), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, isLast ? 4 : 16)
        }
        .opacity(stay.isLowConfidence && !isSelected ? 0.62 : 1)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(isSelected ? BearTheme.honeyLight.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }   // 點列 → 地圖 zoom 到該點（#7）＋選取
    }

    private var timeRangeText: String {
        let f = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
        if let to = stay.to { return "\(stay.from.formatted(f)) – \(to.formatted(f))" }
        return stay.from.formatted(f) // to == null：進行中／單點 import
    }

    private var detailText: String {
        if stay.source == .photoImport { return "相簿匯入 · 只讀了座標與時間" }
        if stay.isLowConfidence { return "約 \(stay.dwellText) · 訊號稀疏、可能不準" }
        return "停留 \(stay.dwellText)"
    }

    @ViewBuilder private var marker: some View {
        ZStack {
            if stay.source == .photoImport {
                Circle().fill(BearTheme.honeyLight)
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(BearTheme.ink)
            } else if stay.isLowConfidence {
                Circle().fill(BearTheme.honey.opacity(0.4))
                Circle().strokeBorder(BearTheme.honeyLight.opacity(0.6), style: .init(lineWidth: 1.5, dash: [3, 3]))
                Text("\(index)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(BearTheme.honeyLight)  // 顯示編號、對得上地圖點；低信心用虛線圈區分
            } else {
                Circle().fill(BearTheme.honey)
                Text("\(index)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(BearTheme.ink)
            }
        }
        .frame(width: 26, height: 26)
    }
}
