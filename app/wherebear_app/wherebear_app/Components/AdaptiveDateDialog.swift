import SwiftUI

// Centre inside the supplied safe pane. Short, wide panes put the calendar
// beside its controls. If content cannot fit, only the body scrolls; actions
// remain inside the card and visible in every orientation.
struct AdaptiveDateDialog<CalendarContent: View, Controls: View, Actions: View>: View {
    var prefersColumns: Bool
    var controlsAboveCalendar: Bool
    private let calendar: CalendarContent
    private let controls: (Bool) -> Controls
    private let actions: Actions

    init(prefersColumns: Bool = false, controlsAboveCalendar: Bool = false,
         @ViewBuilder calendar: () -> CalendarContent,
         @ViewBuilder controls: @escaping (Bool) -> Controls,
         @ViewBuilder actions: () -> Actions) {
        self.prefersColumns = prefersColumns
        self.controlsAboveCalendar = controlsAboveCalendar
        self.calendar = calendar()
        self.controls = controls
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width >= 520 && (prefersColumns || geo.size.height < 520)
            Group {
                if columns {
                    ViewThatFits(in: .vertical) {
                        HStack(alignment: .top, spacing: 18) {
                            calendar.frame(maxWidth: .infinity)
                            sidebar(scrolls: false)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .top, spacing: 18) {
                            ScrollView { calendar }.defaultScrollAnchor(.top)
                            sidebar(scrolls: true)
                        }
                    }
                } else {
                    ViewThatFits(in: .vertical) {
                        VStack(spacing: 16) {
                            verticalContent
                            actions
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 16) {
                            ScrollView { verticalContent }.defaultScrollAnchor(.top)
                            actions.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: columns ? 700 : 440)
            .background(RoundedRectangle(cornerRadius: 24).fill(BearTheme.sheet))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .padding(16)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private var verticalContent: some View {
        VStack(spacing: 14) {
            if controlsAboveCalendar { controls(false) }
            calendar
            if !controlsAboveCalendar { controls(false) }
        }
    }

    private func sidebar(scrolls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if scrolls {
                ScrollView { controls(true) }.scrollBounceBehavior(.basedOnSize)
            } else {
                controls(true)
                Spacer(minLength: 0)
            }
            actions.fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 152)
    }
}
