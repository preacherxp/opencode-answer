import SwiftUI

/// OpenCode's default TUI theme: near-black grounds, monospace text, peach and blue accents.
enum Theme {
    static let background = Color(hex: 0x0A0A0A)
    static let panel = Color(hex: 0x141414)
    static let element = Color(hex: 0x1E1E1E)
    static let border = Color(hex: 0x282828)
    static let text = Color(hex: 0xEEEEEE)
    static let muted = Color(hex: 0x808080)
    static let primary = Color(hex: 0xFAB283)
    static let secondary = Color(hex: 0x5C9CF5)
    static let success = Color(hex: 0x7FD88F)
    static let error = Color(hex: 0xE06C75)

    static let size: CGFloat = 13

    static func mono(_ weight: Font.Weight = .regular, size: CGFloat = size) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
