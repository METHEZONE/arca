import Foundation

/// ARCA skin palettes as raw RGB — UI-framework-free so the app target and
/// the widget extension render the same coat. Values from the brand site's
/// spirit variations (app/arca/page.tsx).
public struct SkinPalette: Sendable, Equatable {
    public struct RGB: Sendable, Equatable {
        public let r: Double, g: Double, b: Double
        public init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
    }

    public let id: String
    public let name: String
    public let flavor: String
    public let hi: RGB
    public let mid: RGB
    public let lo: RGB
    public let fin: RGB

    public static let all: [SkinPalette] = [
        SkinPalette(id: "ember", name: "Ember", flavor: "The original flame.",
                    hi: RGB(0xff9d6b), mid: RGB(0xf75b2b), lo: RGB(0xe2331a), fin: RGB(0xe2331a)),
        SkinPalette(id: "tide", name: "Tide", flavor: "Deep-water calm.",
                    hi: RGB(0x7da9f5), mid: RGB(0x477ee9), lo: RGB(0x2f5fc4), fin: RGB(0x2f5fc4)),
        SkinPalette(id: "blossom", name: "Blossom", flavor: "Sharp and sweet.",
                    hi: RGB(0xff7d9c), mid: RGB(0xfb2d54), lo: RGB(0xd11840), fin: RGB(0xd11840)),
        SkinPalette(id: "moss", name: "Moss", flavor: "Grows on you.",
                    hi: RGB(0x6fe0a2), mid: RGB(0x34c771), lo: RGB(0x1f9e54), fin: RGB(0x1f9e54)),
        SkinPalette(id: "aurum", name: "Aurum", flavor: "Money never blinks.",
                    hi: RGB(0xffd37a), mid: RGB(0xf0a72b), lo: RGB(0xc97f0e), fin: RGB(0xc97f0e)),
        SkinPalette(id: "wisp", name: "Wisp", flavor: "A ghost of the deep night.",
                    hi: RGB(0x9ff5f0), mid: RGB(0x2ed3de), lo: RGB(0x0e7c8c), fin: RGB(0x0e7c8c)),
    ]

    public static let defaultsKey = "arcaSkin"

    /// The wearer's current palette, shared through the App Group.
    public static var current: SkinPalette {
        let store = UserDefaults(suiteName: SharedInbox.appGroupID) ?? .standard
        let id = store.string(forKey: defaultsKey) ?? "ember"
        return all.first { $0.id == id } ?? all[0]
    }

    public init(id: String, name: String, flavor: String, hi: RGB, mid: RGB, lo: RGB, fin: RGB) {
        self.id = id
        self.name = name
        self.flavor = flavor
        self.hi = hi
        self.mid = mid
        self.lo = lo
        self.fin = fin
    }
}
