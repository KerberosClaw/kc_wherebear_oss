import Foundation
import CoreGraphics

enum ControlRailEdge { case leading, trailing }

// Rectangles use the safe content area's local coordinates. Division includes
// the system's interaction margins; background colour can extend across it.
struct AdaptiveMapLayout: Equatable {
    enum Mode { case overlay, wide, book, laptop }
    var mode: Mode = .overlay
    var bounds: CGRect
    // Foreground controls avoid an edge division while the map background
    // keeps its full viewport. This is distinct from an internal two-pane fold.
    var contentBounds: CGRect
    var map: CGRect
    var panel: CGRect
    var mapCanvas: CGRect
    var division: CGRect?
    var compactOverlay = false
    var topInset: CGFloat = 6
    var controlRail: ControlRailEdge?
    var divided: Bool { mode == .book || mode == .laptop }
    var split: Bool { mode != .overlay }
    var controlsOnTrailingEdge: Bool { compactOverlay && controlRail == .leading }

    func needsMapRefit(comparedTo previous: Self) -> Bool {
        mode != previous.mode || mapCanvas != previous.mapCanvas
    }

    init(size: CGSize, regular: Bool, collapsed: Bool = false,
         division: CGRect? = nil, occlusions: [CGRect] = [],
         controlRail: ControlRailEdge? = nil) {
        bounds = CGRect(origin: .zero, size: size)
        contentBounds = bounds
        map = bounds
        panel = bounds
        mapCanvas = bounds
        self.division = division
        self.controlRail = controlRail
        if let f = division, !f.intersection(bounds).isEmpty {
            // Each pane needs room for content, not just a positive width.
            // Preserve supported interior folds; reject edge/sliver panes.
            let minimumPaneExtent: CGFloat = 120
            if f.height > f.width, f.minY <= bounds.minY, f.maxY >= bounds.maxY {
                let start = min(bounds.width, max(0, f.minX))
                let end = min(bounds.width, max(0, f.maxX))
                if start >= minimumPaneExtent && bounds.width - end >= minimumPaneExtent {
                    mode = .book
                    panel = CGRect(x: 0, y: 0, width: start, height: bounds.height)
                    map = CGRect(x: end, y: 0, width: bounds.width - end, height: bounds.height)
                } else if start < bounds.width - end {
                    contentBounds = CGRect(x: end, y: 0, width: bounds.width - end, height: bounds.height)
                } else {
                    contentBounds = CGRect(x: 0, y: 0, width: start, height: bounds.height)
                }
            } else if f.width >= f.height, f.minX <= bounds.minX, f.maxX >= bounds.maxX {
                let start = min(bounds.height, max(0, f.minY))
                let end = min(bounds.height, max(0, f.maxY))
                if start >= minimumPaneExtent && bounds.height - end >= minimumPaneExtent {
                    mode = .laptop
                    map = CGRect(x: 0, y: 0, width: bounds.width, height: start)
                    panel = CGRect(x: 0, y: end, width: bounds.width, height: bounds.height - end)
                } else if start < bounds.height - end {
                    contentBounds = CGRect(x: 0, y: end, width: bounds.width, height: bounds.height - end)
                } else {
                    contentBounds = CGRect(x: 0, y: 0, width: bounds.width, height: start)
                }
            }
        }
        let camera = occlusions.first(where: {
            $0.midX > bounds.width * 0.75 || $0.midX < bounds.width * 0.25
        })
        // A compact window with a side rail can be on either display. Folding
        // an inner Split View window must not change its controls or drawer.
        compactOverlay = !regular && !divided && (camera != nil || controlRail != nil)
        if let camera {
            topInset = max(6, camera.midY - 26)
            if compactOverlay {
                // A lower camera belongs to the bottom rail, not the top toolbar.
                // Keep the upper-camera alignment without letting a rotated
                // occlusion push controls down into the map or bottom actions.
                topInset = camera.midY < bounds.midY ? min(topInset, 24) : 6
            }
        }
        mapCanvas = map
        if let f = division, divided {
            if mode == .book {
                mapCanvas = CGRect(x: f.midX, y: 0, width: bounds.maxX - f.midX, height: bounds.height)
            } else {
                mapCanvas = CGRect(x: 0, y: 0, width: bounds.width, height: f.midY)
            }
        }
        if !divided { panel = contentBounds }
        if !divided && regular && contentBounds.width > contentBounds.height {
            mode = .wide
            let width = min(contentBounds.width * 0.45, min(400, max(300, contentBounds.width / 3)))
            panel = CGRect(x: contentBounds.minX, y: contentBounds.minY, width: width, height: contentBounds.height)
            let mapStart = collapsed ? contentBounds.minX : panel.maxX
            map = CGRect(x: mapStart, y: contentBounds.minY, width: contentBounds.maxX - mapStart, height: contentBounds.height)
            mapCanvas = map
        }
    }
}
