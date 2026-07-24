// Taglines.swift — 啟動 splash 氛圍小字（隨機輪播）
// 詞庫優先序：私房 Taglines.local.json（gitignored）→ 公版 Taglines.json（committed sample）→ 保底。
import Foundation

enum Taglines {
    static func random() -> String { all.randomElement() ?? "熊熊在找路上。" }

    private static let all: [String] = {
        for name in ["Taglines.local", "Taglines"] {   // 私房優先
            if let url = Bundle.main.url(forResource: name, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let arr = try? JSONDecoder().decode([String].self, from: data),
               !arr.isEmpty {
                return arr
            }
        }
        return ["熊熊在找路上。", "走慢一點，風景才跟得上。"]   // bundle 讀不到時的保底
    }()
}
