// ApiKeysScreen.swift — API 金鑰子頁（4a）：列表／建立（命名→一次性明文）／撤銷
// v2：對齊契約 §1.4 —— revoke 走 server id；遮罩／相對時間在顯示層組
import SwiftUI

struct ApiKeysScreen: View {
    @Environment(ApiKeyManager.self) private var manager
    @State private var naming = false
    @State private var newName = ""
    @State private var created: CreatedKey? = nil
    @State private var revoking: ApiKey? = nil

    struct CreatedKey: Identifiable {
        let id = UUID()
        var name: String
        var plaintext: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("給你自己的工具讀你位置用的金鑰。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))
                    .padding(.horizontal, 6)

                if manager.keys.isEmpty {
                    EmptyStateBear(title: "還沒有金鑰",
                                   message: "建一把，讓你自己的儀表板或捷徑讀你的位置。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.keys) { key in
                            ApiKeyRow(apiKey: key) { revoking = key }
                            if key.id != manager.keys.last?.id {
                                Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5).padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .fill(BearTheme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    )
                }

                Button { naming = true } label: {
                    Text("＋ 建立新金鑰")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BearTheme.honeyLight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(BearTheme.honeyLight.opacity(0.45), style: .init(lineWidth: 1.5, dash: [6, 5]))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .padding(.bottom, 100)
        }
        .refreshable { await manager.load() }   // 下拉刷新
        .task { await manager.load() }          // 進頁重抓 → 修「上次使用」不刷新（原本只在登入抓一次）
        .background(BearTheme.bg)
        .navigationTitle("API 金鑰")
        .navigationBarTitleDisplayMode(.large)
        .alert("命名這把金鑰", isPresented: $naming) {
            TextField("例如：家用儀表板", text: $newName)
            Button("產生") {
                let name = newName.isEmpty ? "未命名" : newName
                created = CreatedKey(name: name, plaintext: manager.create(name: name))
                newName = ""
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之後在列表用這個名字認它。")
        }
        .confirmationDialog("撤銷「\(revoking?.name ?? "")」？",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible) {
            Button("撤銷（立即失效）", role: .destructive) {
                if let key = revoking { manager.revoke(id: key.id) }
                revoking = nil
            }
        } message: {
            Text("用這把金鑰的工具會立刻讀不到位置。")
        }
        .fullScreenCover(item: $created) { key in
            NewKeyModal(name: key.name, plaintext: key.plaintext) { created = nil }
                .presentationBackground(.clear)
        }
    }
}

#Preview {
    NavigationStack { ApiKeysScreen() }
        .environment(ApiKeyManager())
        .preferredColorScheme(.dark)
}
