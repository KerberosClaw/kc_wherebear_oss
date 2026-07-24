// AvatarButton.swift — 角落使用者頭貼（pikmin 參考）
// v3：拆成 AvatarView（純視覺，可當 Menu label）＋ AvatarButton（薄 Button 殼，設定頁換頭貼用）
// born-clean：預設＝通用熊 asset；個人頭貼＝用戶資料（Supabase public avatars bucket）
import SwiftUI

// 純視覺頭貼：地圖頁包進 Menu 當 label、設定頁包進 Button 換圖。
struct AvatarView: View {
    var image: UIImage? = nil   // 剛換的頭貼（樂觀即時顯示、免等網路）
    var url: URL? = nil
    var size: CGFloat = 42

    var body: some View {
        avatar
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(BearTheme.honeyLight.opacity(0.7), lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 9, y: 3)
    }

    @ViewBuilder private var avatar: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image("BearMascot").resizable().scaledToFill()
    }
}

// 點擊型頭貼（設定頁：按了開換圖 sheet）。API 與舊版一致 → 呼叫端不動。
struct AvatarButton: View {
    var image: UIImage? = nil
    var url: URL? = nil
    var size: CGFloat = 42
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            AvatarView(image: image, url: url, size: size)
        }
        .buttonStyle(.plain)
    }
}
