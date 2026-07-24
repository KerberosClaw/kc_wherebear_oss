// MapHomeScreen.swift — 地圖首頁（mockup 1b：熊掌浮鈕）
// 綁 LocationReporter＋LocationVM＋ProfileManager（頭貼）＋LandmarkManager（長停留命名卡＝入口①）＋SupabaseSession（頭貼選單＝入口②）
import SwiftUI
import MapKit

struct MapHomeScreen: View {
    @Environment(LocationReporter.self) private var reporter
    @Environment(LocationVM.self) private var vm
    @Environment(ProfileManager.self) private var profile
    @Environment(LandmarkManager.self) private var landmarks
    @Environment(SupabaseSession.self) private var session

    var recenterTick: Int = 0   // MainTabView：切到地圖 tab 就 +1 → 置中回 user

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var followMode: FollowMode = .followNorth   // 預設＝跟隨+正北（熊掌釘中間、地圖跟著移）
    @State private var currentDistance: Double = 1000          // 追蹤當前縮放（pinch）→ 用在脫離門檻/fallback
    @State private var settling = false                        // 剛 re-engage 跟隨、相機還在飛回自己 → 期間不判定脫離
    @State private var naming: NamingTarget? = nil

    // followNorth＝跟隨+正北（預設）；followHeading＝跟隨+羅盤旋轉（點熊掌切）；free＝使用者拖走、不跟隨（顯示「回到我」）
    enum FollowMode { case followNorth, followHeading, free }
    private var isFollowing: Bool { followMode != .free }

    struct NamingTarget: Identifiable {
        let id = UUID()
        var coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        ZStack {
            Map(position: $camera) {
                UserAnnotation {
                    PawPinView(active: followMode == .followHeading) { cycleTracking() } // 點熊掌＝同追蹤鈕、循環三態
                }
            }
            .mapControls { }   // 隱藏系統內建控制（轉向時不再冒出右上角羅盤）
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .continuous) { ctx in
                currentDistance = ctx.camera.distance                    // 記住縮放（pinch）→ zoom 不被鎖
                guard let loc = reporter.lastLocation?.coordinate else { return }
                let off = distanceMeters(ctx.camera.centerCoordinate, loc)
                if settling {                                            // 相機還在飛回自己 → 別誤判成脫離
                    if off < currentDistance * 0.07 { settling = false } // 貼回自己了、恢復偵測
                    return
                }
                // 原生跟隨時相機貼著自己（off≈0）；手指把地圖拖離自己（>15% 視野）就脫離、冒出回到我；純縮放中心仍貼著自己、不脫離。
                if isFollowing, off > currentDistance * 0.15 { followMode = .free }
            }
            .ignoresSafeArea()

            // 頂部：地名卡＋狀態 pill（左）、頭貼選單（右）
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        if hasLocationCard {
                            LocationNameCard(name: displayName)
                        }
                        StatusPill(status: primaryStatus, onOpenSettings: openSystemSettings)
                        if case .reporting = primaryStatus, let cur = vm.current, cur.isStale {
                            StatusPill(status: .stale(staleText(cur)))
                        }
                    }
                    Spacer()
                    avatarMenu
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                Spacer()
            }

            if vm.current == nil && reporter.lastLocation == nil {
                EmptyStateBear(title: "熊熊還不知道你在哪裡",
                               message: "點右下角的熊掌開始回報，足跡就會出現在這裡。")
                    .padding(.horizontal, 44)
            }

            // 底部：長停留命名卡（左）＋熊掌開關（右下）
            VStack {
                Spacer()
                if let pending = landmarks.pendingLongStay {
                    LongStayPromptCard(
                        onName: {
                            landmarks.dismissLongStay()
                            naming = NamingTarget(coordinate: pending)
                        },
                        onSkip: { landmarks.dismissLongStay() }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack {
                    Spacer()
                    VStack(spacing: 12) {   // 右下角：熊掌開始鈕 + 其下 Apple 式常駐追蹤鈕（三態循環）
                        PawReportButton(isOn: reporter.isReporting) {
                            reporter.isReporting ? reporter.stop() : reporter.start()
                        }
                        Button { cycleTracking() } label: {   // 空心=不跟 / 實心=跟隨正北 / 北箭頭=跟隨+羅盤
                            Image(systemName: trackingIcon)
                                .font(.system(size: 16, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .foregroundStyle(followMode == .free ? BearTheme.cream.opacity(0.65) : BearTheme.honeyLight)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(BearTheme.surface)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)))
                                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 14)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: landmarks.pendingLongStay != nil)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: followMode)
        }
        .background(BearTheme.bg)
        .task { await vm.refreshCurrent() } // 登入後（token 就緒）載入當前位置/名稱（不動時間軸選擇）
        .onChange(of: reporter.lastReportAt) { Task { await vm.refreshCurrent() } } // 回報後刷新地名卡/新鮮度
        .onChange(of: recenterTick) { recenter() }                              // 切回地圖 tab → 重新跟隨+置中
        .onAppear { reporter.startHeadingUpdates(); reporter.startLiveUpdates(); reporter.primeLocation(); applyFollow() }   // 進地圖：開羅盤 + 即時位置流 + seed + 啟動原生跟隨
        .onDisappear { reporter.stopHeadingUpdates(); reporter.stopLiveUpdates() }
        .sheet(item: $naming) { target in
            LandmarkFormSheet(coordinate: target.coordinate)
        }
    }

    // MARK: - 頭貼選單（入口②：email／登出／未來找朋友）。設定 tab 仍保留。
    private var avatarMenu: some View {
        Menu {
            if let email = session.userEmail {
                Section(email) { menuItems }
            } else {
                menuItems
            }
        } label: {
            AvatarView(image: profile.avatarImage, url: profile.avatarURL, size: 76)  // 放大＋頂對齊左側兩張卡
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button { } label: { Label("找朋友 · 即將推出", systemImage: "person.2.fill") }
            .disabled(true)
        Button(role: .destructive) { session.signOut() } label: {
            Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
        }
    }

    // MARK: - 熊掌跟隨（Apple Maps 式三態循環：不跟 → 跟隨正北 → 跟隨+羅盤 → 不跟）
    // 點右下追蹤鈕（或熊掌）循環一格；手指拖離地圖 → 自動掉回「不跟」。
    private func cycleTracking() {
        switch followMode {
        case .free:          followMode = .followNorth;  applyFollow()   // 不跟 → 跟隨(正北、置中)
        case .followNorth:   followMode = .followHeading; applyFollow()   // → 跟隨+羅盤旋轉
        case .followHeading: followMode = .free;          freeze()        // → 停止跟隨(定住、轉回正北)
        }
    }

    // 追蹤鈕圖示（比照 Apple：空心=不跟、實心=跟隨正北、北箭頭=跟隨+羅盤）
    private var trackingIcon: String {
        switch followMode {
        case .free:          return "location"
        case .followNorth:   return "location.fill"
        case .followHeading: return "location.north.line.fill"
        }
    }

    // 跟隨：直接原生（順、不頓），交 MapKit 連續平滑追蹤。followNorth 正北 / followHeading 跟行進向旋轉。
    private func applyFollow() {
        guard isFollowing else { return }
        settling = true
        let fallback: MapCameraPosition = reporter.lastLocation.map {
            .region(MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 1200, longitudinalMeters: 1200))
        } ?? .automatic
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .userLocation(followsHeading: followMode == .followHeading, fallback: fallback)
        }
    }

    // 停止跟隨（.free）：定住成靜態相機（正北、置中當前位置）→ 之後移動不再跟。
    // 從 followHeading 過來也轉回正北，使下一次「不跟→跟隨」天生就是北、免手動 snap（那會頓）。
    private func freeze() {
        guard let loc = reporter.lastLocation?.coordinate else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            camera = .camera(MapCamera(centerCoordinate: loc, distance: currentDistance, heading: 0, pitch: 0))
        }
    }

    // 切回地圖 tab：重新跟隨 + 正北 + 置中
    private func recenter() {
        followMode = .followNorth
        applyFollow()
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // MARK: - 地名卡
    // 座標卡 bug（req 7）：resolved 地名走 DB（vm.current、有 lag），但「座標」用 reporter.lastLocation 即時值，
    // 與熊掌（UserAnnotation 系統定位）同步、移動時會更新，不再顯示落後的 DB 座標。
    private var hasLocationCard: Bool { vm.current != nil || reporter.lastLocation != nil }

    private var displayName: String {
        if let name = vm.current?.resolvedName, !name.isEmpty { return name }
        if let loc = reporter.lastLocation { return coordString(loc.coordinate) }
        if let cur = vm.current { return coordString(cur.coordinate) }
        return "定位中…"
    }

    private func coordString(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    private var primaryStatus: ReportStatus {
        if reporter.permissionState == .denied || reporter.permissionState == .notDetermined {
            return .permissionInsufficient
        }
        if reporter.connectivity == .offline { return .offline }
        if reporter.isReporting {
            return .reporting(last: relative(reporter.lastReportAt), frequency: reporter.frequency.label)
        }
        return .stopped
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let mins = max(0, Int(Date.now.timeIntervalSince(date) / 60))
        return mins < 1 ? "剛剛" : "\(mins) 分前"
    }

    private func staleText(_ cur: CurrentLocation) -> String {
        let mins = max(0, Int(Date.now.timeIntervalSince(cur.capturedAt) / 60))
        return "\(mins) 分前"
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

#Preview {
    MapHomeScreen()
        .environment(LocationReporter())
        .environment(LocationVM())
        .environment(ProfileManager())
        .environment(LandmarkManager())
        .environment(SupabaseSession())
        .preferredColorScheme(.dark)
}
