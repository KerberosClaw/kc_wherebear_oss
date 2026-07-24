// PawGlyph.swift — 熊掌印圖形（1 掌墊＋3 趾），pin／熊掌鈕共用
import SwiftUI

struct PawGlyph: View {
    var color: Color = BearTheme.pawInk
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Ellipse()
                .frame(width: size * 0.60, height: size * 0.47)
                .offset(y: size * 0.21)
            Circle().frame(width: size * 0.24)
                .offset(x: -size * 0.35, y: -size * 0.13)
            Circle().frame(width: size * 0.24)
                .offset(y: -size * 0.26)
            Circle().frame(width: size * 0.24)
                .offset(x: size * 0.35, y: -size * 0.13)
        }
        .foregroundStyle(color)
        .frame(width: size, height: size * 0.92)
    }
}

#Preview { PawGlyph(size: 60).padding().background(BearTheme.honeyLight) }
