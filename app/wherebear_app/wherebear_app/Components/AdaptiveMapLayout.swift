import SwiftUI

extension AdaptiveMapLayout {
    init(_ geometry: GeometryProxy, regular: Bool, collapsed: Bool = false,
         controlRail: ControlRailEdge? = nil) {
        var division: CGRect?
        var occlusions: [CGRect] = []
        if #available(iOS 27.1, *) {
            if let region = geometry.reservedRegions(kind: .division).first(where: { $0.isActive }) {
                // The frame already includes system interaction margins.
                division = region.frame
            }
            occlusions = geometry.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }.map(\.frame)
        }
        self.init(size: geometry.size, regular: regular, collapsed: collapsed,
                  division: division, occlusions: occlusions, controlRail: controlRail)
    }
}

extension EnvironmentValues {
    // Read the current window's system placement; never cache device orientation.
    var adaptiveControlRail: ControlRailEdge? {
        if #available(iOS 27.1, *) {
            switch toolbarVerticalEdge {
            case .leading: return .leading
            case .trailing: return .trailing
            default: return nil
            }
        }
        return nil
    }
}

extension View {
    func layoutFrame(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}

struct ProfileMenu: View {
    @Environment(ProfileManager.self) private var profile
    @Environment(SupabaseSession.self) private var session
    var size: CGFloat = 44
    var body: some View {
        Menu {
            if let email = session.userEmail { Text(email) }
            Button {} label: { Label("找朋友 · 即將推出", systemImage: "person.2.fill") }.disabled(true)
            Button(role: .destructive) { session.signOut() } label: {
                Label("登出", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            AvatarView(image: profile.avatarImage, url: profile.avatarURL, size: size)
        }
        .accessibilityLabel("帳號選單")
    }
}

// Backgrounds may cross the fold; direct map gestures must not target it.
struct ReservedInteractionShield: View {
    let layout: AdaptiveMapLayout
    var body: some View {
        if let division = layout.division, !division.intersection(layout.bounds).isEmpty {
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                .accessibilityHidden(true)
                .layoutFrame(division.intersection(layout.bounds))
        }
    }
}
