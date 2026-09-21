import CoreGraphics

// All stops share the drawer's local coordinate space. In short windows the
// stops may coincide, but must never cross the measured map toolbar.
struct CollapsibleSheetStops {
    let full: CGFloat
    let half: CGFloat
    let collapsed: CGFloat

    init(height: CGFloat, fullTopFraction: CGFloat = 0.15,
         halfTopFraction: CGFloat = 0.46, collapsedVisibleHeight: CGFloat = 158,
         minimumTop: CGFloat = 0, bottomGap: CGFloat = 0) {
        let bottom = max(0, height - bottomGap)
        full = min(bottom, max(0, minimumTop, height * fullTopFraction))
        collapsed = min(bottom, max(full, height - collapsedVisibleHeight))
        half = min(collapsed, max(full, height * halfTopFraction))
    }
}
