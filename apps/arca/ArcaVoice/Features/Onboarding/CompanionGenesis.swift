import Foundation
import ArcaVoiceKit

/// How a companion is born. A Swift port of the web hatchery's generator
/// (`lib/companion/generate.ts`): the same three answers plus a salt always
/// hatch the same companion, so a re-roll is a real re-roll and a restore is
/// a faithful one. The PRNG is mulberry32 over an xxhash-style string hash,
/// reproduced bit-for-bit with wrapping UInt32 arithmetic.
enum CompanionGenesis {
    enum Pace: String, CaseIterable, Codable {
        case careful, steady, swift

        var label: String {
            switch self {
            case .swift: return L("바로 실행한다 — 속도가 생명", "Act first — speed is life")
            case .steady: return L("정리부터 한다 — 기록이 먼저", "Organize first — the record comes first")
            case .careful: return L("신중히 검토한다 — 실수는 비싸다", "Review carefully — mistakes are expensive")
            }
        }
        var symbol: String {
            switch self {
            case .swift: return "bolt.fill"
            case .steady: return "list.bullet.rectangle.fill"
            case .careful: return "magnifyingglass"
            }
        }
    }

    enum Tone: String, CaseIterable, Codable {
        case formal, warm, plain

        var label: String {
            switch self {
            case .formal: return L("깍듯한 존댓말", "Formal and polished")
            case .warm: return L("친근한 존댓말", "Friendly and warm")
            case .plain: return L("짧고 담백하게", "Short and plain")
            }
        }
        var sample: String {
            switch self {
            case .formal: return L("「확인 후 정리해 회신드리겠습니다.」", "“I'll review, organize, and get back to you.”")
            case .warm: return L("「확인해서 정리해둘게요!」", "“I'll check and tidy it up for you!”")
            case .plain: return L("「확인 후 회신드립니다.」", "“Reviewing. Will reply.”")
            }
        }
    }

    /// What the owner wants most — steers the first quest and the greeting,
    /// not the roll itself.
    enum Focus: String, CaseIterable, Codable {
        case meetings, flow, memory, day

        var label: String {
            switch self {
            case .meetings: return L("회의를 대신 기억해줘", "Remember my meetings for me")
            case .flow: return L("내 몰입을 지켜줘", "Guard my focus")
            case .memory: return L("나에 대해 알아가줘", "Get to know me")
            case .day: return L("내 하루를 정리해줘", "Make sense of my day")
            }
        }
        var symbol: String {
            switch self {
            case .meetings: return "waveform"
            case .flow: return "moon.zzz.fill"
            case .memory: return "brain.head.profile"
            case .day: return "sun.horizon.fill"
            }
        }
    }

    /// Gacha tiers. Weights are the roll odds out of 100.
    enum Rarity: String, CaseIterable, Codable {
        case common, rare, epic, legendary

        static func roll(_ rnd: inout Mulberry32) -> Rarity {
            let r = rnd.next() * 100
            if r < 2 { return .legendary }
            if r < 12 { return .epic }
            if r < 40 { return .rare }
            return .common
        }

        var stars: Int {
            switch self {
            case .common: return 1
            case .rare: return 2
            case .epic: return 3
            case .legendary: return 4
            }
        }
        var label: String {
            switch self {
            case .common: return L("커먼", "COMMON")
            case .rare: return L("레어", "RARE")
            case .epic: return L("에픽", "EPIC")
            case .legendary: return L("레전더리", "LEGENDARY")
            }
        }
        /// Hex tint for the tier banner and aura.
        var tintHex: UInt32 {
            switch self {
            case .common: return 0x9aa4b2
            case .rare: return 0x5aa9ff
            case .epic: return 0xb99bff
            case .legendary: return 0xffd37a
            }
        }
    }

    struct Profile: Codable, Equatable {
        var pace: Pace
        var tone: Tone
        var focus: Focus
    }

    struct Spec: Equatable {
        let seed: UInt32
        let rarity: Rarity
        let skinId: String
        let archetype: String
        let traits: [String]
        let nameCandidates: [String]
        let voiceLine: String
    }

    // MARK: - Vocabulary (1:1 with generate.ts)

    private static let nameHeads = ["아", "루", "코", "모", "노", "비", "포", "미", "오", "제", "토", "무"]
    private static let nameTails = ["루", "비", "코", "미", "무", "니", "타", "로", "키", "디", "보", "리"]
    private static let nameCaps = ["", "", "", "", "니", "리", "토", "미"]

    private static let archetypes: [Pace: [Tone: (name: String, traits: [String])]] = [
        .careful: [
            .formal: ("집사형 가디언", ["차분함", "꼼꼼함", "기록광"]),
            .warm: ("사서형 단짝", ["다정함", "신중함", "수집벽"]),
            .plain: ("관측자형 파수꾼", ["과묵함", "정확함", "인내심"]),
        ],
        .steady: [
            .formal: ("비서실장형", ["정돈됨", "균형감", "보고 정신"]),
            .warm: ("길잡이형 동료", ["싹싹함", "정리력", "눈치 백단"]),
            .plain: ("정찰병형 실무가", ["간결함", "판단력", "실행력"]),
        ],
        .swift: [
            .formal: ("의전형 해결사", ["기민함", "예의 바름", "추진력"]),
            .warm: ("탐험가형 친구", ["호기심", "명랑함", "돌파력"]),
            .plain: ("번개형 해결사", ["속도", "단호함", "집중력"]),
        ],
    ]

    private static let voiceLines: [Tone: String] = [
        .formal: "다녀왔습니다. 자리를 비우신 동안 세 건을 마무리해 두었습니다.",
        .warm: "다녀왔어요! 급한 세 건은 제가 처리해뒀고, 나머지는 골라두기만 했어요.",
        .plain: "복귀 보고. 3건 처리 완료, 1건은 판단 대기.",
    ]

    // MARK: - Generation

    static func generate(profile: Profile, salt: Int) -> Spec {
        let seedInput = [profile.pace.rawValue, profile.tone.rawValue, profile.focus.rawValue, String(salt)]
            .joined(separator: "|")
        let seed = hashString(seedInput)
        var rnd = Mulberry32(seed: seed)

        let rarity = Rarity.roll(&rnd)
        let skin = pick(&rnd, SkinPalette.all).id
        let archetype = archetypes[profile.pace]![profile.tone]!

        var names: [String] = []
        while names.count < 4 {
            let name = makeName(&rnd)
            if !names.contains(name) { names.append(name) }
        }

        return Spec(seed: seed, rarity: rarity, skinId: skin, archetype: archetype.name,
                    traits: archetype.traits, nameCandidates: names,
                    voiceLine: voiceLines[profile.tone]!)
    }

    static func greeting(tone: Tone, ownerName: String, companionName: String) -> String {
        let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let you = owner.isEmpty ? L("당신", "you") : owner
        switch tone {
        case .formal:
            return L("처음 뵙겠습니다, \(you). 저는 \(companionName)입니다. 이제 \(you)의 ZONE은 제가 지킵니다.",
                     "A pleasure to meet you, \(you). I'm \(companionName). Your ZONE is mine to guard now.")
        case .warm:
            return L("안녕하세요, \(you)! 저는 \(companionName)이에요. 앞으로 몰입은 제가 지켜드릴게요.",
                     "Hi \(you)! I'm \(companionName). From here on, I'll guard your focus.")
        case .plain:
            return L("\(companionName)입니다. \(you)의 ZONE, 지금부터 제가 지킵니다.",
                     "\(companionName). Your ZONE — I've got it from here.")
        }
    }

    private static func makeName(_ rnd: inout Mulberry32) -> String {
        pick(&rnd, nameHeads) + pick(&rnd, nameTails) + pick(&rnd, nameCaps)
    }

    private static func pick<T>(_ rnd: inout Mulberry32, _ array: [T]) -> T {
        array[Int(rnd.next() * Double(array.count))]
    }

    /// `hashString` from generate.ts — UTF-16 code units, like JS charCodeAt.
    static func hashString(_ string: String) -> UInt32 {
        let units = Array(string.utf16)
        var h = UInt32(1779033703) ^ UInt32(units.count)
        for unit in units {
            h = (h ^ UInt32(unit)) &* 3432918353
            h = (h << 13) | (h >> 19)
        }
        h = (h ^ (h >> 16)) &* 2246822507
        h = (h ^ (h >> 13)) &* 3266489909
        return h ^ (h >> 16)
    }

    struct Mulberry32 {
        private var a: UInt32
        init(seed: UInt32) { a = seed }

        /// Uniform in [0, 1).
        mutating func next() -> Double {
            a = a &+ 0x6d2b79f5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4294967296
        }
    }
}

/// The hatched companion as the account remembers it. One record per
/// account, so switching accounts switches companions.
struct HatchedCompanion: Codable, Equatable {
    var name: String
    var archetype: String
    var traits: [String]
    var rarity: CompanionGenesis.Rarity
    var skinId: String
    var seed: UInt32
    var profile: CompanionGenesis.Profile
    var hatchedAt: Date

    private static let key = "hatchedCompanion"

    static func load() -> HatchedCompanion? {
        guard let raw = AccountDefaults.string(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HatchedCompanion.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self), let raw = String(data: data, encoding: .utf8) else { return }
        AccountDefaults.set(raw, for: Self.key)
    }
}
