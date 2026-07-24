// NewKeyModal.swift — 新金鑰明文「只顯示一次」modal
// 規則：明文絕不二次顯示；離開前強制看到警告＋複製
import SwiftUI

struct NewKeyModal: View {
    var name: String
    var plaintext: String
    var onDone: () -> Void
    @State private var copied = false

    var body: some View {
        ZStack {
            BearTheme.bg.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 0) {
                Circle().fill(BearTheme.green.opacity(0.15))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(BearTheme.green))
                    .padding(.bottom, 10)
                Text("「\(name)」已建立")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(BearTheme.cream)
                Text(Date.now.formatted(date: .numeric, time: .omitted))
                    .font(.system(size: 12.5))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
                    .padding(.bottom, 16)

                Text(plaintext)
                    .font(.system(size: 16.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(BearTheme.honeyLight)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(BearTheme.bg)
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BearTheme.honeyLight.opacity(0.4), lineWidth: 1))
                    )
                    .padding(.bottom, 10)

                Button {
                    UIPasteboard.general.string = plaintext
                    copied = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 14, weight: .bold))
                        Text(copied ? "已複製" : "複製金鑰").font(.system(size: 14.5, weight: .bold))
                    }
                    .foregroundStyle(BearTheme.honeyLight)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(BearTheme.honeyLight.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(BearTheme.honeyLight.opacity(0.4), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.success, trigger: copied)
                .padding(.bottom, 14)

                InlineNotice(kind: .warning, text: "明文只顯示這一次。離開此頁後就再也看不到，請先複製保存。")
                    .padding(.bottom, 16)

                PrimaryButton(title: "我已保存金鑰", action: onDone)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 28).fill(BearTheme.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)))
            .shadow(color: .black.opacity(0.7), radius: 35, y: 12)
            .padding(24)
        }
    }
}
