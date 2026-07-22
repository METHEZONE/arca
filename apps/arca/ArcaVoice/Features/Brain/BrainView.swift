import Foundation
import SwiftUI
import SwiftData

/// The living map: an Obsidian-graph-like view of the user's memories and
/// session notes, connected by shared keywords, with AI-discovered
/// connections ("weave insights") glowing ember on top. Canvas-only drawing
/// so the force simulation can run at 60fps without layout thrash.
struct BrainView: View {
    var searchQuery: String = ""

    @Environment(\.modelContext) private var context
    @State private var engine = BrainEngine()

    @State private var offset: CGSize = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var pinchDelta: CGFloat = 1.0
    @State private var lastTickDate: Date?
    @State private var pulseOn = false

    private let fixedDt: Double = 1.0 / 60.0
    private let background = Color(red: 0.02, green: 0.02, blue: 0.03)
    private let ember = Color(red: 1.0, green: 0.478, blue: 0.102)
    /// DESIGN.md tokens: warm off-white #ffedd7, copper #dc5000.
    private let offWhite = Color(red: 1.0, green: 0.929, blue: 0.843)
    private let copper = Color(red: 0.863, green: 0.314, blue: 0.0)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background.ignoresSafeArea()

                // Inside-the-skull depth: a faint warm core and darkened rim.
                // Static gradients — zero per-frame cost.
                RadialGradient(colors: [copper.opacity(0.07), .clear],
                               center: .center, startRadius: 0,
                               endRadius: min(geo.size.width, geo.size.height) * 0.55)
                    .ignoresSafeArea()
                RadialGradient(colors: [.clear, .black.opacity(0.55)],
                               center: .center,
                               startRadius: min(geo.size.width, geo.size.height) * 0.38,
                               endRadius: max(geo.size.width, geo.size.height) * 0.75)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                if engine.nodes.isEmpty {
                    emptyState
                } else {
                    graphCanvas(size: geo.size)
                }

                VStack {
                    HStack {
                        brainStatus
                        Spacer()
                        weaveControls
                    }
                    Spacer()
                    selectionCard
                }
                .padding()
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: engine.selectedNode)
            .animation(.easeInOut(duration: 0.3), value: engine.lastError)
            .task { engine.load(context: context) }
        }
    }

    // MARK: - Canvas + gestures

    private func graphCanvas(size: CGSize) -> some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, canvasSize in
                draw(&ctx, size: canvasSize, date: timeline.date)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in handleTap(at: value.location) })
            .onChange(of: timeline.date) { _, newDate in step(now: newDate, size: size) }
        }
        .scaleEffect(zoom * pinchDelta)
        .offset(x: offset.width + dragTranslation.width, y: offset.height + dragTranslation.height)
        .gesture(panGesture)
        .simultaneousGesture(zoomGesture)
        .clipped()
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragTranslation = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
                dragTranslation = .zero
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in pinchDelta = value }
            .onEnded { value in
                zoom = min(max(zoom * value, 0.5), 2.5)
                pinchDelta = 1
            }
    }

    private func handleTap(at point: CGPoint) {
        var closest: (id: String, dist: CGFloat)?
        for node in engine.nodes {
            let dx = node.position.x - point.x, dy = node.position.y - point.y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist <= 24, (closest == nil || dist < closest!.dist) {
                closest = (node.id, dist)
            }
        }
        engine.selectedNode = closest?.id
    }

    private func step(now: Date, size: CGSize) {
        defer { lastTickDate = now }
        guard let last = lastTickDate else { return }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return }
        let steps = min(3, max(1, Int((elapsed / fixedDt).rounded())))
        for _ in 0..<steps { engine.tick(size: size) }
    }

    // MARK: - Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(engine.nodes.count)
        for node in engine.nodes { positions[node.id] = node.position }

        let hasSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        for edge in engine.edges {
            guard let a = positions[edge.a], let b = positions[edge.b] else { continue }
            if hasSearch {
                let highlighted = engine.nodeMatches(edge.a, query: searchQuery)
                    || engine.nodeMatches(edge.b, query: searchQuery)
                ctx.drawLayer { layer in
                    layer.opacity = highlighted ? 1 : 0.25
                    drawEdge(&layer, a: a, b: b, edge: edge, t: t)
                }
            } else {
                drawEdge(&ctx, a: a, b: b, edge: edge, t: t)
            }
        }

        var insightNodeIds = Set<String>()
        for edge in engine.edges where edge.isInsight {
            insightNodeIds.insert(edge.a); insightNodeIds.insert(edge.b)
        }
        let labeled = labelNodeIds()

        for node in engine.nodes {
            let glowing = node.kind == .insight || insightNodeIds.contains(node.id)
            let highlighted = !hasSearch || engine.nodeMatches(node.id, query: searchQuery)
            var renderNode = node
            if hasSearch, highlighted {
                renderNode.weight = min(1, renderNode.weight + 0.18)
            }
            ctx.drawLayer { layer in
                layer.opacity = highlighted ? 1 : 0.25
                drawNode(&layer, node: renderNode, glowing: glowing, selected: node.id == engine.selectedNode, t: t)
                if labeled.contains(node.id) || (hasSearch && highlighted) {
                    drawLabel(&layer, node: renderNode)
                }
            }
        }

        drawFirings(&ctx, positions: positions)
    }

    private func labelNodeIds() -> Set<String> {
        var ids = Set<String>()
        for id in engine.nodes.sorted(by: { $0.weight > $1.weight }).prefix(5).map(\.id) { ids.insert(id) }
        if let selected = engine.selectedNode {
            ids.insert(selected)
            for edge in engine.edgesTouching(selected) { ids.insert(edge.a); ids.insert(edge.b) }
        }
        return ids
    }

    private func drawEdge(_ ctx: inout GraphicsContext, a: CGPoint, b: CGPoint, edge: BrainEngine.Edge, t: Double) {
        let path = curvedPath(from: a, to: b, seedId: edge.id)
        if edge.isInsight {
            let phase = Double(abs(edge.id.hashValue % 628)) / 100.0
            let pulse = 0.6 + 0.4 * sin(t * 1.4 + phase)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [ember, ember.opacity(0.2)]), startPoint: a, endPoint: b)
            ctx.drawLayer { layer in
                layer.opacity = 0.5 * pulse
                layer.addFilter(.blur(radius: 7))
                layer.stroke(path, with: shading, lineWidth: CGFloat(5 + edge.strength * 5))
            }
            ctx.drawLayer { layer in
                layer.opacity = 0.55 + 0.45 * pulse
                layer.stroke(path, with: shading, lineWidth: CGFloat(1.25 + edge.strength * 1.5))
            }
        } else {
            // A synapse, not a wire: warm gradient, visible but quiet, with a
            // soft under-glow on the strong ones.
            let strength = min(max(edge.strength, 0), 1)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [offWhite.opacity(0.35), copper.opacity(0.5)]),
                startPoint: a, endPoint: b)
            if strength > 0.55 {
                ctx.drawLayer { layer in
                    layer.opacity = 0.12
                    layer.addFilter(.blur(radius: 4))
                    layer.stroke(path, with: shading, lineWidth: CGFloat(2.5 + strength * 2.5))
                }
            }
            ctx.drawLayer { layer in
                layer.opacity = 0.30 + 0.35 * strength
                layer.stroke(path, with: shading, lineWidth: CGFloat(0.8 + strength * 1.4))
            }
        }
    }

    /// The traveling spark of a synapse firing — a bright dot running the
    /// edge's curve with a warm tail.
    private func drawFirings(_ ctx: inout GraphicsContext, positions: [String: CGPoint]) {
        for firing in engine.firings {
            guard let edge = engine.edges.first(where: { $0.id == firing.edgeId }),
                  let a = positions[edge.a], let b = positions[edge.b] else { continue }
            let progress = engine.firingProgress(firing)
            let point = pointOnCurve(from: a, to: b, seedId: edge.id, t: progress)
            let fade = sin(progress * .pi) // bright mid-flight, soft at both ends

            ctx.drawLayer { layer in
                layer.opacity = 0.5 * fade
                layer.addFilter(.blur(radius: 5))
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                           with: .color(ember))
            }
            ctx.drawLayer { layer in
                layer.opacity = 0.95 * fade
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                           with: .color(offWhite))
            }
        }
    }

    private func drawNode(_ ctx: inout GraphicsContext, node: BrainEngine.Node, glowing: Bool, selected: Bool, t: Double) {
        let radius = CGFloat(5 + 8 * min(max(node.weight, 0), 1) + 5 * node.degree)
        let center = node.position
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        if glowing {
            let phase = Double(abs(node.id.hashValue % 628)) / 100.0
            let breathe = 0.5 + 0.5 * sin(t * 1.1 + phase)
            let glowRadius = radius * CGFloat(1.9 + 0.7 * breathe)
            let glowRect = CGRect(x: center.x - glowRadius, y: center.y - glowRadius,
                                   width: glowRadius * 2, height: glowRadius * 2)
            ctx.drawLayer { layer in
                layer.opacity = 0.3 + 0.3 * breathe
                layer.addFilter(.blur(radius: 6))
                layer.fill(Path(ellipseIn: glowRect), with: .color(ember))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(ember))
        } else if node.kind == .session {
            ctx.stroke(Path(ellipseIn: rect), with: .color(ember.opacity(0.85)), lineWidth: 2)
            let innerRect = rect.insetBy(dx: radius * 0.35, dy: radius * 0.35)
            ctx.fill(Path(ellipseIn: innerRect), with: .color(ember.opacity(0.3)))
        } else {
            // A neuron, not a dot: warm core with a soft halo; hubs (higher
            // degree) glow bigger and warmer than leaf memories.
            let heat = 0.25 + 0.75 * node.degree
            let haloRadius = radius * CGFloat(1.8 + 1.4 * node.degree)
            let haloRect = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                                  width: haloRadius * 2, height: haloRadius * 2)
            ctx.drawLayer { layer in
                layer.opacity = 0.10 + 0.22 * heat
                layer.addFilter(.blur(radius: 5))
                layer.fill(Path(ellipseIn: haloRect), with: .color(copper))
            }
            ctx.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [offWhite, offWhite.opacity(0.85),
                                      copper.opacity(0.55 + 0.35 * heat)]),
                    center: CGPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.25),
                    startRadius: 0, endRadius: radius * 1.15))
        }

        if selected {
            let ringRect = rect.insetBy(dx: -5, dy: -5)
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(.white.opacity(0.65)), lineWidth: 1.5)
        }
    }

    private func drawLabel(_ ctx: inout GraphicsContext, node: BrainEngine.Node) {
        let radius = CGFloat(5 + 8 * min(max(node.weight, 0), 1) + 5 * node.degree)
        let point = CGPoint(x: node.position.x, y: node.position.y + radius + 4)
        ctx.draw(Text(node.label).font(.caption2).foregroundStyle(offWhite.opacity(0.6)), at: point, anchor: .top)
    }

    /// A gentle quadratic arc rather than a straight line — the bend is
    /// derived from the edge id so it stays put frame to frame.
    private func curvedPath(from a: CGPoint, to b: CGPoint, seedId: String) -> Path {
        var path = Path()
        path.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / dist, ny = dx / dist
        let seed = CGFloat(abs(seedId.hashValue % 1000)) / 1000.0 - 0.5
        let bend = dist * 0.18 * seed
        let control = CGPoint(x: mid.x + nx * bend, y: mid.y + ny * bend)
        path.addQuadCurve(to: b, control: control)
        return path
    }

    /// The point at parameter `t` along the same quadratic curve
    /// `curvedPath` draws — used to place a firing's traveling spark.
    private func pointOnCurve(from a: CGPoint, to b: CGPoint, seedId: String, t: Double) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / dist, ny = dx / dist
        let seed = CGFloat(abs(seedId.hashValue % 1000)) / 1000.0 - 0.5
        let bend = dist * 0.18 * seed
        let c = CGPoint(x: mid.x + nx * bend, y: mid.y + ny * bend)
        let u = CGFloat(1 - t), v = CGFloat(t)
        return CGPoint(
            x: u * u * a.x + 2 * u * v * c.x + v * v * b.x,
            y: u * u * a.y + 2 * u * v * c.y + v * v * b.y)
    }

    // MARK: - Overlays

    private var weaveControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                Task { await engine.weaveInsights(context: context) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(engine.isWeaving ? "Weaving…" : "Weave insights")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(ember.opacity(engine.isWeaving ? 0.55 : 0.85)))
                .foregroundStyle(.white)
                .opacity(pulseOn ? 0.5 : 1)
            }
            .buttonStyle(.arcaPress)
            .disabled(engine.isWeaving)

            if let error = engine.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .transition(.opacity)
            }
        }
        .onChange(of: engine.isWeaving) { _, weaving in
            if weaving {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulseOn = true
                }
            } else {
                pulseOn = false
            }
        }
        .onChange(of: engine.lastError) { _, newValue in
            guard let newValue else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                if engine.lastError == newValue { engine.lastError = nil }
            }
        }
    }

    private var brainStatus: some View {
        HStack(spacing: 8) {
            Label("\(engine.nodes.count) memories", systemImage: "brain.head.profile")
            Text("·")
                .foregroundStyle(.white.opacity(0.35))
            Text("\(engine.edges.count) links")
            Button {
                engine.load(context: context)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.arcaPress)
            .help("Reload Memory Brain")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.35)))
    }

    @ViewBuilder
    private var selectionCard: some View {
        if let id = engine.selectedNode, let node = engine.nodes.first(where: { $0.id == id }) {
            let insightLines = engine.edgesTouching(id).filter(\.isInsight).compactMap(\.insightText)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    kindBadge(node.kind)
                    Spacer()
                    Button { engine.selectedNode = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.arcaPress)
                }
                Text(node.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if !insightLines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(insightLines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(ember).frame(width: 5, height: 5).padding(.top, 5)
                                Text(line).font(.caption).foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08)))
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func kindBadge(_ kind: BrainEngine.NodeKind) -> some View {
        let label: String
        switch kind {
        case .memory: label = "Memory"
        case .session: label = "Session"
        case .insight: label = "Insight"
        }
        let tint: Color = kind == .memory ? .white : ember
        return Text(label)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.22)))
            .foregroundStyle(tint)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.25))
            Text("Your brain is empty — record, chat, connect. Memories will appear here.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                engine.load(context: context)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.arcaPress)
            .foregroundStyle(ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
