import SwiftUI
import ArcaVoiceKit

/// ARCA's skins — same creature, different coats. Palettes live in
/// ArcaVoiceCore (SkinPalette) so the widget wears the same one; this wraps
/// them in SwiftUI colors and owns selection.
struct ArcaSkin: Identifiable, Equatable {
    let id: String
    let name: String
    let flavor: String
    let hi: Color
    let mid: Color
    let lo: Color
    let fin: Color

    init(_ palette: SkinPalette) {
        id = palette.id
        name = palette.name
        flavor = palette.flavor
        hi = Color(red: palette.hi.r, green: palette.hi.g, blue: palette.hi.b)
        mid = Color(red: palette.mid.r, green: palette.mid.g, blue: palette.mid.b)
        lo = Color(red: palette.lo.r, green: palette.lo.g, blue: palette.lo.b)
        fin = Color(red: palette.fin.r, green: palette.fin.g, blue: palette.fin.b)
    }
}

enum ArcaSkins {
    static let all: [ArcaSkin] = SkinPalette.all.map(ArcaSkin.init)

    static var current: ArcaSkin { ArcaSkin(SkinPalette.current) }

    static func select(_ skin: ArcaSkin) {
        let store = UserDefaults(suiteName: SharedInbox.appGroupID) ?? .standard
        store.set(skin.id, forKey: SkinPalette.defaultsKey)
        NotificationCenter.default.post(name: .arcaSkinChanged, object: nil)
    }

    /// The gacha: never rolls the one you're wearing.
    static func roll() -> ArcaSkin {
        let others = all.filter { $0.id != current.id }
        let picked = others.randomElement() ?? all[0]
        select(picked)
        return picked
    }
}

extension Notification.Name {
    static let arcaSkinChanged = Notification.Name("arca.skinChanged")
}
