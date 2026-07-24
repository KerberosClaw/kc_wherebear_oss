// InlineNotice.swift — 行內訊息（驗證信已寄／請先驗證／帳密錯／權限被拒）
import SwiftUI

struct InlineNotice: View {
    enum Kind { case success, warning, error }
    var kind: Kind
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    private var tint: Color {
        switch kind {
        case .success: BearTheme.green
        case .warning: BearTheme.amber
        case .error:   BearTheme.salmon
        }
    }
    private var fg: Color {
        switch kind {
        case .success: BearTheme.greenText
        case .warning: BearTheme.amberText
        case .error:   BearTheme.salmonText
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(fg)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BearTheme.honeyLight)
                    .underline()
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(tint.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.4), lineWidth: 1))
        )
    }
}

#Preview {
    VStack(spacing: 8) {
        InlineNotice(kind: .success, text: "驗證信已寄出，去收信點連結後回來登入。")
        InlineNotice(kind: .warning, text: "請先驗證 email 才能繼續。", actionTitle: "重寄驗證信", action: {})
        InlineNotice(kind: .error, text: "帳號或密碼不對，再試一次。")
        InlineNotice(kind: .warning, text: "定位權限被拒，背景回報無法啟動。", actionTitle: "去系統設定", action: {})
    }
    .padding(24).background(BearTheme.bg)
}
