// AuthScreen.swift — Onboarding／登入／註冊／忘記密碼＋email 驗證擋牆
// 綁 SupabaseSession；定位權限請求由 LocationReporter 在登入成功後發動（repo 端）
import SwiftUI

struct AuthScreen: View {
    @Environment(SupabaseSession.self) private var session
    enum Mode { case signIn, signUp, forgot }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var showResetConfirm = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x2A2015), BearTheme.bg],
                           center: .top, startRadius: 0, endRadius: 560)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    mascotHeader
                    VStack(spacing: 12) {
                        notices
                        AuthTextField(icon: "envelope", placeholder: "email", text: $email)
                        if mode != .forgot {
                            AuthTextField(icon: "lock", placeholder: "密碼", text: $password, isSecure: true)
                        }
                        PrimaryButton(title: primaryTitle, isLoading: isLoading) { submit() }
                        HStack {
                            Button(mode == .signIn ? "註冊新帳號" : "回登入") {
                                mode = (mode == .signIn) ? .signUp : .signIn
                            }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(BearTheme.honeyLight)
                            Spacer()
                            if mode == .signIn {
                                Button("忘記密碼？") { mode = .forgot }
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(BearTheme.cream.opacity(0.5))
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.top, 34)
                    bottomNote
                        .padding(.top, 26)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 28)
                .padding(.top, 48)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .alert("寄送重設密碼信", isPresented: $showResetConfirm) {
            Button("寄送") { sendReset() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("會寄一封重設密碼信到 \(email.isEmpty ? "你的 email" : email)。確定要寄嗎？")
        }
    }

    private var bottomNote: some View {
        // 規則：Always 權限為什麼要，講清楚（放 scroll 內、鍵盤不會蓋住）
        Text("登入後會請求定位權限：背景回報需要「永遠」，會先要求使用期間再引導升級。")
            .font(.system(size: 12))
            .lineSpacing(3)
            .foregroundStyle(BearTheme.cream.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(BearTheme.honeyLight.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(BearTheme.honeyLight.opacity(0.2), lineWidth: 0.5))
            )
    }

    private var mascotHeader: some View {
        VStack(spacing: 14) {
            Image("BearMascot")
                .resizable()
                .scaledToFill()
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 44))
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
            VStack(spacing: 6) {
                Text("熊熊在哪裡")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(BearTheme.cream)
                    .kerning(1)
                (Text("這個 app 會在背景低頻地把你的位置，回報到")
                 + Text("你自己的").bold().foregroundStyle(BearTheme.honeyLight)
                 + Text("後端。"))
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundStyle(BearTheme.cream.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if session.state == .needsVerify {
            InlineNotice(kind: .warning, text: "請先驗證 email 才能繼續。",
                         actionTitle: "重寄驗證信") { session.resendVerification() }
        }
        if let err = session.lastError {
            InlineNotice(kind: .error, text: err) // 規則：訊息友善、不洩安全細節
        }
        if let info = session.infoMessage {
            InlineNotice(kind: .success, text: info)
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .signIn: "登入"
        case .signUp: "註冊"
        case .forgot: "寄送重設密碼信"
        }
    }

    private func submit() {
        if mode == .forgot { showResetConfirm = true; return }   // 寄信前先確認，免誤按燒 email quota
        Task {
            isLoading = true
            switch mode {
            case .signIn: await session.signIn(email: email, password: password)
            case .signUp: await session.signUp(email: email, password: password)
            case .forgot: break
            }
            isLoading = false
        }
    }

    private func sendReset() {
        Task { isLoading = true; await session.resetPassword(email: email); isLoading = false }
    }
}

#Preview {
    AuthScreen()
        .environment(SupabaseSession())
        .preferredColorScheme(.dark)
}
