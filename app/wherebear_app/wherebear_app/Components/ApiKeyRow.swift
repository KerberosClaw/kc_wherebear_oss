// ApiKeyRow.swift — 金鑰列（名稱＋遮罩 wb_…last4＋last_used_at 相對時間＋撤銷）
// v2：對齊契約 §1.4（server id／key_last4／last_used_at timestamp；顯示層組字串）
import SwiftUI

struct ApiKeyRow: View {
    var apiKey: ApiKey
    var onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(apiKey.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(BearTheme.cream)
                Text("\(apiKey.masked) · \(apiKey.lastUsedText)")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
            }
            Spacer()
            Button("撤銷", action: onRevoke)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BearTheme.salmon)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
