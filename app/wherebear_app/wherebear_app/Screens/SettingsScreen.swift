// SettingsScreen.swift — 設定：頭貼（PhotosPicker→ProfileManager）／頻率／地標／金鑰／帳號／權限／隱私
// 綁 SupabaseSession＋LocationReporter＋ApiKeyManager＋ProfileManager＋LandmarkManager
import SwiftUI
import PhotosUI

struct SettingsScreen: View {
    @Environment(SupabaseSession.self) private var session
    @Environment(LocationReporter.self) private var reporter
    @Environment(ApiKeyManager.self) private var keyManager
    @Environment(ProfileManager.self) private var profile
    @Environment(LandmarkManager.self) private var landmarks
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var cropItem: CropItem? = nil
    @State private var editingName = false
    @State private var showChangePwConfirm = false

    struct CropItem: Identifiable { let id = UUID(); let image: UIImage }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("設定")
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(BearTheme.cream)
                        .padding(.horizontal, 6)

                    profileCard

                    section("回報") {
                        HStack {
                            Text("回報頻率").font(.system(size: 15.5)).foregroundStyle(BearTheme.cream)
                            Spacer()
                            FrequencyPicker(frequency: Binding(
                                get: { reporter.frequency },
                                set: { reporter.setFrequency($0) }
                            ))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }

                    section("地標") {
                        NavigationLink { LandmarksScreen() } label: {
                            row("我的地標", trailing: "\(landmarks.landmarks.count) 個", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    section("金鑰與帳號") {
                        NavigationLink { ApiKeysScreen() } label: {
                            row("API 金鑰", trailing: "\(keyManager.keys.count) 把", chevron: true)
                        }
                        .buttonStyle(.plain)
                        divider
                        Button { showChangePwConfirm = true } label: {
                            row("修改密碼", trailing: "寄重設信", chevron: true)
                        }
                        .buttonStyle(.plain)
                        divider
                        Button { session.signOut() } label: {
                            Text("登出")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(BearTheme.salmon)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                    }

                    section("系統權限") {
                        HStack {
                            Text("定位權限").font(.system(size: 15.5)).foregroundStyle(BearTheme.cream)
                            Spacer()
                            locationPermissionBadge
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        divider
                        row("相簿權限", trailing: "僅匯入時", chevron: false)
                    }

                    section("除錯") {
                        NavigationLink { OutboxDebugScreen() } label: {
                            // 兩個佇列各自顯示：停留卡住時位置點那格可能是 0、只看一個數字會漏
                            row("離線佇列", trailing: "地點 \(reporter.outboxCount) · 停留 \(reporter.visitOutboxCount)", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("分享位置給朋友").font(.system(size: 15.5)).foregroundStyle(BearTheme.cream)
                            Spacer()
                            Text("Phase 3")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(BearTheme.honeyLight)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(BearTheme.honeyLight.opacity(0.14))
                                        .overlay(Capsule().strokeBorder(BearTheme.honeyLight.opacity(0.35), lineWidth: 0.5))
                                )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .background(card)
                        .opacity(0.5)

                        Text("你的位置資料只會送到你自己設定的後端，不經過任何第三方服務。頭貼是公開展示照、與位置資料分開存放。")
                            .font(.system(size: 12))
                            .lineSpacing(4)
                            .foregroundStyle(BearTheme.cream.opacity(0.4))
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                    }

                    // 建置版本戳記（分辨手機上裝的是哪一版；可長按複製）
                    Text(BuildInfo.version)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(BearTheme.cream.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 10)
                        .textSelection(.enabled)
                }
                .padding(16)
                .padding(.bottom, 100)
            }
            .background(BearTheme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .alert("修改密碼", isPresented: $showChangePwConfirm) {
                Button("寄送重設信") { session.changePassword() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("會寄一封重設密碼信到你的 email，點信裡連結設定新密碼。確定要寄嗎？")
            }
            .sheet(isPresented: $editingName) {
                NameEditSheet(initial: profile.displayName ?? "") { newName in
                    Task { await profile.setDisplayName(newName) }
                }
            }
        }
    }

    // 主顯示身分：有暱稱用暱稱、否則 email
    private var displayIdentity: String {
        if let n = profile.displayName, !n.isEmpty { return n }
        return session.userEmail ?? "—"
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            AvatarButton(image: profile.avatarImage, url: profile.avatarURL, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Button { editingName = true } label: {
                    HStack(spacing: 5) {
                        Text(displayIdentity)
                            .font(.system(size: 16.5, weight: .bold))
                            .foregroundStyle(BearTheme.cream)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BearTheme.honeyLight.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                if let name = profile.displayName, !name.isEmpty {   // 有暱稱才另列 email 小字
                    Text(session.userEmail ?? "")
                        .font(.system(size: 12)).foregroundStyle(BearTheme.cream.opacity(0.5)).lineLimit(1)
                }
                Text(session.emailVerified ? "email 已驗證 ✓" : "email 未驗證")
                    .font(.system(size: 12))
                    .foregroundStyle(session.emailVerified ? BearTheme.green : BearTheme.amberText)
            }
            Spacer()
            // 頭貼流程：PhotosPicker → ProfileManager.setAvatar（上傳 public avatars bucket）
            PhotosPicker(selection: $avatarItem, matching: .images) {
                Text("更換頭貼")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BearTheme.honeyLight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(card)
        .onChange(of: avatarItem) {
            Task {
                if let data = try? await avatarItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    cropItem = CropItem(image: image) // 先進圓形裁切再上傳
                }
            }
        }
        .sheet(item: $cropItem) { item in
            CircleCropSheet(image: item.image) { cropped in
                Task { await profile.setAvatar(cropped) }
            }
        }
    }

    @ViewBuilder private var locationPermissionBadge: some View {
        switch reporter.permissionState {
        case .always:
            Text("永遠 ✓").font(.system(size: 14, weight: .semibold)).foregroundStyle(BearTheme.green)
        default:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("不足 · 前往設定")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BearTheme.amberText)
                    .underline()
            }
        }
    }

    private func section(_ header: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header)
                .font(.system(size: 12.5, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(BearTheme.cream.opacity(0.45))
                .padding(.horizontal, 10)
            VStack(spacing: 0, content: content).background(card)
        }
    }

    private func row(_ title: String, trailing: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15.5)).foregroundStyle(BearTheme.cream)
            Spacer()
            Text(trailing).font(.system(size: 13.5)).foregroundStyle(BearTheme.cream.opacity(0.5))
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BearTheme.cream.opacity(0.3))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 16)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(BearTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

// 離線佇列除錯（唯讀窺看：回線會自動補送，這裡只看目前積了哪些）。走 navigation push（非 modal）。
// 兩個佇列分頁顯示 —— 不做兩層 push（除錯頁多半兩邊都 0、多點一次才知道沒事）、
// 也不放同一頁兩段（位置點上限 1000 筆會把停留埋在下面，而停留才是有價值的那個）。
private struct OutboxDebugScreen: View {
    @Environment(LocationReporter.self) private var reporter
    @State private var tab = 0
    @State private var points: [(lat: Double, lng: Double, at: String)] = []
    @State private var visits: [(arrived: String, departed: String?, lat: Double, lng: Double)] = []

    var body: some View {
        VStack(spacing: 0) {
            DateChips(items: ["地點 (\(points.count))", "停留 (\(visits.count))"], selected: $tab)
                .padding(.top, 8).padding(.bottom, 12)
            List {
                if tab == 0 { pointRows } else { visitRows }
            }
            .scrollContentBackground(.hidden)
            .refreshable { reload() }   // 下拉刷新：重讀佇列
        }
        .background(BearTheme.bg)
        .navigationTitle("離線佇列（\(points.count + visits.count)）")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func reload() {
        points = reporter.outboxPeek()
        visits = reporter.visitOutboxPeek()
    }

    @ViewBuilder private var pointRows: some View {
        if points.isEmpty {
            emptyRow("沒有待補送的位置點。")
        } else {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.5f, %.5f", p.lat, p.lng))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(BearTheme.cream)
                    Text(p.at).font(.system(size: 11)).foregroundStyle(BearTheme.cream.opacity(0.5))
                }
                .listRowBackground(BearTheme.surface)
            }
        }
    }

    @ViewBuilder private var visitRows: some View {
        if visits.isEmpty {
            emptyRow("沒有待補送的停留。")
        } else {
            ForEach(Array(visits.enumerated()), id: \.offset) { _, v in
                VStack(alignment: .leading, spacing: 2) {
                    Text("到達 \(v.arrived)")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(BearTheme.cream)
                    // 有離開時間＝這筆是「離開」那次投遞；沒有＝到達那次，還在停留中
                    Text(v.departed.map { "離開 \($0)" } ?? "離開 — 仍在停留中")
                        .font(.system(size: 11)).foregroundStyle(BearTheme.cream.opacity(0.5))
                    Text(String(format: "%.5f, %.5f", v.lat, v.lng))
                        .font(.system(size: 11)).foregroundStyle(BearTheme.cream.opacity(0.5))
                }
                .listRowBackground(BearTheme.surface)
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text("佇列是空的 — \(text)")
            .font(.system(size: 14)).foregroundStyle(BearTheme.cream.opacity(0.5))
            .listRowBackground(BearTheme.surface)
    }
}

// 暱稱編輯 sheet：輸入顯示名稱 → ProfileManager.setDisplayName。留空＝清除、顯示回 email。
private struct NameEditSheet: View {
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("這個名字會顯示在設定頁；未來也會給你分享位置的好友看到。留空則顯示 email。")
                    .font(.system(size: 13)).lineSpacing(3)
                    .foregroundStyle(BearTheme.cream.opacity(0.6))
                TextField("", text: $text, prompt: Text("顯示名稱").foregroundStyle(BearTheme.cream.opacity(0.35)))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BearTheme.cream)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14).fill(BearTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    )
                    .submitLabel(.done)
                    .onSubmit { save() }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BearTheme.bg)
            .navigationTitle("編輯名稱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("儲存") { save() } }
            }
            .onAppear { text = initial }
        }
        .presentationDetents([.height(260)])
    }
    private func save() { onSave(text); dismiss() }
}

#Preview {
    SettingsScreen()
        .environment(SupabaseSession())
        .environment(LocationReporter())
        .environment(ApiKeyManager())
        .environment(ProfileManager())
        .environment(LandmarkManager())
        .preferredColorScheme(.dark)
}
