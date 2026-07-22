import Foundation
import SwiftUI
import SwiftData

/// A compact "Memory Brain" teaser for a home/dashboard screen — a small
/// live preview of the graph (no gestures, just the drift), with a title,
/// note/link counts, and a chevron. Purely presentational: whoever places
/// this card wires `onTap` to push the full `BrainView`.
struct BrainPreviewCard: View {
    let context: ModelContext
    var onTap: (() -> Void)?

    @State private var engine = BrainEngine()
    @State private var lastTickDate: Date?
    @State private var totalNodeCount = 0
    @State private var totalEdgeCount = 0

    private let fixedDt: Double = 1.0 / 60.0
    private let background = Color(red: 0.03, green: 0.05, blue: 0.09)
    private let ember = Color(red: 1.0, green: 0.478, blue: 0.102)
    private static let maxPreviewNodes = 30

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 14) {
                miniCanvas
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory Brain")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(totalNodeCount) notes · \(totalEdgeCount) links")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.thinMaterial))
        }
        .buttonStyle(.arcaPress)
        .task {
            engine.load(context: context)
            totalNodeCount = engine.nodes.count
            totalEdgeCount = engine.edges.count
            // Keep the mini simulation cheap — the counts above still
            // reflect the whole brain, only the drawn subset is trimmed.
            if engine.nodes.count > Self.maxPreviewNodes {
                engine.nodes = Array(engine.nodes.prefix(Self.maxPreviewNodes))
                let survivingIds = Set(engine.nodes.map(\.id))
                engine.edges = engine.edges.filter { survivingIds.contains($0.a) && survivingIds.contains($0.b) }
            }
        }
    }

    private var miniCanvas: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                drawMini(&ctx, size: size, date: timeline.date)
            }
            .onChange(of: timeline.date) { _, newDate in step(now: newDate, size: CGSize(width: 64, height: 64)) }
        }
    }

    private func step(now: Date, size: CGSize) {
        defer { lastTickDate = now }
        guard let last = lastTickDate else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        let steps = min(3, max(1, Int((elapsed / fixedDt).rounded())))
        for _ in 0..<steps { engine.tick(size: size) }
    }

    private func drawMini(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        guard !engine.nodes.isEmpty else { return }
        let t = date.timeIntervalSinceReferenceDate
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(engine.nodes.count)
        for node in engine.nodes { positions[node.id] = node.position }

        for edge in engine.edges {
            guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            if edge.isInsight {
                let phase = Double(abs(edge.id.hashValue % 628)) / 100.0
                let pulse = 0.6 + 0.4 * sin(t * 1.4 + phase)
                ctx.stroke(path, with: .color(ember.opacity(0.45 + 0.4 * pulse)), lineWidth: 1.2)
            } else {
                ctx.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 0.6)
            }
        }

        var insightNodeIds = Set<String>()
        for edge in engine.edges where edge.isInsight {
            insightNodeIds.insert(edge.a); insightNodeIds.insert(edge.b)
        }

        for node in engine.nodes {
            let glowing = node.kind == .insight || insightNodeIds.contains(node.id)
            let radius = CGFloat(2 + 2.5 * min(max(node.weight, 0), 1))
            let rect = CGRect(x: node.position.x - radius, y: node.position.y - radius,
                               width: radius * 2, height: radius * 2)
            if glowing {
                ctx.fill(Path(ellipseIn: rect), with: .color(ember))
            } else if node.kind == .session {
                ctx.stroke(Path(ellipseIn: rect), with: .color(ember.opacity(0.8)), lineWidth: 1)
            } else {
                ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.85)))
            }
        }
    }
}
