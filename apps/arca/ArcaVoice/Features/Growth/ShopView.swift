import SwiftUI
import ArcaVoiceKit

/// The shop: coats for the companion, bought with coins that only real work
/// earns. The earn table is on the page so it never feels arbitrary.
struct ShopView: View {
    @State private var progress = CompanionProgress.shared
    @State private var wearing = ArcaSkins.current.id
    @State private var shortFor: String?

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    ArcaFace(mood: .happy, size: 90, halo: true, interactive: true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("상점", "Shop"))
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(L("코인은 일을 해야 생겨요 — 회의를 요약하고, 리포트를 받고, 할 일을 끝내면.",
                               "Coins come from work — summarize meetings, get reports, finish to-dos."))
                            .font(.callout).foregroundStyle(.white.opacity(0.6))
                        LevelStrip(progress: progress)
                    }
                    Spacer()
                }

                Text(L("코트", "Coats")).font(.system(.headline, design: .rounded, weight: .bold))
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ArcaSkins.all) { skin in
                        let price = SkinPricing.price(for: skin.id)
                        let owned = progress.owns(skinId: skin.id)
                        ShopSkinCard(skin: skin, price: price, owned: owned, wearing: wearing == skin.id,
                                     short: shortFor == skin.id) {
                            if owned {
                                withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
                                    ArcaSkins.select(skin); wearing = skin.id
                                }
                            } else if progress.buySkin(skin.id, price: price) {
                                withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
                                    ArcaSkins.select(skin); wearing = skin.id
                                }
                            } else {
                                withAnimation { shortFor = skin.id }
                                Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(1.6))
                                    withAnimation { shortFor = nil }
                                }
                            }
                        }
                    }
                }

                Text(L("코인 버는 법", "How coins are earned")).font(.system(.headline, design: .rounded, weight: .bold))
                VStack(spacing: 6) {
                    ForEach(CompanionProgress.Event.allCases.filter { $0.coins > 0 }, id: \.self) { event in
                        HStack {
                            Text(event.label).font(.callout)
                            Spacer()
                            Text("+\(event.xp) XP").font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                            Label("+\(event.coins)", systemImage: "circle.hexagongrid.circle.fill")
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(Color(hex: 0xFFC531))
                                .frame(width: 60, alignment: .trailing)
                            Text(L("\(progress.count(event))회", "\(progress.count(event))×"))
                                .font(.caption2).foregroundStyle(.white.opacity(0.35))
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(24)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .arcaSkinChanged)) { _ in
            wearing = ArcaSkins.current.id
        }
    }
}

private struct ShopSkinCard: View {
    let skin: ArcaSkin
    let price: Int
    let owned: Bool
    let wearing: Bool
    let short: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ArcaFace(mood: wearing ? .happy : .idle, size: 76, halo: false, skinOverride: skin)
                    .frame(height: 84)
                    .saturation(owned ? 1 : 0.35)
                    .opacity(owned ? 1 : 0.7)
                Text(skin.name).font(.subheadline.weight(.bold))
                Text(skin.flavor).font(.caption2).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Group {
                    if wearing {
                        Text(L("착용 중", "WEARING"))
                    } else if owned {
                        Text(L("착용하기", "WEAR"))
                    } else if short {
                        Text(L("코인이 부족해요", "NOT ENOUGH COINS"))
                    } else {
                        Label("\(price)", systemImage: "circle.hexagongrid.circle.fill")
                    }
                }
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(wearing ? AnyShapeStyle(skin.mid) : short ? AnyShapeStyle(Color.orange.opacity(0.8)) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                .foregroundStyle(owned || short ? .white : Color(hex: 0xFFC531))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if wearing {
                    RoundedRectangle(cornerRadius: 18).strokeBorder(skin.mid, lineWidth: 2)
                        .shadow(color: skin.mid.opacity(0.6), radius: 6)
                }
            }
        }
        .buttonStyle(.arcaPress)
    }
}
