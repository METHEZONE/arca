import SwiftUI

/// Design tokens. Motion and color language for ARCA —
/// fun to use is a spec, not a nice-to-have.
enum ArcaTheme {
    static let recording = Color(red: 0.95, green: 0.26, blue: 0.21)
    static let idle = Color(red: 0.13, green: 0.55, blue: 0.95)

    /// ARCA's face color: the glowing cyan of a friendly pixel-display robot.
    static let pixel = Color(red: 0.32, green: 0.91, blue: 0.90)

    /// The deep-night backdrop the spirit floats on (iPhone home).
    static let spiritNight = Color(red: 0.03, green: 0.05, blue: 0.09)

    /// Speaker orb palette — assigned in order of first appearance.
    static let speakerColors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .mint,
    ]
}

/// ARCA's digital eyes: chunky pixel blobs on its "screen", glowing cyan —
/// the friendly robot-pet look. Draw at small sizes (8–24pt); the pixel grid
/// stays readable because cells are large relative to the eye.
enum PixelEyes {
    /// A round pixel eye (the resting/idle expression).
    static var round: some View {
        PixelBlob(pattern: PixelBlob.roundEye)
            .fill(ArcaTheme.pixel)
            .shadow(color: ArcaTheme.pixel.opacity(0.75), radius: 1.5)
    }

    /// A happy ^-shaped pixel eye.
    static var happy: some View {
        PixelBlob(pattern: PixelBlob.happyEye)
            .fill(ArcaTheme.pixel)
            .shadow(color: ArcaTheme.pixel.opacity(0.75), radius: 1.5)
    }
}

/// Fills the "on" cells of a small pixel grid. Cells overlap by a hair so
/// antialiasing doesn't draw seams between them.
struct PixelBlob: Shape {
    let pattern: [[Bool]]

    static let roundEye: [[Bool]] = [
        [false, true, true, false],
        [true, true, true, true],
        [true, true, true, true],
        [false, true, true, false],
    ]

    static let happyEye: [[Bool]] = [
        [false, true, true, false],
        [true, false, false, true],
        [true, false, false, true],
        [false, false, false, false],
    ]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let rows = pattern.count
        let cols = pattern.first?.count ?? 0
        guard rows > 0, cols > 0 else { return path }
        let cellW = rect.width / CGFloat(cols)
        let cellH = rect.height / CGFloat(rows)
        for (r, row) in pattern.enumerated() {
            for (c, on) in row.enumerated() where on {
                path.addRect(CGRect(
                    x: rect.minX + CGFloat(c) * cellW,
                    y: rect.minY + CGFloat(r) * cellH,
                    width: cellW + 0.4,
                    height: cellH + 0.4))
            }
        }
        return path
    }
}
