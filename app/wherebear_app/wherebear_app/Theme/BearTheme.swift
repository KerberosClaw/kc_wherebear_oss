// BearTheme.swift — 設計 tokens（深色底＋暖熊 accent）
// 對應 mockup 色票：bg #17130F / surface #221B13 / cream #F4E3C8 / honey #C98A4B / #E8B878
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum BearTheme {
    static let bg          = Color(hex: 0x17130F) // 主背景（暖近黑）
    static let surface     = Color(hex: 0x221B13) // 卡片
    static let surfaceHi   = Color(hex: 0x262019) // modal
    static let sheet       = Color(hex: 0x201913) // bottom sheet
    static let cream       = Color(hex: 0xF4E3C8) // 主文字
    static let honey       = Color(hex: 0xC98A4B) // accent
    static let honeyLight  = Color(hex: 0xE8B878) // accent 亮
    static let ink         = Color(hex: 0x2A1D10) // accent 上的深字
    static let pawInk      = Color(hex: 0x3A2A18) // 掌印
    static let green       = Color(hex: 0x7FAE63) // 回報中
    static let greenText   = Color(hex: 0xCFE3BD)
    static let amber       = Color(hex: 0xD9A13A) // 警示
    static let amberText   = Color(hex: 0xECC57E)
    static let salmon      = Color(hex: 0xD98A6A) // 破壞性
    static let salmonText  = Color(hex: 0xEAB29A)
    static let offlineBlue = Color(hex: 0xB8C6DD) // 離線

    static var honeyGradient: LinearGradient {
        LinearGradient(colors: [honeyLight, honey], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
