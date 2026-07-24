// RelativeTime.swift — 中文相對時間顯示（api 金鑰「上次使用」等）
// 階梯：剛剛 / N分鐘前 / N小時前 / N天前(<7) / M月D日(今年·≥7天) / 去年 / YYYY年（更早）
// now 參數可注入 → 好寫單元測試；app 端用預設 .now。
import Foundation

func relativeZh(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    let secs = now.timeIntervalSince(date)
    if secs < 60 { return "剛剛" }                                    // 含未來時間防呆（secs<0）
    if secs < 3600 { return "\(Int(secs / 60))分鐘前" }
    if secs < 86400 { return "\(Int(secs / 3600))小時前" }
    let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
    if days < 7 { return "\(days)天前" }
    let dc = cal.dateComponents([.year, .month, .day], from: date)
    let nowYear = cal.component(.year, from: now)
    if dc.year == nowYear { return "\(dc.month ?? 0)月\(dc.day ?? 0)日" }   // 今年 ≥7 天：月日
    if dc.year == nowYear - 1 { return "去年" }                            // 去年：年粗度
    return "\(dc.year ?? 0)年"                                             // 更早：YYYY年
}
