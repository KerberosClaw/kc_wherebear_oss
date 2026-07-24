// PhotoImportSheet.swift — 相簿匯入：選時間範圍（preset＋任意起訖）→ 掃描 → 確認
// 綁 PhotoImporter.scan(range:) / importPoints；只讀座標＋時間，明講不看照片
import SwiftUI

struct PhotoImportSheet: View {
    @Environment(PhotoImporter.self) private var importer
    @Environment(\.dismiss) private var dismiss
    var onImported: (Int) -> Void = { _ in }   // 匯入完成回呼 → 時間軸重載

    private enum RangeChoice: Int, CaseIterable {
        case today, week, custom
        var label: String {
            switch self {
            case .today: "今天"
            case .week: "最近 7 天"
            case .custom: "自訂⋯"
            }
        }
    }
    @State private var choice: RangeChoice = .today
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var customEnd = Date.now
    @State private var found: Int? = nil
    @State private var importResult: PhotoImporter.ImportResult? = nil
    @State private var isImporting = false

    // preset 也換算成任意起訖區間傳給 scan(range:)
    private var interval: DateInterval {
        let cal = Calendar.current
        switch choice {
        case .today: return DateInterval(start: cal.startOfDay(for: .now), end: .now)
        case .week: return DateInterval(start: cal.date(byAdding: .day, value: -7, to: .now) ?? .now, end: .now)
        case .custom:
            let end = max(customStart, customEnd)
            return DateInterval(start: min(customStart, customEnd), end: cal.date(byAdding: .day, value: 1, to: end) ?? end)
        }
    }
    // 掃描範圍顯示：同年 7/16 – 7/23；跨年 2025/12/25 – 2026/01/03
    private var scanRangeText: String {
        let cal = Calendar.current
        let s = cal.dateComponents([.year, .month, .day], from: interval.start)
        let e = cal.dateComponents([.year, .month, .day], from: interval.end)
        if s.year == e.year {
            return "\(s.month ?? 0)/\(s.day ?? 0) – \(e.month ?? 0)/\(e.day ?? 0)"
        }
        return String(format: "%d/%02d/%02d – %d/%02d/%02d",
                      s.year ?? 0, s.month ?? 0, s.day ?? 0, e.year ?? 0, e.month ?? 0, e.day ?? 0)
    }
    private var scanKey: String { "\(choice.rawValue)-\(customStart.timeIntervalSince1970)-\(customEnd.timeIntervalSince1970)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("從相簿匯入足跡")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(BearTheme.cream)
                    .padding(.top, 22)
                Text("把有 GPS 的照片變成時間軸上的點。")
                    .font(.system(size: 13))
                    .foregroundStyle(BearTheme.cream.opacity(0.55))
                    .padding(.top, 4)
                    .padding(.bottom, 16)

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BearTheme.greenText)
                        .padding(.top, 1)
                    Text("只讀取座標與拍攝時間，不會查看、上傳照片本身。")
                        .font(.system(size: 13.5, weight: .bold))
                        .lineSpacing(3)
                        .foregroundStyle(BearTheme.greenText)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BearTheme.green.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BearTheme.green.opacity(0.4), lineWidth: 1))
                )
                .padding(.bottom, 18)

                Text("時間範圍")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
                    .padding(.bottom, 8)
                HStack(spacing: 8) {
                    ForEach(RangeChoice.allCases, id: \.rawValue) { c in
                        Button { choice = c } label: {
                            Text(c.label)
                                .font(.system(size: 14, weight: choice == c ? .bold : .semibold))
                                .foregroundStyle(choice == c ? BearTheme.ink : BearTheme.cream.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(choice == c ? BearTheme.honeyLight.opacity(0.9) : .white.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, choice == .custom ? 10 : 18)

                if choice == .custom {
                    VStack(spacing: 4) {
                        DatePicker("從", selection: $customStart, in: ...Date.now, displayedComponents: .date)
                        DatePicker("到", selection: $customEnd, in: ...Date.now, displayedComponents: .date)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(BearTheme.cream)
                    .tint(BearTheme.honeyLight)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
                    .padding(.bottom, 18)
                }

                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(BearTheme.honeyLight.opacity(0.15))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "camera").font(.system(size: 18)).foregroundStyle(BearTheme.honeyLight))
                    VStack(alignment: .leading, spacing: 2) {
                        if let found {
                            Text("找到 \(found) 個帶定位的點")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(BearTheme.cream)
                            Text("掃描範圍：\(scanRangeText)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(BearTheme.cream.opacity(0.55))
                        } else {
                            Text("掃描中⋯")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(BearTheme.cream.opacity(0.7))
                        }
                    }
                    Spacer()
                    if found == nil { ProgressView().tint(BearTheme.honeyLight) }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                )
                .padding(.bottom, 18)

                if let res = importResult {
                    // 匯入結果提示（P2：不再靜默回頁；F：連不到伺服器要明講、不 hang）
                    VStack(spacing: 5) {
                        if res.failed {
                            Text("⚠️ 連不到伺服器")
                                .font(.system(size: 16.5, weight: .heavy))
                                .foregroundStyle(BearTheme.amberText)
                            Text(res.inserted > 0
                                 ? "已匯入 \(res.inserted) 個就中斷，網路穩了再匯剩下的。"
                                 : "檢查網路或 dev 連線後再試一次。")
                                .font(.system(size: 12.5))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(BearTheme.cream.opacity(0.55))
                        } else {
                            Text(res.inserted > 0 ? "✅ 匯入了 \(res.inserted) 個點" : "沒有新點可匯入")
                                .font(.system(size: 16.5, weight: .heavy))
                                .foregroundStyle(BearTheme.cream)
                            if res.total - res.inserted > 0 {
                                Text("\(res.total - res.inserted) 個是重複、已略過")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(BearTheme.cream.opacity(0.55))
                            }
                            if res.inserted > 0 {
                                Text("到對應日期查看（右上「選日期」）。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(BearTheme.cream.opacity(0.45))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    PrimaryButton(title: res.failed ? "關閉" : "完成", isLoading: false) {
                        onImported(res.inserted)
                        dismiss()
                    }
                } else {
                    PrimaryButton(title: found.map { "匯入 \($0) 個點" } ?? "匯入",
                                  isLoading: found == nil || isImporting) {
                        guard !isImporting, found != nil else { return }
                        Task {
                            isImporting = true
                            importResult = await importer.importPoints()
                            isImporting = false
                        }
                    }
                    Button("取消") { dismiss() }
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(BearTheme.cream.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 22)
        }
        .presentationDetents([.height(620)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(hex: 0x241D15))
        .task(id: scanKey) {
            found = nil
            importResult = nil
            found = await importer.scan(range: interval)
        }
    }
}
