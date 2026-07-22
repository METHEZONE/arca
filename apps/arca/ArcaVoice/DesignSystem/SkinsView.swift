import SwiftUI

/// The skin locker — same ARCA, different coats. Tap to wear one, or hit
/// Roll and let fate pick (it never lands on what you're already wearing).
struct SkinsView: View {
    @State private var wearing = ArcaSkins.current.id
    @State private var rolling = false
    @State private var rollFace = 0
    @State private var rollTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                // The stage: whoever you're wearing, front and center.
                ZStack {
                    Circle()
                        .fill(ArcaSkins.current.mid.opacity(0.12))
                        .frame(width: 220, height: 220)
                    if rolling {
                        ArcaFace(mood: .happy, size: 150, halo: true,
                                 skinOverride: ArcaSkins.all[rollFace % ArcaSkins.all.count])
                            .id(rollFace)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        ArcaFace(mood: .happy, size: 150)
                    }
                }
                .frame(height: 230)

                Button {
                    roll()
                } label: {
                    Label(rolling ? "Rolling…" : "Roll the dice", systemImage: "dice.fill")
                        .font(.headline)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(ArcaSkins.current.mid, in: Capsule())
                        .foregroundStyle(.white)
                        .shadow(color: ArcaSkins.current.mid.opacity(0.5), radius: 8)
                }
                .buttonStyle(.arcaPress)
                // No .disabled(rolling) — tapping again mid-roll cancels and
                // restarts the reel instead of going dead until it settles.

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(ArcaSkins.all) { skin in
                        SkinCard(skin: skin, isWorn: wearing == skin.id) {
                            withAnimation(.spring(duration: 0.35, bounce: 0.4)) {
                                ArcaSkins.select(skin)
                                wearing = skin.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 18)
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.09).ignoresSafeArea())
        .navigationTitle("Skins")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The gacha: spin through faces, ease out, land on the rolled skin.
    /// Cancels any roll already in flight so a mid-spin tap restarts the
    /// reel cleanly instead of queuing behind (or being blocked by) it.
    private func roll() {
        rollTask?.cancel()
        rolling = true
        rollTask = Task { @MainActor in
            var delay = 70.0
            for i in 1...14 {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.14)) { rollFace += 1 }
                try? await Task.sleep(for: .milliseconds(Int(delay)))
                if i > 8 { delay *= 1.35 } // ease out — the reel slows down
            }
            guard !Task.isCancelled else { return }
            let landed = ArcaSkins.roll()
            wearing = landed.id
            withAnimation(.spring(duration: 0.4, bounce: 0.55)) { rolling = false }
        }
    }
}

private struct SkinCard: View {
    let skin: ArcaSkin
    let isWorn: Bool
    let onWear: () -> Void

    var body: some View {
        Button(action: onWear) {
            VStack(spacing: 8) {
                ArcaFace(mood: isWorn ? .happy : .idle, size: 76, halo: false,
                         skinOverride: skin)
                    .frame(height: 84)
                Text(skin.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(skin.flavor)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Text(isWorn ? "WEARING" : "WEAR")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(isWorn ? AnyShapeStyle(skin.mid) : AnyShapeStyle(.white.opacity(0.1)),
                                in: Capsule())
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if isWorn {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(skin.mid, lineWidth: 2)
                        .shadow(color: skin.mid.opacity(0.6), radius: 6)
                }
            }
        }
        .buttonStyle(.arcaPress)
    }
}

#Preview {
    NavigationStack { SkinsView() }
}
