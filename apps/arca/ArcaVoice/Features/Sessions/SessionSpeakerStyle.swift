import SwiftUI

enum SessionSpeakerStyle {
    static func color(for name: String) -> Color {
        let value = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return ArcaTheme.speakerColors[abs(value) % ArcaTheme.speakerColors.count]
    }

    static func hexColor(for name: String) -> String {
        let palette = [
            "#7C3AED", "#2563EB", "#059669", "#D97706",
            "#DC2626", "#0891B2", "#9333EA", "#16A34A",
        ]
        let value = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[abs(value) % palette.count]
    }
}
