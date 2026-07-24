// CircleCropSheet.swift — 頭貼圓形裁切（拖曳移動 + 雙指縮放 + 圓形遮罩預覽）
import SwiftUI

struct CircleCropSheet: View {
    let image: UIImage
    var onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let diameter: CGFloat = 300

    var body: some View {
        ZStack {
            BearTheme.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Text("調整頭貼")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(BearTheme.cream)

                ZStack {
                    canvas(clip: true)
                    Circle()
                        .strokeBorder(BearTheme.honeyLight.opacity(0.85), lineWidth: 2)
                        .frame(width: diameter, height: diameter)
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { scale = min(max(lastScale * $0.magnification, 1), 5) }
                            .onEnded { _ in lastScale = scale },
                        DragGesture()
                            .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width,
                                                         height: lastOffset.height + $0.translation.height) }
                            .onEnded { _ in lastOffset = offset }
                    )
                )

                Text("拖曳移動 · 雙指縮放")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BearTheme.cream.opacity(0.5))

                HStack(spacing: 12) {
                    Button("取消") { dismiss() }
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BearTheme.cream.opacity(0.7))
                        .background(Capsule().fill(.white.opacity(0.08)))
                    Button("套用") { apply() }
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(BearTheme.ink)
                        .background(Capsule().fill(BearTheme.honeyLight))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 30)
                .padding(.top, 6)
            }
            .padding(.vertical, 34)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func canvas(clip: Bool) -> some View {
        let base = Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: diameter, height: diameter)
        if clip { base.clipShape(Circle()) } else { base.clipped() }
    }

    @MainActor private func apply() {
        let renderer = ImageRenderer(content: canvas(clip: false).frame(width: diameter, height: diameter))
        renderer.scale = 3 // ~900px
        if let ui = renderer.uiImage { onCrop(ui) }
        dismiss()
    }
}
