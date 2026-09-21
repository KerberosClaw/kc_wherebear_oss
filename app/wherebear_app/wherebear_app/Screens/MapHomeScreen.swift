// MapHomeScreen.swift — 地圖首頁（mockup 1b：熊掌浮鈕）
// 綁 LocationReporter＋LocationVM＋ProfileManager（頭貼）＋LandmarkManager（長停留命名卡＝入口①）＋SupabaseSession（頭貼選單＝入口②）
import SwiftUI
import MapKit

struct MapHomeScreen: View {
    @Environment(LocationReporter.self) private var reporter
    @Environment(LocationVM.self) private var vm
    @Environment(LandmarkManager.self) private var landmarks

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

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.adaptiveControlRail) private var controlRail

    var body: some View {
        GeometryReader { geo in
            let layout = AdaptiveMapLayout(geo, regular: sizeClass == .regular, controlRail: controlRail)
            let compactControls = layout.compactOverlay || sizeClass == .regular || layout.divided
            let controlArea = layout.divided ? layout.panel : layout.contentBounds
            let informationArea = layout.mode == .book ? layout.panel
                : (layout.mode == .laptop ? layout.map : layout.contentBounds)
            // On the inner display the system status controls occupy the right.
            // Keep the left information group near the physical top edge.
            let informationTopOffset = compactControls && !layout.compactOverlay
                ? -max(0, geo.safeAreaInsets.top - 12) : 0
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
                .safeAreaInset(edge: .leading, spacing: 0) {
                    Color.clear.frame(width: layout.mode == .book ? layout.map.minX : 0)
                        .allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: layout.mode == .laptop ? layout.bounds.height - layout.map.maxY : 0)
                        .allowsHitTesting(false)
                }
                .layoutFrame(layout.bounds)

                // 窄視窗的資訊與控制一起靠向系統側欄的另一側。
                VStack {
                    HStack(alignment: .top, spacing: 12) {
                        if compactControls && !layout.compactOverlay { ProfileMenu(size: 44) }
                        VStack(alignment: layout.controlsOnTrailingEdge ? .trailing : .leading, spacing: 8) {
                            if hasLocationCard {
                                LocationNameCard(name: displayName)
                            }
                            StatusPill(status: primaryStatus, onOpenSettings: openSystemSettings)
                            if case .reporting = primaryStatus, let cur = vm.current, cur.isStale {
                                StatusPill(status: .stale(staleText(cur)))
                            }
                        }
                        .frame(maxWidth: layout.split ? 360 : .infinity,
                               alignment: layout.controlsOnTrailingEdge ? .trailing : .leading)
                        if !layout.controlsOnTrailingEdge { Spacer(minLength: 0) }
                        if !compactControls { ProfileMenu(size: 76) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, layout.compactOverlay ? layout.topInset + 8 : (compactControls ? 16 : 6))
                    Spacer()
                }

                .layoutFrame(informationArea)
                .offset(y: informationTopOffset)

                if vm.current == nil && reporter.lastLocation == nil {
                    EmptyStateBear(title: "熊熊還不知道你在哪裡",
                                   message: "點熊掌開始回報，足跡就會出現在這裡。")
                        .padding(.horizontal, 44)
                        .layoutFrame(layout.divided ? layout.map : layout.contentBounds)
                }

                // 窄視窗避開側邊導覽列；寬視窗仍靠左，一般手機保留右下排列。
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
                        if !compactControls || layout.controlsOnTrailingEdge { Spacer() }
                        let controls = compactControls
                            ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                            : AnyLayout(VStackLayout(spacing: 12))
                        controls {   // 回報與定位切換維持同一組
                            PawReportButton(isOn: reporter.isReporting, compact: compactControls) {
                                reporter.isReporting ? reporter.stop() : reporter.start()
                            }
                            trackingControl(compact: compactControls)

                        }
                        if compactControls && !layout.controlsOnTrailingEdge { Spacer() }
                    }
                    .padding(.leading, compactControls ? 16 : 0)
                    .padding(.trailing, compactControls ? 16 : 20)
                    .padding(.bottom, 14)
                }
                .layoutFrame(controlArea)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: landmarks.pendingLongStay != nil)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: followMode)
                ReservedInteractionShield(layout: layout)
            }
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

    private func trackingControl(compact: Bool) -> some View {
        VStack(spacing: 7) {
            Button { cycleTracking() } label: {
                Image(systemName: trackingIcon)
                    .font(.system(size: compact ? 20 : 16, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(followMode == .free ? BearTheme.cream.opacity(0.65) : BearTheme.honeyLight)
                    .frame(width: compact ? 56 : 44, height: compact ? 56 : 44)
                    .background(Circle().fill(BearTheme.surface)
                        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)))
                    .frame(width: compact ? 64 : 44, height: compact ? 64 : 44)
                    .contentShape(Circle())
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定位切換")
            .accessibilityValue(trackingLabel)
            if compact {
                Text(trackingLabel)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(BearTheme.cream)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .glassEffect(.regular.tint(BearTheme.surfaceHi.opacity(0.6)), in: .capsule)
            }
        }
    }

    private var trackingLabel: String {
        switch followMode {
        case .free: "回到我"
        case .followNorth: "正北跟隨"
        case .followHeading: "羅盤跟隨"
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
