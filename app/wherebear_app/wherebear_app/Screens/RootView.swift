// RootView.swift — 入口：auth gate ＋ 3 tab（地圖／時間軸／設定）＋ 啟動 splash（沿用 LaunchImage、皮克敏式進度條）
// iOS 26：原生 TabView 重編譯即自動套 Liquid Glass 浮動 tab bar，不自己刻
import SwiftUI

enum AppTab: Hashable { case map, timeline, settings }

struct RootView: View {
    @Environment(SupabaseSession.self) private var session
    @Environment(LocationReporter.self) private var reporter
    @Environment(\.scenePhase) private var scenePhase
    @State private var splashDone = false
    @State private var splashProgress: Double = 0

    var body: some View {
        Group {
            if session.state == .restoring || !splashDone {
                SplashView(progress: splashProgress).transition(.opacity)   // 沿用同一張 LaunchImage → 靜態啟動圖無縫接續
            } else if session.state == .loggedIn {
                MainTabView()                                                // 登入後直接進地圖 tab
            } else {
                AuthScreen()
            }
        }
        .preferredColorScheme(.dark)
        .task {   // 啟動 splash：進度條 0→1 + 卡 Config.splashSeconds 秒才進主畫面（金句輪播讓等待「有東西看」而無感）。
                  // 秒數走 Config.splashSeconds（本機 8；開源版可調短、設 0 跳過）。續登若更久則等續登完成。
            if Config.splashSeconds > 0 {
                withAnimation(.easeInOut(duration: Config.splashSeconds)) { splashProgress = 1 }
                try? await Task.sleep(for: .seconds(Config.splashSeconds))
            } else {
                splashProgress = 1
            }
            withAnimation(.easeOut(duration: 0.4)) { splashDone = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reporter.onEnterForeground() }  // 回前景：立刻補位置 + 補送離線佇列
        }
    }
}

// 啟動載入畫面：全幅 LaunchImage 背景 + 底部 scrim（金草上文字才讀得清）+ 標題（cream、非紅）+ 皮克敏式斜紋進度條
struct SplashView: View {
    var progress: Double
    @State private var titleIn = false
    @State private var tagline = Taglines.random()   // 每次啟動隨機挑一句氛圍小字
    @State private var taglineOpacity: Double = 1

    var body: some View {
        ZStack {
            GeometryReader { geo in     // 匹配 LaunchScreen storyboard 的 scaleAspectFill 全出血 → 切換無縫、不跳
                Image("LaunchImage")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Text("熊熊在哪裡")
                    .font(.system(size: 52, weight: .heavy))
                    .tracking(6)
                    .foregroundStyle(BearTheme.cream)
                    .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
                    .padding(.top, 100)
                    .opacity(titleIn ? 1 : 0)
                    .scaleEffect(titleIn ? 1 : 0.86)
                    .offset(y: titleIn ? 0 : -26)
                Spacer()
                VStack(spacing: 10) {
                    Text(tagline)                                    // 氛圍小字：完整淡出→換字→淡入（無重疊、銜接乾淨）
                        .opacity(taglineOpacity)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(BearTheme.cream.opacity(0.95))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 4)
                    StripedProgressBar(progress: progress)
                        .frame(height: 11)
                        .padding(.horizontal, 44)
                    Text("正在登入……")                              // 狀態（小、暗一點）
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BearTheme.cream.opacity(0.7))
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                }
                .padding(.bottom, 64)
            }
        }
        .task {
            withAnimation(.spring(response: 1.1, dampingFraction: 0.7)) { titleIn = true }   // 更明顯：彈一下 + 放大 + 下滑
            while !Task.isCancelled {                                        // 氛圍小字：顯示 → 淡出 → 換字(全透明) → 淡入
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeInOut(duration: 0.35)) { taglineOpacity = 0 }
                try? await Task.sleep(for: .seconds(0.35))
                tagline = Taglines.random()
                withAnimation(.easeInOut(duration: 0.35)) { taglineOpacity = 1 }
                try? await Task.sleep(for: .seconds(0.35))
            }
        }
    }
}

// 皮克敏式斜紋進度條（棕/honey 調）：淺色 track + honey 填充 + 45° 斜紋
struct StripedProgressBar: View {
    var progress: Double
    private var p: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(BearTheme.cream.opacity(0.22))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                ZStack {
                    BearTheme.honey
                    stripes
                }
                .frame(width: geo.size.width * p)
                .clipShape(Capsule())
            }
        }
    }

    private var stripes: some View {
        Canvas { ctx, sz in
            let w: CGFloat = 8
            var x = -sz.height
            while x < sz.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: sz.height))
                path.addLine(to: CGPoint(x: x + sz.height, y: 0))
                path.addLine(to: CGPoint(x: x + sz.height + w, y: 0))
                path.addLine(to: CGPoint(x: x + w, y: sz.height))
                path.closeSubpath()
                ctx.fill(path, with: .color(BearTheme.honeyLight.opacity(0.5)))
                x += w * 2
            }
        }
    }
}

struct MainTabView: View {
    @Environment(ProfileManager.self) private var profile
    @Environment(LandmarkManager.self) private var landmarks
    @Environment(ApiKeyManager.self) private var keys
    @State private var tab: AppTab = .map
    @State private var recenterTick = 0

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("地圖", systemImage: "map.fill", value: AppTab.map) { MapHomeScreen(recenterTick: recenterTick) }
            Tab("時間軸", systemImage: "clock.fill", value: AppTab.timeline) { TimelineScreen() }
            Tab("設定", systemImage: "gearshape.fill", value: AppTab.settings) { SettingsScreen() }
        }
        .tint(BearTheme.honeyLight)
        .task { // 登入後集中重載（各 manager 在 init 時還沒 token → 這裡補載頭貼/地標/金鑰）
            await profile.load()
            await landmarks.load()
            await keys.load()
        }
        .alert("沒存成功", isPresented: Binding(
            get: { landmarks.lastError != nil },
            set: { if !$0 { landmarks.lastError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: { Text(landmarks.lastError ?? "") }
    }

    // 切到（或從別 tab 回到）地圖 tab → recenterTick +1 → 地圖置中回 user。
    // 註：SwiftUI TabView 對「已選中 tab 再點一下」不回呼 selection setter → 同 tab 重點不觸發（已知限制）；
    // 跨 tab 切回可靠觸發，地圖上另可用熊掌點兩下回正北置中。
    private var tabSelection: Binding<AppTab> {
        Binding(get: { tab }, set: { newValue in
            if newValue == .map { recenterTick += 1 }
            tab = newValue
        })
    }
}

#Preview("已登入") {
    let session = SupabaseSession()
    session.state = .loggedIn
    return RootView()
        .environment(session)
        .environment(LocationReporter())
        .environment(LocationVM())
        .environment(PhotoImporter())
        .environment(ApiKeyManager())
        .environment(ProfileManager())
        .environment(LandmarkManager())
}
