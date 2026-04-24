import SwiftUI

enum DS {
    enum Color {
        static let accent = SwiftUI.Color.accentColor
        static let bgSubtle = SwiftUI.Color.white.opacity(0.04)
        static let bgHover = SwiftUI.Color.white.opacity(0.08)
        static let bgSelected = SwiftUI.Color.white.opacity(0.12)
        static let textPrimary = SwiftUI.Color.white.opacity(1.0)
        static let textSecondary = SwiftUI.Color.white.opacity(0.7)
        static let textTertiary = SwiftUI.Color.white.opacity(0.4)
        static let divider = SwiftUI.Color.white.opacity(0.08)
    }

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let pill: CGFloat = 5
        static let row: CGFloat = 7
        static let panel: CGFloat = 10
    }

    enum FontSize {
        static let xs: CGFloat = 11
        static let sm: CGFloat = 12
        static let body: CGFloat = 13
        static let title: CGFloat = 15
        static let large: CGFloat = 20
    }
}
