import SwiftUI

enum Theme {
    // MARK: - Colors

    static let windowBackground = Color(hex: 0x1A1A1A)
    static let surfaceBackground = Color(hex: 0x232323)
    static let cardBackground = Color(hex: 0x2A2A2A)
    static let cardBackgroundHover = Color(hex: 0x333333)
    static let cardBorder = Color(hex: 0x3A3A3C).opacity(0.4)

    static let textPrimary = Color.white.opacity(0.9)
    static let textSecondary = Color.white.opacity(0.5)
    static let textTertiary = Color.white.opacity(0.3)

    static let diffAddition = Color(hex: 0x30D158)
    static let diffDeletion = Color(hex: 0xFF453A)

    // MARK: - Column Accent Colors

    static let triageAccent = Color(hex: 0x64D2FF)
    static let planAccent = Color(hex: 0x5856D6)
    static let buildAccent = Color(hex: 0xFF6B35)
    static let draftAccent = Color(hex: 0x8E8E93)
    static let inReviewAccent = Color(hex: 0xFF9F0A)
    static let validationAccent = Color(hex: 0x0A84FF)
    static let approvedAccent = Color(hex: 0x30D158)
    static let mergedAccent = Color(hex: 0xBF5AF2)

    // Per-card validation status colors
    static let ciRunningColor = Color(hex: 0xFF9F0A)  // amber
    static let ciFailedColor = Color(hex: 0xFF453A)    // red

    // MARK: - Spacing

    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let columnCornerRadius: CGFloat = 14
    static let columnPadding: CGFloat = 10
    static let columnSpacing: CGFloat = 12

    // MARK: - Typography

    static let repoFont = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let metaFont = Font.system(size: 11)
    static let metaMonoFont = Font.system(size: 11, design: .monospaced)
    static let columnHeaderFont = Font.system(size: 11, weight: .semibold)
    static let countBadgeFont = Font.system(size: 10, weight: .bold, design: .rounded)
    static let filterFont = Font.system(size: 12, weight: .medium)
    static let toolbarTitleFont = Font.system(size: 15, weight: .semibold)
}

// MARK: - Pointer Cursor

extension View {
    /// Sets the cursor to a pointing hand on hover — use on all clickable non-system controls.
    func pointingHand() -> some View {
        self.onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
