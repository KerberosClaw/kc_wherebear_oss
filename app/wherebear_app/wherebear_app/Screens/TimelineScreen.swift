// TimelineScreen.swift — 時間軸：軌跡地圖＋可拖曳 stays 面板＋相簿匯入＋stay 命名（地標入口②）
// 綁 LocationVM（選擇狀態集中在 VM → 切 tab 保留）＋ PhotoImporter ＋ LandmarkManager
import SwiftUI
import MapKit

struct TimelineScreen: View {
    @Environment(LocationVM.self) private var vm
    @Environment(LandmarkManager.self) private var landmarks
    @Environment(LocationReporter.self) private var reporter
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)  // 空狀態（沒足跡）以 user 位置置中，不再框到世界圖
    @State private var detent: SheetDetent = .half
    @State private var showImport = false
    @State private var namingStay: Stay? = nil
    @State private var selectedStayID: UUID? = nil
    @State private var didInitialFit = false
    // 選日期兩入口（時間區間 / 行事曆多選）
    @State private var showDateOptions = false
    @State private var showCalendar = false
    @State private var showRange = false
    @State private var calSelected: Set<String> = []   // 月曆選取（yyyy-MM-dd）
    @State private var calRecorded: Set<String> = []   // 該月有記錄的日
    @State private var calMonth = Date()
    @State private var rangeFrom = Date()
    @State private var rangeTo = Date()
    @State private var rangeMonth = Date()
    private enum RangeEndpoint { case from, to }
    @State private var rangeEndpoint: RangeEndpoint = .from

    private var selectedStay: Stay? { vm.todayStays.first { $0.id == selectedStayID } }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.adaptiveControlRail) private var controlRail
    @State private var listCollapsed = false
    @State private var splitMap = false
    @State private var listScrollOffset: CGFloat = 0
    @State private var mapHeaderHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let layout = AdaptiveMapLayout(geo, regular: sizeClass == .regular,
                                           collapsed: listCollapsed, controlRail: controlRail)
            ZStack(alignment: .topLeading) {
                mapPane(layout, topInset: geo.safeAreaInsets.top)
                    .layoutFrame(layout.mapCanvas)
                timelinePanel(layout, bottomInset: geo.safeAreaInsets.bottom)
                    .layoutFrame(CGRect(x: layout.panel.minX, y: layout.panel.minY,
                                        width: layout.panel.width,
                                        height: layout.panel.height + (layout.split ? geo.safeAreaInsets.bottom : 0)))
                    .opacity(layout.mode == .wide && listCollapsed ? 0 : 1)
                    .allowsHitTesting(!(layout.mode == .wide && listCollapsed))
                    .accessibilityHidden(layout.mode == .wide && listCollapsed)
                if showImport && layout.split {
                    modalScrim { showImport = false }
                        .clipped()
                        .layoutFrame(panelBackdrop(layout, insets: geo.safeAreaInsets))
                        .zIndex(10)
                    PhotoImportSheet(onImported: { _ in Task { await vm.reloadStays() } },
                                     prefersColumns: layout.mode == .laptop,
                                     onClose: { showImport = false })
                        .background(layout.mode == .laptop ? Color.clear : BearTheme.sheet)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .padding(12)
                        .layoutFrame(layout.panel)
                        .zIndex(11)
                }
                ReservedInteractionShield(layout: layout).zIndex(20)
                if showRange || showCalendar {
                    if layout.split {
                        modalScrim { closeModals() }
                            .clipped()
                            .layoutFrame(panelBackdrop(layout, insets: geo.safeAreaInsets))
                            .zIndex(10)
                    } else {
                        modalScrim { closeModals() }.ignoresSafeArea().zIndex(10)
                    }
                    dateDialog(layout)
                        .layoutFrame(layout.split ? layout.panel : layout.contentBounds)
                        .zIndex(11)
                }
            }
            .onChange(of: layout, initial: true) { previous, value in
                splitMap = value.split
                // An edge reservation changes foreground clearance, not the
                // map viewport. Preserve the user's zoom and selected stay.
                if didInitialFit && value.needsMapRefit(comparedTo: previous) {
                    if let stay = selectedStay { select(stay) }
                    else { applyFit(collapse: false) }
                }
                if value.divided { listCollapsed = false }
            }
        }
        .background(BearTheme.sheet.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { showImport && !splitMap },
                                    set: { showImport = $0 })) {
            PhotoImportSheet(onImported: { _ in Task { await vm.reloadStays() } })
        }
        .sheet(item: $namingStay) { stay in
            if let c = stay.coordinate {
                // 已在某地標範圍內 → 開「編輯」那個地標（改名／拉大範圍），不再重建（避免重疊警告 + 重複地標）
                let existing = landmarks.resolvePreview(c)
                LandmarkFormSheet(coordinate: existing?.coordinate ?? c,
                                  suggestedName: (stay.isLowConfidence || stay.name == "未命名地點") ? "" : stay.name,
                                  editing: existing,
                                  onSaved: { _ in reapplyAliases() },   // 樂觀更新：畫面先跟上
                                  // 真的落地之後才做人為指定 —— 要拿 server id，也要確保
                                  // 它跑在自動重判之前（否則感測器可能先定案，人講的話就輸了）
                                  onPersisted: { saved in assignNamedStay(stay, to: saved) })
            }
        }
        .task {
            reporter.primeLocation()             // seed 即時位置 → 空狀態熊掌能置中回正北
            await vm.reloadStays()               // 進頁：依 VM 目前選擇載入（不強制今天）
            if !didInitialFit { didInitialFit = true; applyFit(collapse: false) } // 初次框景（有最小縮放，不爆大）
        }
        .onChange(of: reporter.lastReportAt) { Task { await vm.reloadStays() } }   // B4：回報寫入即刷新軌跡線/停留（邊看邊長、免切頁）；用本地 lastReportAt 信號、非 Realtime
    }

    private var dateChips: some View {
        DateChips(items: ["今天", "選日期"],
                  selected: .constant(vm.selectedDays.isEmpty ? 0 : 1), onTap: onDateChipTap)
            .popover(isPresented: $showDateOptions) { optionsPopover }
    }

    private func toggleList() { withAnimation { listCollapsed.toggle() } }

    private func mapPane(_ layout: AdaptiveMapLayout, topInset: CGFloat) -> some View {
        ZStack {
            Map(position: $camera) {
                let coords = vm.todayStays.compactMap(\.coordinate)
                if coords.count > 1 {
                    MapPolyline(coordinates: coords)
                        .stroke(BearTheme.honey, style: .init(lineWidth: 3, lineCap: .round, dash: [1, 12]))
                }
                // live 移動軌跡（選定單日）：原始 live 點直接連。用 salmon 珊瑚色實線 —— 避開 Apple 地圖道路的藍灰色（會搞混），
                // 與停留/匯入的 honey 橘虛線用「實 vs 虛」再區隔。
                if vm.livePoints.count > 1 {
                    MapPolyline(coordinates: vm.livePoints)
                        .stroke(BearTheme.salmon, style: .init(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(vm.todayStays) { stay in
                    if let c = stay.coordinate {
                        Annotation("", coordinate: c) {
                            Button { select(stay) } label: { stayMarker(index: globalIndex(stay), stay: stay) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .mapControls { }   // 隱藏系統羅盤（轉向時不再冒出、也不會被面板遮）
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .ignoresSafeArea(edges: layout.split ? [] : .all)


            VStack(spacing: 8) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        if layout.controlsOnTrailingEdge { Spacer(minLength: 0) }
                        if layout.mode == .wide && listCollapsed {
                            Button(action: toggleList) { Label("時間軸", systemImage: "sidebar.left") }
                                .buttonStyle(.borderedProminent)
                            fitButton
                        } else if !layout.split {
                            if layout.compactOverlay || sizeClass == .regular {
                                dateToolbar
                            } else {
                                fitButton
                                Spacer()
                                dateChips
                            }
                        }
                        if !layout.controlsOnTrailingEdge { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.leading, max(0, layout.map.minX - layout.mapCanvas.minX))
                    .padding(.top, layout.split ? 16 : layout.topInset)
                    .offset(y: !layout.split && sizeClass == .regular
                            ? -max(0, topInset - 12) : 0)
                    if let sel = selectedStay { calloutCard(sel) }
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    mapHeaderHeight = height
                }
                Spacer()
            }
            .padding(.leading, layout.split ? 0 : layout.contentBounds.minX)
            .padding(.trailing, layout.split ? 0 : layout.bounds.maxX - layout.contentBounds.maxX)
            .padding(.top, layout.split ? 0 : layout.contentBounds.minY)
            .padding(.bottom, layout.split ? 0 : layout.bounds.maxY - layout.contentBounds.maxY)
            if vm.todayStays.isEmpty && !layout.split { emptyState.padding(.horizontal, 32) }
        }
    }

    private var emptyState: some View {
        EmptyStateBear(title: vm.isRange ? "這段期間沒有足跡" : "這一天沒有足跡",
                       message: "開著回報、或從相簿匯入，就會有紀錄。",
                       actionTitle: "相簿匯入", action: { showImport = true })
    }

    @ViewBuilder private func timelinePanel(_ layout: AdaptiveMapLayout, bottomInset: CGFloat) -> some View {
        if layout.split {
            VStack(alignment: .leading, spacing: 12) {
                if layout.mode == .wide {
                    HStack(spacing: 8) {
                        ProfileMenu()
                        dateChips
                        Spacer(minLength: 0)
                        Button(action: toggleList) { Image(systemName: "sidebar.left") }
                            .accessibilityLabel("收合時間軸")
                            .frame(width: 44, height: 44)
                    }
                    HStack(spacing: 8) {
                        fitButton
                        importIconButton
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            if layout.mode != .laptop { ProfileMenu() }
                            dateToolbar
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                if layout.mode != .laptop { ProfileMenu() }
                                dateChips
                            }
                            HStack(spacing: 8) { fitButton; importIconButton }
                        }
                    }
                }
                panelHeading
                if vm.todayStays.isEmpty {
                    ScrollView { emptyState }
                } else {
                    ScrollView { stayRows(compact: layout.mode == .wide).padding(.bottom, max(12, bottomInset)) }
                        .modifier(RememberTimelineScroll(offset: $listScrollOffset))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BearTheme.sheet)
            .clipped()
        } else if !vm.todayStays.isEmpty {
            CollapsibleSheet(detent: $detent, title: sheetTitle, subtitle: sheetSubtitle,
                             fullTopFraction: selectedStay != nil ? 0.22 : 0.15,
                             floating: layout.compactOverlay,
                             minimumTop: layout.compactOverlay ? max(layout.topInset + 44, mapHeaderHeight) + 12 : 0,
                             scrollOffset: $listScrollOffset) {
                if !layout.compactOverlay && sizeClass != .regular { importButton }
            } content: { stayRows(compact: layout.compactOverlay) }
        }
    }

    private var panelHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sheetTitle).font(.headline).foregroundStyle(BearTheme.cream)
            Text(sheetSubtitle).font(.caption).foregroundStyle(BearTheme.cream.opacity(0.55))
        }
    }

    private func stayRows(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if vm.isRange {
                ForEach(dayGroups, id: \.day) { group in
                    if let yh = group.yearHeader {   // 跨年時才顯示年份小標
                        Text(yh)
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(BearTheme.cream.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4).padding(.top, 14)
                    }
                    Text(dayHeaderText(group.day))   // 「7/2 週四」
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(BearTheme.honeyLight.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 2)
                    ForEach(Array(group.stays.enumerated()), id: \.element.id) { i, stay in
                        row(stay, isLast: i == group.stays.count - 1, compact: compact)
                    }
                }
            } else {
                ForEach(Array(vm.todayStays.enumerated()), id: \.element.id) { i, stay in
                    row(stay, isLast: i == vm.todayStays.count - 1, compact: compact)
                }
            }
        }
        .padding(.top, 2)
        .scrollTargetLayout()
    }


    // 一列 stay（帶全域編號 → 地圖點對得上；點列 zoom 到該點）
    private func row(_ stay: Stay, isLast: Bool, compact: Bool) -> some View {
        StayRow(stay: stay, index: globalIndex(stay), isLast: isLast,
                onName: stay.coordinate != nil ? { namingStay = stay } : nil,   // 匯入點也可命名（#6）
                isSelected: stay.id == selectedStayID,
                onTap: { select(stay) }, compact: compact)
    }

    // 全域序號（在 vm.todayStays 的位置＋1）→ 地圖 marker 與列表共用同一編號
    private func globalIndex(_ stay: Stay) -> Int {
        (vm.todayStays.firstIndex { $0.id == stay.id } ?? 0) + 1
    }

    // 命名/改地標範圍後：對所有點用本地地標重掃 alias（落在範圍內的即時顯示該名，含鄰近點）
    private func reapplyAliases() {
        for i in vm.todayStays.indices {
            if let c = vm.todayStays[i].coordinate, let lm = landmarks.resolvePreview(c) {
                vm.todayStays[i].name = lm.alias
            }
        }
    }

    // 使用者對著某一段停留按了命名 —— 那是**人在指認**，不只是畫了一個圓。
    // 感測器那條路要湊足票數才敢命名（單一定位點在沒有 CLVisit 同名佐證時判錯過，所以門檻是
    // 兩票），但人講的話不需要湊票。把這個訊號送回後端，那段停留就直接成立。
    //
    // 只對 visit 來源的停留有效（live／相片匯入沒有對應的 visit 身分）。
    // 送不出去也不影響地標已經存好這件事，下次還有「權威離開時重判」那道安全網。
    private func assignNamedStay(_ stay: Stay, to saved: Landmark?) {
        guard let visitId = stay.visitId, let lm = saved else {
            // 沒 visit 身分（live／相片匯入）或地標根本沒存成功 → 沒有可指認的對象。
            // 仍要補一次重判：表單為了讓指定排在前面，已經把自動重判關掉了。
            Task { await LandmarkManager.reconsiderRecentVisits() }
            return
        }
        Task {
            await LandmarkManager.assignVisit(visitId, toLandmark: lm.id)
            await LandmarkManager.reconsiderRecentVisits()  // 指定完才做廣域重判，順序不能反
            await vm.reloadStays()                          // 後端定案後刷新，時間軸與事件同源
        }
    }

    private func onDateChipTap(_ i: Int) {
        selectedStayID = nil
        if i == 0 {
            Task { vm.selectedDays = []; await vm.reloadStays(); applyFit(collapse: true) }  // 收面板全螢幕框好（同選日期）
        } else {
            showDateOptions = true   // 每次點都開 → 兩入口 dialog（時間區間 / 行事曆多選）
        }
    }

    // 停留門檻說明（比照列表次要字）。
    //
    // 🔴 這裡刻意**不寫數字**。原本寫的是「久留逾 10 分鐘才算停留」，對齊 detect_stays 的
    //    min_dwell_s=600 —— 但那個門檻只管用定位點聚出來的 live 段，**CLVisit 段完全不吃**
    //    （prod 實測有 4～9 分鐘的 src=visit 段照樣顯示）。也就是說畫面承諾了一件它沒在做的事。
    //
    //    要對齊只有兩條路，而把門檻也套到 CLVisit 段上是錯的：那會讓一堆真實的短停留
    //    （轉乘、買個東西）從時間軸消失 —— 拿好資料去遷就一句文案。所以改的是文案。
    private var sheetSubtitle: String { "短暫經過可能不會留下紀錄" }

    // 面板標題：今天 / 某日「M/D」/ 多日「N 個」
    private var sheetTitle: String {
        let n = vm.todayStays.count
        if vm.isRange { return "\(n) 個停留／點" }
        if vm.selectedDays.isEmpty { return "今天 · \(n) 個停留／點" }
        if let d = vm.selectedDays.first {
            let c = tzCal.dateComponents([.month, .day], from: d)
            return "\(c.month ?? 0)/\(c.day ?? 0) · \(n) 個停留／點"
        }
        return "\(n) 個停留／點"
    }

    // 選中一個 stay：zoom 到它、記住選取（map↔list 雙向）
    private func select(_ stay: Stay) {
        selectedStayID = stay.id
        let result: SheetDetent = (detent == .full) ? .half : detent   // 全開會擋地圖 → 降半開
        if result != detent { withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { detent = result } }
        if let c = stay.coordinate {
            withAnimation(.easeInOut(duration: 0.4)) {
                camera = .region(focusRegion(center: c, meters: 650, coverage: coverage(for: result)))
            }
        }
    }

    // 顯示全部足跡：先收面板（看整張圖、中心才不會被遮）
    private func fitCamera() { applyFit(collapse: true) }

    // 框景（初次進頁 / 換日期 collapse=false 不收面板；熊掌 collapse=true 收面板）
    // 有足跡框住所有點（最小縮放防爆大 #2）、無足跡以使用者位置置中（#3/#5）
    private func applyFit(collapse: Bool) {
        let coords = vm.todayStays.compactMap(\.coordinate)
        selectedStayID = nil
        if collapse { withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { detent = .collapsed } }
        let cov = coverage(for: collapse ? .collapsed : detent)
        withAnimation(.easeInOut(duration: 0.45)) {
            if coords.isEmpty {
                camera = northUpUserRegion()   // 沒足跡：置中 user 且轉回正北（region 天生北正上）
            } else if coords.count == 1 {
                camera = .region(focusRegion(center: coords[0], meters: 900, coverage: cov))
            } else {
                camera = .region(shiftUp(regionThatFits(coords), coverage: cov))
            }
        }
    }

    // 沒足跡時的框景：region 天生北正上 → 保證回正北 + 置中 user；拿不到即時位置才退 .userLocation
    private func northUpUserRegion() -> MapCameraPosition {
        if let loc = reporter.lastLocation?.coordinate {
            return .region(MKCoordinateRegion(center: loc, latitudinalMeters: 1200, longitudinalMeters: 1200))
        }
        return .userLocation(fallback: .automatic)
    }

    // 面板遮住地圖下半 → 把相機中心往「南」偏，讓目標落在可見的上半（#2/#5：體感不跑掉）
    private func coverage(for d: SheetDetent) -> Double {
        if splitMap { return 0 }
        switch d {
        case .collapsed: return 0.10
        case .half:      return 0.27
        case .full:      return 0.38
        }
    }
    private func focusRegion(center c: CLLocationCoordinate2D, meters: Double, coverage: Double) -> MKCoordinateRegion {
        let latDelta = meters / 111_000
        let shifted = CLLocationCoordinate2D(latitude: c.latitude - coverage * latDelta, longitude: c.longitude)
        return MKCoordinateRegion(center: shifted, latitudinalMeters: meters, longitudinalMeters: meters)
    }
    private func shiftUp(_ r: MKCoordinateRegion, coverage: Double) -> MKCoordinateRegion {
        var out = r
        out.center.latitude -= coverage * r.span.latitudeDelta
        return out
    }

    // 點很近時別爆縮（最小 span ~1.3km）；#4
    private func regionThatFits(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let lats = coords.map(\.latitude), lngs = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.6, 0.012),
                                    longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.6, 0.012))
        return MKCoordinateRegion(center: center, span: span)
    }

    // 跨日多選時依當地日期分組（跨年時第一次出現的年份帶 yearHeader）
    private var dayGroups: [(day: Date, stays: [Stay], yearHeader: String?)] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: vm.todayStays) { cal.startOfDay(for: $0.from) }
        let days = groups.keys.sorted()
        let multiYear = Set(days.map { cal.component(.year, from: $0) }).count > 1
        var prevYear: Int? = nil
        var out: [(day: Date, stays: [Stay], yearHeader: String?)] = []
        for d in days {
            let y = cal.component(.year, from: d)
            let yh: String? = (multiYear && y != prevYear) ? "\(y)" : nil
            prevYear = y
            out.append((day: d, stays: groups[d]!.sorted { $0.from < $1.from }, yearHeader: yh))
        }
        return out
    }

    // 日期小標：「7/2 週四」（中文星期）
    private func dayHeaderText(_ d: Date) -> String {
        let cal = Calendar.current
        let m = cal.component(.month, from: d)
        let day = cal.component(.day, from: d)
        let wd = cal.component(.weekday, from: d)   // 1=日 … 7=六
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return "\(m)/\(day) 週\(names[wd - 1])"
    }

    private var dateToolbar: some View {
        HStack(spacing: 8) {
            dateChips
            fitButton
            importIconButton
        }
    }

    private var fitButton: some View {
        Button { fitCamera() } label: {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BearTheme.honeyLight)
                .frame(width: 44, height: 44)
                .background(Circle().fill(BearTheme.surface))
                .overlay(Circle().strokeBorder(BearTheme.honeyLight.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("顯示全部足跡")
        .help("顯示全部足跡")
    }

    private var importIconButton: some View {
        Button { showImport = true } label: {
            Image(systemName: "camera")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BearTheme.honeyLight)
                .frame(width: 44, height: 44)
                .background(Circle().fill(BearTheme.surface))
                .overlay(Circle().strokeBorder(BearTheme.honeyLight.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("相簿匯入")
        .help("相簿匯入")
    }

    private var importButton: some View {
        Button { showImport = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "camera").font(.system(size: 12, weight: .bold))
                Text("相簿匯入").font(.system(size: 12.5, weight: .bold))
            }
            .foregroundStyle(BearTheme.honeyLight)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(BearTheme.honeyLight.opacity(0.14))
                    .overlay(Capsule().strokeBorder(BearTheme.honeyLight.opacity(0.35), lineWidth: 0.5))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // 選中點 callout（點地圖 marker 或列表都會帶出）→ 顯示名稱/時間/停留＋命名
    private func calloutCard(_ stay: Stay) -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(stay.source == .photoImport ? BearTheme.honeyLight : BearTheme.honey)
                    .frame(width: 30, height: 30)
                if stay.source == .photoImport {
                    Image(systemName: "camera.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(BearTheme.ink)
                } else {
                    Text("\(globalIndex(stay))").font(.system(size: 13, weight: .bold)).foregroundStyle(BearTheme.ink)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stay.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(BearTheme.cream).lineLimit(1)
                Text(calloutDetail(stay)).font(.system(size: 12)).foregroundStyle(BearTheme.cream.opacity(0.6))
            }
            Spacer(minLength: 6)
            if stay.coordinate != nil {
                Button { namingStay = stay } label: {
                    Image(systemName: "tag").font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(BearTheme.honeyLight)
                        .padding(8)
                        .background(Circle().strokeBorder(BearTheme.honeyLight.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button { selectedStayID = nil } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BearTheme.cream.opacity(0.5)).padding(7)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 18).fill(BearTheme.sheet.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.horizontal, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func calloutDetail(_ stay: Stay) -> String {
        let t = stay.from.formatted(.dateTime.hour().minute())
        if stay.source == .photoImport { return "相簿匯入點 · \(t)" }
        return "停留 \(stay.dwellText) · \(t)"
    }

    // 選日期兩入口 popover（貼齊「選日期」chip；做法 A）
    private var optionsPopover: some View {
        VStack(spacing: 0) {
            popoverRow("時間區間", "calendar") { showDateOptions = false; openRange() }
            Divider().overlay(Color.white.opacity(0.12))
            popoverRow("行事曆多選", "calendar.day.timeline.left") { showDateOptions = false; openCalendar() }
        }
        .frame(width: 200)
        .presentationCompactAdaptation(.popover)
    }
    private func popoverRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 22)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(BearTheme.honeyLight)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Background coverage includes the fold margin and screen edge;
    // controls remain inside the smaller safe panel rectangle.
    private func panelBackdrop(_ layout: AdaptiveMapLayout, insets: EdgeInsets) -> CGRect {
        let top = layout.mode == .laptop ? (layout.division?.midY ?? layout.panel.minY) : -insets.top
        let right = layout.mode == .book ? (layout.division?.midX ?? layout.panel.maxX) : layout.panel.maxX
        return CGRect(x: -insets.leading, y: top,
                      width: right + insets.leading,
                      height: layout.bounds.maxY + insets.bottom - top)
    }

    private func dateDialog(_ layout: AdaptiveMapLayout) -> some View {
        AdaptiveDateDialog(prefersColumns: layout.mode == .laptop,
                           controlsAboveCalendar: showRange) {
            if showRange {
                BearCalendar(selected: .constant([keyOf(rangeEndpoint == .from ? rangeFrom : rangeTo)]),
                             recorded: [], month: $rangeMonth, onMonthChange: {},
                             onSelect: { date in
                                 if rangeEndpoint == .from { rangeFrom = date }
                                 else { rangeTo = date }
                             })
            } else {
                BearCalendar(selected: $calSelected, recorded: calRecorded, month: $calMonth,
                             onMonthChange: { Task { await loadCalRecorded() } })
            }
        } controls: { columns in
            if showRange { rangeControls(columns: columns) }
            else { calendarControls(columns: columns) }
        } actions: {
            HStack(spacing: 8) {
                modalButton("取消", filled: false) { closeModals() }
                modalButton("完成", filled: true) {
                    if showRange { applyRange() } else { applyCalendarSelection() }
                }
            }
        }
    }

    private func rangeControls(columns: Bool) -> some View {
        VStack(spacing: 12) {
            Text("時間區間").font(.system(size: 18, weight: .heavy)).foregroundStyle(BearTheme.cream)
            let fields = columns ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            fields {
                rangeField("從", date: rangeFrom, endpoint: .from)
                rangeField("到", date: rangeTo, endpoint: .to)
            }
            Text("選一段連續日期（上限約一個月）。")
                .font(.system(size: 11.5)).foregroundStyle(BearTheme.cream.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rangeField(_ title: String, date: Date, endpoint: RangeEndpoint) -> some View {
        let active = rangeEndpoint == endpoint
        return Button {
            rangeEndpoint = endpoint
            rangeMonth = date
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(keyOf(date).replacingOccurrences(of: "-", with: "/"))
                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(active ? BearTheme.ink : BearTheme.cream)
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(active ? BearTheme.honeyLight : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(keyOf(date))")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func calendarControls(columns: Bool) -> some View {
        VStack(alignment: columns ? .leading : .center, spacing: 10) {
            if columns { Text("選日期").font(.headline).foregroundStyle(BearTheme.cream) }
            let shortcuts = columns ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            shortcuts {
                quickChip("最近 7 天") { quickSelectRecent(7) }
                quickChip("本月") { quickSelectThisMonth() }
                quickChip("清除") { calSelected = [] }
            }
            Text(calSelected.isEmpty ? "點日期多選（可不連續）。熊掌＝有足跡。" : "已選 \(calSelected.count) 天")
                .font(.system(size: 11.5)).foregroundStyle(BearTheme.cream.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modalButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .bold))
                .foregroundStyle(filled ? BearTheme.ink : BearTheme.cream)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Capsule().fill(filled ? BearTheme.honeyLight : .white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
    private func quickChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .bold)).foregroundStyle(BearTheme.honeyLight)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(BearTheme.honeyLight.opacity(0.12))
                    .overlay(Capsule().strokeBorder(BearTheme.honeyLight.opacity(0.3), lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }
    private func quickSelectRecent(_ days: Int) {
        var keys = Set<String>()
        for i in 0..<days { if let d = tzCal.date(byAdding: .day, value: -i, to: Date()) { keys.insert(keyOf(d)) } }
        calSelected = keys; calMonth = Date()
        Task { await loadCalRecorded() }
    }
    private func quickSelectThisMonth() {
        let today = tzCal.startOfDay(for: Date())
        var d = monthBounds(Date()).0
        var keys = Set<String>()
        while d <= today { keys.insert(keyOf(d)); guard let n = tzCal.date(byAdding: .day, value: 1, to: d) else { break }; d = n }
        calSelected = keys; calMonth = Date()
    }

    // MARK: 選日期 helpers（用當地時區 Calendar；日期以 yyyy-MM-dd 字串為 key）
    private var tzCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: Config.tz) ?? .current
        return c
    }
    private func keyOf(_ d: Date) -> String {
        let c = tzCal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private func dateOf(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return tzCal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    private func monthBounds(_ m: Date) -> (Date, Date) {
        let first = tzCal.date(from: tzCal.dateComponents([.year, .month], from: m)) ?? m
        let range = tzCal.range(of: .day, in: .month, for: m) ?? (1..<29)
        let last = tzCal.date(byAdding: .day, value: range.count - 1, to: first) ?? first
        return (first, last)
    }
    private func openCalendar() {
        calSelected = Set(vm.selectedDays.map(keyOf))       // 帶入目前選擇
        calMonth = vm.selectedDays.first ?? Date()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { showCalendar = true }
        Task { await loadCalRecorded() }
    }
    private func closeModals() {
        withAnimation(.easeOut(duration: 0.2)) { showRange = false; showCalendar = false }
    }
    // 遮罩層（薄霧 + 輕壓暗）；只淡入、不縮放
    private func modalScrim(onClose: @escaping () -> Void) -> some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.2)
        }
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
    }
    private func loadCalRecorded() async {
        let (from, to) = monthBounds(calMonth)
        calRecorded = await vm.recordedDayKeys(from: from, to: to)
    }
    private func applyCalendarSelection() {
        let days = calSelected.sorted().compactMap(dateOf)
        closeModals()
        Task { vm.selectedDays = days; await vm.reloadStays(); applyFit(collapse: true) }  // 收面板全螢幕框好（等於自動按熊掌）
    }
    private func openRange() {
        rangeTo = Date()
        rangeFrom = tzCal.date(byAdding: .day, value: -6, to: Date()) ?? Date()
        rangeEndpoint = .from
        rangeMonth = rangeFrom
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { showRange = true }
    }
    private func applyRange() {
        let lo = tzCal.startOfDay(for: min(rangeFrom, rangeTo))
        let hi = tzCal.startOfDay(for: max(rangeFrom, rangeTo))
        var days: [Date] = []
        var d = lo
        while d <= hi && days.count < 31 {
            days.append(d)
            guard let next = tzCal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        closeModals()
        Task { vm.selectedDays = days; await vm.reloadStays(); applyFit(collapse: true) }  // 收面板全螢幕框好（等於自動按熊掌）
    }

    private func stayMarker(index: Int, stay: Stay) -> some View {
        let selected = stay.id == selectedStayID
        return ZStack {
            if selected {
                Circle().fill(BearTheme.honeyLight.opacity(0.25)).frame(width: 42, height: 42)
            }
            Circle()
                .fill(stay.source == .photoImport ? BearTheme.honeyLight : BearTheme.honey)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(BearTheme.cream, lineWidth: selected ? 3 : 2.5))
            if stay.source == .photoImport {
                Image(systemName: "camera.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(BearTheme.ink)
            } else {
                Text("\(index)").font(.system(size: 12, weight: .bold)).foregroundStyle(BearTheme.ink)
            }
        }
        .scaleEffect(selected ? 1.15 : 1)
        .shadow(color: .black.opacity(0.4), radius: 5, y: 2)
    }
}

#Preview {
    TimelineScreen()
        .environment(LocationVM())
        .environment(PhotoImporter())
        .environment(LandmarkManager())
        .environment(LocationReporter())
        .preferredColorScheme(.dark)
}
