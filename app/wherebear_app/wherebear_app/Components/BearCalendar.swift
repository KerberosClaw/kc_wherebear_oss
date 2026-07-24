// BearCalendar.swift — 自刻多選月曆（時間軸「行事曆多選」用）
// 中文年月/星期；有記錄的日在數字下方標小熊掌；已選高亮；未來日禁選。
// 日期以「當地時區的 yyyy-MM-dd」字串當 key（避開 Date/tz 比對坑）。
import SwiftUI

struct BearCalendar: View {
    @Binding var selected: Set<String>   // 選取的 "yyyy-MM-dd"（當地）
    var recorded: Set<String>            // 有記錄的 "yyyy-MM-dd"
    @Binding var month: Date             // 顯示中的月（任一該月日期）
    var onMonthChange: () -> Void        // 切月後（month 已更新）→ 外面重載該月 recorded

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: Config.tz) ?? .current
        return c
    }
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(spacing: 2) {
                ForEach(weekdays, id: \.self) { w in
                    Text(w)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BearTheme.cream.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 46) }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            monthButton(system: "chevron.left", delta: -1)
            Spacer()
            Text(verbatim: "\(cal.component(.year, from: month))年 \(cal.component(.month, from: month))月")  // verbatim 防千分位逗號
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(BearTheme.cream)
            Spacer()
            monthButton(system: "chevron.right", delta: 1)
        }
        .padding(.horizontal, 4)
    }

    private func monthButton(system: String, delta: Int) -> some View {
        Button {
            if let m = cal.date(byAdding: .month, value: delta, to: month) { month = m; onMonthChange() }
        } label: {
            Image(systemName: system)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(BearTheme.honeyLight)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private func dayCell(_ d: Date) -> some View {
        let k = key(d)
        let isSel = selected.contains(k)
        let isRec = recorded.contains(k)
        let isToday = cal.isDate(d, inSameDayAs: Date())
        let isFuture = cal.startOfDay(for: d) > cal.startOfDay(for: Date())
        let num = cal.component(.day, from: d)
        return Button {
            if isSel { selected.remove(k) } else { selected.insert(k) }
        } label: {
            VStack(spacing: 1) {
                Text("\(num)")
                    .font(.system(size: 16, weight: isSel ? .heavy : .regular))
                    .foregroundStyle(isSel ? BearTheme.ink : (isFuture ? BearTheme.cream.opacity(0.25) : BearTheme.cream))
                Image(systemName: "pawprint.fill")       // 有記錄 → 數字下方小熊掌（沒記錄也佔位、對齊）
                    .font(.system(size: 8))
                    .foregroundStyle(isSel ? BearTheme.ink.opacity(0.7) : BearTheme.honeyLight)
                    .opacity(isRec ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Circle().fill(isSel ? BearTheme.honeyLight : .clear).frame(width: 40, height: 40))
            .overlay(isToday && !isSel
                     ? Circle().strokeBorder(BearTheme.honeyLight.opacity(0.5), lineWidth: 1).frame(width: 40, height: 40)
                     : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    private var cells: [Date?] {
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let lead = cal.component(.weekday, from: first) - 1   // 1=日 → 前置空格
        var arr: [Date?] = Array(repeating: nil, count: lead)
        for day in range { arr.append(cal.date(byAdding: .day, value: day - 1, to: first)) }
        return arr
    }

    private func key(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
