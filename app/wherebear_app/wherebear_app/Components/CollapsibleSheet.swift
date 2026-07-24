// CollapsibleSheet.swift — 可拖曳的三段式 bottom sheet
// 三段 snap：collapsed（貼 tab bar 上、只剩標題）／ half（約中間）／ full（切齊上方 capsule 下、留 padding）。
// 拖把手在三段間平滑滑動、放開 snap 到最近段；點一下在收合↔半展間切換。
// 抖動修法：拖曳用一般 @State（onChanged 直接跟手、無隱式動畫），放開才 withAnimation snap
// —— 不用 @GestureState（放開瞬間歸零 + detent 跳段會互撞造成抖動）。
import SwiftUI

enum SheetDetent: CaseIterable { case collapsed, half, full }

struct CollapsibleSheet<Accessory: View, Content: View>: View {
    @Binding var detent: SheetDetent
    var title: String
    var subtitle: String? = nil                // 標題下小字說明（非粗體、小字、次要色）；nil＝不顯示
    var fullTopFraction: CGFloat = 0.15        // full 距畫面頂比例（由外面依「有無 callout」動態帶入）
    var halfTopFraction: CGFloat = 0.46        // half：約中間
    var collapsedVisibleHeight: CGFloat = 158  // collapsed：露出高度
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let fullTop = geo.size.height * fullTopFraction
            let halfTop = geo.size.height * halfTopFraction
            let collapsedTop = geo.size.height - collapsedVisibleHeight
            let base = topFor(detent, full: fullTop, half: halfTop, collapsed: collapsedTop)
            let top = min(collapsedTop, max(fullTop, base + dragOffset))

            VStack(spacing: 0) {
                header(fullTop: fullTop, halfTop: halfTop, collapsedTop: collapsedTop)
                ScrollView {
                    content
                        .padding(.horizontal, 18)
                        .padding(.bottom, 112) // 淨空浮動 tab bar（frame 已修為可見高度、不再被 offset 吃掉；此值＝真實淨空、可微調）
                }
                .scrollDisabled(detent == .collapsed)
            }
            // frame 高度＝可見高度（geo.height − top）而非整螢幕 → ScrollView 視窗＝實際可見、捲動範圍算對、
            // 最後幾列捲得到（修 #2/#3）；offset 仍下移 top、sheet 底剛好貼螢幕底、不再溢出螢幕外。
            .frame(width: geo.size.width, height: max(0, geo.size.height - top), alignment: .top)
            .background(BearTheme.sheet.opacity(0.96))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26))
            .shadow(color: .black.opacity(0.4), radius: 15, y: -8)
            .offset(y: top)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func topFor(_ d: SheetDetent, full: CGFloat, half: CGFloat, collapsed: CGFloat) -> CGFloat {
        switch d {
        case .full: return full
        case .half: return half
        case .collapsed: return collapsed
        }
    }

    private func header(fullTop: CGFloat, halfTop: CGFloat, collapsedTop: CGFloat) -> some View {
        VStack(spacing: 8) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 38, height: 4.5).padding(.top, 10)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(BearTheme.cream)
                    if let subtitle, !subtitle.isEmpty {   // 比照 StayRow「停留xx分·高信心」：12.5、非粗體、cream 0.55
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(BearTheme.cream.opacity(0.55))
                    }
                }
                Spacer()
                accessory
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .gesture(
            // 用 .global 座標系量位移：面板自己會移動，若用 local 座標會互相回饋 → 抖（#1 根治）
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in dragOffset = v.translation.height }
                .onEnded { v in
                    let base = topFor(detent, full: fullTop, half: halfTop, collapsed: collapsedTop)
                    let predicted = base + v.predictedEndTranslation.height
                    let target = nearestDetent(to: predicted, full: fullTop, half: halfTop, collapsed: collapsedTop)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        detent = target
                        dragOffset = 0
                    }
                }
        )
        .onTapGesture {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                detent = (detent == .collapsed) ? .half : .collapsed
            }
        }
    }

    private func nearestDetent(to y: CGFloat, full: CGFloat, half: CGFloat, collapsed: CGFloat) -> SheetDetent {
        let options: [(SheetDetent, CGFloat)] = [(.full, full), (.half, half), (.collapsed, collapsed)]
        return options.min { abs($0.1 - y) < abs($1.1 - y) }!.0
    }
}
