import Foundation
import CoreGraphics

// Compile alongside AdaptiveMapLayoutGeometry.swift and
// CollapsibleSheetGeometry.swift; no simulator or server.
@main struct AdaptiveMapLayoutChecks {
    static func main() {
        let phone = AdaptiveMapLayout(size: CGSize(width: 393, height: 780), regular: false)
        precondition(phone.mode == .overlay && !phone.compactOverlay && phone.map == phone.bounds)
        let flat = AdaptiveMapLayout(size: CGSize(width: 900, height: 600), regular: true)
        let hidden = AdaptiveMapLayout(size: CGSize(width: 900, height: 600), regular: true, collapsed: true)
        precondition(flat.panel.maxX == flat.map.minX)
        precondition(hidden.map == hidden.bounds && hidden.panel == flat.panel,
                     "Collapsing must preserve list width and its scroll layout")
        let portrait = AdaptiveMapLayout(size: CGSize(width: 600, height: 900), regular: true)
        precondition(portrait.mode == .overlay)
        // Split View: the app's local content stays 385 x 635 while the
        // division at its edge becomes active. Neither side has two panes.
        let splitSize = CGSize(width: 385, height: 635)
        for (rail, division) in [
            (ControlRailEdge.trailing, CGRect(x: 0, y: 0, width: 13.5, height: 669)),
            (.leading, CGRect(x: 371.5, y: 0, width: 13.5, height: 669))
        ] {
            let unfolded = AdaptiveMapLayout(size: splitSize, regular: false, controlRail: rail)
            let folded = AdaptiveMapLayout(size: splitSize, regular: false,
                                           division: division, controlRail: rail)
            precondition(folded.mode == .overlay,
                         "An edge division must preserve the map and bottom drawer in Split View")
            precondition(folded.compactOverlay && unfolded.compactOverlay,
                         "An inner compact window must keep the same controls and floating drawer")
            precondition(folded.controlsOnTrailingEdge == (rail == .leading)
                         && folded.controlsOnTrailingEdge == unfolded.controlsOnTrailingEdge)
            precondition(folded.mapCanvas == unfolded.mapCanvas && folded.map == unfolded.map)
            precondition(!folded.needsMapRefit(comparedTo: unfolded)
                         && !unfolded.needsMapRefit(comparedTo: folded),
                         "Folding and unfolding an edge must preserve the user's camera")
            precondition(folded.panel == folded.contentBounds && folded.panel.width == 371.5,
                         "Only the supplied reserved frame is excluded, with no duplicated margins")
            precondition(folded.contentBounds.intersection(division).isEmpty)
            precondition(folded.contentBounds.minX == (rail == .trailing ? 13.5 : 0))
        }
        // Mirrored edge/sliver cases, including partially outside regions.
        let edgeRegions = [CGRect(x: -20, y: -20, width: 53.5, height: 700),
                           CGRect(x: 351.5, y: -20, width: 53.5, height: 700),
                           CGRect(x: 3, y: -20, width: 20, height: 700),
                           CGRect(x: 362, y: -20, width: 20, height: 700),
                           CGRect(x: -20, y: -10, width: 430, height: 24),
                           CGRect(x: -20, y: 621, width: 430, height: 24),
                           CGRect(x: -20, y: 3, width: 430, height: 20),
                           CGRect(x: -20, y: 612, width: 430, height: 20)]
        for region in edgeRegions {
            let layout = AdaptiveMapLayout(size: splitSize, regular: false, division: region,
                                           controlRail: .leading)
            precondition(!layout.divided && layout.mode == .overlay)
            precondition(layout.contentBounds.width >= 120 && layout.contentBounds.height >= 120)
            precondition(layout.bounds.contains(layout.contentBounds))
            precondition(layout.contentBounds.intersection(region).isEmpty)
            precondition(layout.mapCanvas == layout.bounds)
        }
        // Outside regions and a partial strip cannot divide the app's content.
        for region in [CGRect(x: -25, y: 0, width: 20, height: 700),
                       CGRect(x: 390, y: 0, width: 20, height: 700),
                       CGRect(x: 170, y: 200, width: 20, height: 100)] {
            let layout = AdaptiveMapLayout(size: splitSize, regular: false, division: region)
            precondition(layout.mode == .overlay && layout.contentBounds == layout.bounds)
        }
        for width in stride(from: 400, through: 1200, by: 100) {
            for height in stride(from: 400, through: 1000, by: 100) {
                let size = CGSize(width: width, height: height)
                for fraction in [0.35, 0.5, 0.65] {
                    let vertical = CGRect(x: Double(width) * fraction - 16, y: -20, width: 32, height: Double(height + 40))
                    let book = AdaptiveMapLayout(size: size, regular: true, collapsed: true, division: vertical)
                    precondition(book.mode == .book)
                    precondition(book.needsMapRefit(comparedTo: AdaptiveMapLayout(size: size, regular: true)))
                    precondition(book.mapCanvas.minX == vertical.midX, "Map background must reach the fold centre")
                    precondition(book.panel.maxX <= vertical.minX && book.map.minX >= vertical.maxX)
                    let horizontal = CGRect(x: -20, y: Double(height) * fraction - 16, width: Double(width + 40), height: 32)
                    let laptop = AdaptiveMapLayout(size: size, regular: true, collapsed: true, division: horizontal)
                    precondition(laptop.mode == .laptop)
                    precondition(laptop.mapCanvas.maxY == horizontal.midY, "Map background must reach the fold centre")
                    precondition(laptop.map.maxY <= horizontal.minY && laptop.panel.minY >= horizontal.maxY)
                    for layout in [book, laptop] {
                        precondition(layout.bounds.contains(layout.map) && layout.bounds.contains(layout.panel))
                    }
                }
            }
        }
        let outer = AdaptiveMapLayout(size: CGSize(width: 390, height: 600), regular: false,
                                      occlusions: [CGRect(x: 400, y: 20, width: 32, height: 32)])
        precondition(outer.compactOverlay && outer.topInset + 26 == 36)

        // A rotation can move the camera between all four corners and can
        // change the rail side without changing the window's dimensions.
        for size in [CGSize(width: 390, height: 600), CGSize(width: 600, height: 390)] {
            for x in [CGFloat(-48), size.width + 10] {
                for y in [CGFloat(20), size.height - 52] {
                    let rail: ControlRailEdge = x < 0 ? .leading : .trailing
                    let camera = CGRect(x: x, y: y, width: 32, height: 32)
                    let rotated = AdaptiveMapLayout(size: size, regular: false,
                                                   occlusions: [camera], controlRail: rail)
                    precondition(rotated.compactOverlay && rotated.mode == .overlay)
                    precondition((6...24).contains(rotated.topInset),
                                 "Top controls must stay in the top band when the camera rotates down")
                    precondition(rotated.controlsOnTrailingEdge == (rail == .leading),
                                 "Closed home controls must occupy the opposite side from the rail")
                }
            }
        }
        for rail in [ControlRailEdge.leading, .trailing] {
            // Rail relocation alone must not change an open display's panes
            // or move its accepted home controls away from the leading edge.
            for size in [CGSize(width: 900, height: 600), CGSize(width: 600, height: 900)] {
                for division: CGRect? in [nil,
                    CGRect(x: size.width / 2 - 16, y: -20, width: 32, height: size.height + 40),
                    CGRect(x: -20, y: size.height / 2 - 16, width: size.width + 40, height: 32)] {
                    let existing = AdaptiveMapLayout(size: size, regular: true, division: division)
                    let changedRail = AdaptiveMapLayout(size: size, regular: true, division: division,
                                                        controlRail: rail)
                    precondition(!changedRail.compactOverlay && !changedRail.controlsOnTrailingEdge)
                    precondition(existing.mode == changedRail.mode && existing.panel == changedRail.panel
                                 && existing.map == changedRail.map && existing.mapCanvas == changedRail.mapCanvas)
                }
            }
            let transientCamera = AdaptiveMapLayout(size: CGSize(width: 600, height: 390),
                                                   regular: false, controlRail: rail)
            precondition(transientCamera.compactOverlay, "A transiently missing camera must not change the drawer style")
        }

        // Known short landscape: toolbar ends at y=70; the drawer needs a
        // 12-point gap. A plain 15% stop would be y=58.5, overlapping it.
        let short = CollapsibleSheetStops(height: 390, minimumTop: 82, bottomGap: 12)
        precondition(short.full == 82 && short.half == 179.4 && short.collapsed == 232)
        let ordinary = CollapsibleSheetStops(height: 600)
        precondition(ordinary.full == 90 && ordinary.half == 276 && ordinary.collapsed == 442,
                     "Default inner-display drawer stops must be preserved")
        for height in stride(from: CGFloat(240), through: 1000, by: 20) {
            for headerBottom in [CGFloat(50), 90, 140] {
                let stops = CollapsibleSheetStops(height: height, minimumTop: headerBottom + 12, bottomGap: 12)
                precondition(stops.full >= headerBottom + 12,
                             "The expanded drawer must clear the toolbar and selected-stop card")
                precondition(stops.full <= stops.half && stops.half <= stops.collapsed)
                precondition(stops.collapsed <= height - 12)
            }
        }
        print("Layout checks passed: left/right Split View, edge/sliver/outside divisions, camera preservation, phone, 378 interior folds, rotated rails, and drawer clearance")
    }
}
