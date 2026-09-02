import Foundation
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// The brain as a room full of thoughts: every memory is a small bright
/// character — a colour and a silhouette per kind, two eyes and a mouth —
/// clustered by what it is, linked by what it shares. The layout cools and
/// stops, so a thought stays where you can click it; life comes from
/// breathing, blinking and the odd spark running a link, not from drift.
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
    @State private var confirmDelete = false

    private let fixedDt: Double = 1.0 / 60.0
    private let background = Color(red: 0.05, green: 0.06, blue: 0.11)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background.ignoresSafeArea()
                RadialGradient(colors: [Color.white.opacity(0.05), .clear],
                               center: .center, startRadius: 0,
                               endRadius: min(geo.size.width, geo.size.height) * 0.6)
                    .ignoresSafeArea()

                if engine.nodes.isEmpty {
                    emptyState
                } else {
                    graphCanvas(size: geo.size)
                }

                VStack(spacing: 10) {
                    HStack(alignment: .top) {
                        legend
                        Spacer()
                        weaveControls
                    }
                    Spacer()
                }
                .padding()

                if let id = engine.selectedNode, let node = engine.node(id) {
                    HStack {
                        Spacer()
                        detailPanel(node: node)
                            .frame(width: 320)
                            .padding(16)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: engine.selectedNode)
            .animation(.easeInOut(duration: 0.3), value: engine.lastError)
            .task { engine.load(context: context) }
        }
    }

    // MARK: - Canvas + gestures

    private func graphCanvas(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
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
        DragGesture(minimumDistance: 6)
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
        for node in engine.nodes where !engine.hiddenKinds.contains(node.kind) {
            let dx = node.position.x - point.x, dy = node.position.y - point.y
            let dist = (dx * dx + dy * dy).squareRoot()
            let reach = radius(for: node) + 14
            if dist <= reach, (closest == nil || dist < closest!.dist) {
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

    private func radius(for node: BrainEngine.Node) -> CGFloat {
        CGFloat(13 + 9 * min(max(node.weight, 0), 1) + 8 * node.degree)
    }

    private func color(for kind: BrainEngine.NodeKind) -> Color { Color(hex: kind.hex) }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(engine.nodes.count)
        var kinds: [String: BrainEngine.NodeKind] = [:]
        for node in engine.nodes { positions[node.id] = node.position; kinds[node.id] = node.kind }

        let hasSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hidden = engine.hiddenKinds
        let selected = engine.selectedNode
        let neighbors: Set<String> = selected.map { id in
            Set(engine.edgesTouching(id).flatMap { [$0.a, $0.b] })
        } ?? []

        for edge in engine.edges {
            guard let a = positions[edge.a], let b = positions[edge.b],
                  let ka = kinds[edge.a], let kb = kinds[edge.b],
                  !hidden.contains(ka), !hidden.contains(kb) else { continue }
            let touchesSelection = selected == nil || edge.a == selected || edge.b == selected
            let dim = hasSearch
                ? !(engine.nodeMatches(edge.a, query: searchQuery) || engine.nodeMatches(edge.b, query: searchQuery))
                : !touchesSelection
            ctx.drawLayer { layer in
                layer.opacity = dim ? 0.12 : 1
                drawEdge(&layer, a: a, b: b, edge: edge, colorA: color(for: ka), colorB: color(for: kb), t: t)
            }
        }

        let labeled = labelNodeIds()
        for node in engine.nodes where !hidden.contains(node.kind) {
            let matches = !hasSearch || engine.nodeMatches(node.id, query: searchQuery)
            let dimmed = hasSearch ? !matches : (selected != nil && node.id != selected && !neighbors.contains(node.id))
            ctx.drawLayer { layer in
                layer.opacity = dimmed ? 0.28 : 1
                drawThought(&layer, node: node, selected: node.id == selected, t: t)
                if labeled.contains(node.id) || (hasSearch && matches) {
                    drawLabel(&layer, node: node)
                }
            }
        }

        drawFirings(&ctx, positions: positions, kinds: kinds)
    }

    private func labelNodeIds() -> Set<String> {
        var ids = Set<String>()
        for id in engine.nodes.sorted(by: { $0.degree > $1.degree }).prefix(6).map(\.id) { ids.insert(id) }
        if let selected = engine.selectedNode {
            ids.insert(selected)
            for edge in engine.edgesTouching(selected) { ids.insert(edge.a); ids.insert(edge.b) }
        }
        return ids
    }

    private func drawEdge(_ ctx: inout GraphicsContext, a: CGPoint, b: CGPoint, edge: BrainEngine.Edge,
                          colorA: Color, colorB: Color, t: Double) {
        let path = curvedPath(from: a, to: b, seedId: edge.id)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [colorA.opacity(0.55), colorB.opacity(0.55)]), startPoint: a, endPoint: b)
        if edge.isInsight {
            let phase = Double(abs(edge.id.hashValue % 628)) / 100.0
            let pulse = 0.6 + 0.4 * sin(t * 1.4 + phase)
            ctx.drawLayer { layer in
                layer.opacity = 0.35 * pulse
                layer.addFilter(.blur(radius: 6))
                layer.stroke(path, with: .color(Color(hex: BrainEngine.NodeKind.insight.hex)), lineWidth: 6)
            }
            ctx.stroke(path, with: .color(Color(hex: BrainEngine.NodeKind.insight.hex).opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, dash: [6, 5], dashPhase: CGFloat(-t * 18)))
        } else {
            let strength = min(max(edge.strength, 0), 1)
            ctx.drawLayer { layer in
                layer.opacity = 0.35 + 0.45 * strength
                layer.stroke(path, with: shading, lineWidth: CGFloat(1.2 + strength * 1.8))
            }
        }
    }

    private func drawFirings(_ ctx: inout GraphicsContext, positions: [String: CGPoint], kinds: [String: BrainEngine.NodeKind]) {
        for firing in engine.firings {
            guard let edge = engine.edges.first(where: { $0.id == firing.edgeId }),
                  let a = positions[edge.a], let b = positions[edge.b], let kind = kinds[edge.a] else { continue }
            let progress = engine.firingProgress(firing)
            let point = pointOnCurve(from: a, to: b, seedId: edge.id, t: progress)
            let fade = sin(progress * .pi)
            ctx.drawLayer { layer in
                layer.opacity = 0.6 * fade
                layer.addFilter(.blur(radius: 4))
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                           with: .color(color(for: kind)))
            }
            ctx.drawLayer { layer in
                layer.opacity = fade
                layer.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(.white))
            }
        }
    }

    /// The character: a kind-specific silhouette, breathing, with a face.
    private func drawThought(_ ctx: inout GraphicsContext, node: BrainEngine.Node, selected: Bool, t: Double) {
        let phase = Double(abs(node.id.hashValue % 628)) / 100.0
        let breathe = 1 + 0.035 * sin(t * 1.3 + phase)
        let r = radius(for: node) * CGFloat(breathe) * (selected ? 1.18 : 1)
        let c = node.position
        let tint = color(for: node.kind)

        if selected || node.kind == .insight {
            let glow = CGRect(x: c.x - r * 1.9, y: c.y - r * 1.9, width: r * 3.8, height: r * 3.8)
            ctx.drawLayer { layer in
                layer.opacity = selected ? 0.35 : 0.18 + 0.1 * sin(t * 2 + phase)
                layer.addFilter(.blur(radius: 10))
                layer.fill(Path(ellipseIn: glow), with: .color(tint))
            }
        }

        let body = ThoughtShapes.path(kind: node.kind, center: c, radius: r, seed: phase)
        ctx.fill(body, with: .color(tint))
        // A soft top highlight so the flat shape reads as a body, not a sticker.
        ctx.drawLayer { layer in
            layer.opacity = 0.22
            layer.clip(to: body)
            layer.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.75, y: c.y - r * 1.05, width: r * 1.5, height: r * 0.9)),
                       with: .color(.white))
        }
        if selected {
            ctx.stroke(body, with: .color(.white.opacity(0.9)), lineWidth: 2)
        }

        drawFace(&ctx, center: c, radius: r, selected: selected, t: t, phase: phase, kind: node.kind)
    }

    private func drawFace(_ ctx: inout GraphicsContext, center c: CGPoint, radius r: CGFloat,
                          selected: Bool, t: Double, phase: Double, kind: BrainEngine.NodeKind) {
        let ink = Color(red: 0.08, green: 0.08, blue: 0.14)
        let eyeY = c.y - r * 0.12
        let eyeDX = r * 0.32
        // Blink every ~4s for ~120ms, offset per node.
        let cycle = (t + phase * 3).truncatingRemainder(dividingBy: 4.2)
        let blinking = cycle > 4.05
        let eyeH: CGFloat = blinking ? 1.2 : max(2.4, r * 0.2)
        let eyeW: CGFloat = max(2.4, r * 0.16)

        if selected || kind == .insight {
            // Happy arcs.
            for sign in [-1.0, 1.0] {
                var arc = Path()
                let x = c.x + CGFloat(sign) * eyeDX
                arc.move(to: CGPoint(x: x - eyeW, y: eyeY + 1))
                arc.addQuadCurve(to: CGPoint(x: x + eyeW, y: eyeY + 1), control: CGPoint(x: x, y: eyeY - eyeH * 1.6))
                ctx.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: max(1.6, r * 0.11), lineCap: .round))
            }
        } else {
            for sign in [-1.0, 1.0] {
                let x = c.x + CGFloat(sign) * eyeDX
                ctx.fill(Path(ellipseIn: CGRect(x: x - eyeW / 2, y: eyeY - eyeH / 2, width: eyeW, height: eyeH)), with: .color(ink))
            }
        }
        // Mouth: a small smile, wider when selected.
        var mouth = Path()
        let mw = r * (selected ? 0.42 : 0.28)
        let my = c.y + r * 0.28
        mouth.move(to: CGPoint(x: c.x - mw, y: my))
        mouth.addQuadCurve(to: CGPoint(x: c.x + mw, y: my), control: CGPoint(x: c.x, y: my + r * (selected ? 0.34 : 0.2)))
        ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: max(1.5, r * 0.1), lineCap: .round))
        if selected {
            // Blush.
            for sign in [-1.0, 1.0] {
                let x = c.x + CGFloat(sign) * r * 0.55
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.12, y: c.y + r * 0.05, width: r * 0.24, height: r * 0.14)),
                         with: .color(.white.opacity(0.35)))
            }
        }
    }

    private func drawLabel(_ ctx: inout GraphicsContext, node: BrainEngine.Node) {
        let r = radius(for: node)
        let point = CGPoint(x: node.position.x, y: node.position.y + r + 6)
        let label = node.label.count > 22 ? String(node.label.prefix(22)) + "…" : node.label
        ctx.draw(Text(label).font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75)), at: point, anchor: .top)
    }

    private func curvedPath(from a: CGPoint, to b: CGPoint, seedId: String) -> Path {
        var path = Path()
        path.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / dist, ny = dx / dist
        let seed = CGFloat(abs(seedId.hashValue % 1000)) / 1000.0 - 0.5
        let bend = dist * 0.18 * seed
        path.addQuadCurve(to: b, control: CGPoint(x: mid.x + nx * bend, y: mid.y + ny * bend))
        return path
    }

    private func pointOnCurve(from a: CGPoint, to b: CGPoint, seedId: String, t: Double) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let dist = max((dx * dx + dy * dy).squareRoot(), 1)
        let nx = -dy / dist, ny = dx / dist
        let seed = CGFloat(abs(seedId.hashValue % 1000)) / 1000.0 - 0.5
        let bend = dist * 0.18 * seed
        let c = CGPoint(x: mid.x + nx * bend, y: mid.y + ny * bend)
        let u = CGFloat(1 - t), v = CGFloat(t)
        return CGPoint(x: u * u * a.x + 2 * u * v * c.x + v * v * b.x,
                       y: u * u * a.y + 2 * u * v * c.y + v * v * b.y)
    }

    // MARK: - Overlays

    /// Kind chips with counts. Tap to hide/show a kind.
    private var legend: some View {
        let counts = Dictionary(grouping: engine.nodes, by: \.kind).mapValues(\.count)
        return HStack(spacing: 6) {
            ForEach(BrainEngine.NodeKind.allCases, id: \.self) { kind in
                let count = counts[kind] ?? 0
                if count > 0 {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            if engine.hiddenKinds.contains(kind) { engine.hiddenKinds.remove(kind) } else { engine.hiddenKinds.insert(kind) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            ThoughtShapeIcon(kind: kind, size: 12)
                            Text("\(kind.label) \(count)")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(color(for: kind).opacity(engine.hiddenKinds.contains(kind) ? 0.08 : 0.22)))
                        .foregroundStyle(.white.opacity(engine.hiddenKinds.contains(kind) ? 0.4 : 0.95))
                    }
                    .buttonStyle(.arcaPress)
                }
            }
            Text(L("연결 \(engine.edges.count)", "\(engine.edges.count) links"))
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 4)
        }
    }

    private var weaveControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    engine.load(context: context)
                    engine.reheat(1)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(8)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.arcaPress)
                .help(L("다시 정리", "Re-layout"))

                Button {
                    Task { await engine.weaveInsights(context: context) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(engine.isWeaving ? L("엮는 중…", "Weaving…") : L("인사이트 엮기", "Weave insights"))
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color(hex: BrainEngine.NodeKind.insight.hex).opacity(engine.isWeaving ? 0.5 : 0.9)))
                    .foregroundStyle(.white)
                    .opacity(pulseOn ? 0.5 : 1)
                }
                .buttonStyle(.arcaPress)
                .disabled(engine.isWeaving)
            }
            if let error = engine.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .transition(.opacity)
            }
        }
        .onChange(of: engine.isWeaving) { _, weaving in
            if weaving {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulseOn = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { pulseOn = false }
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

    /// The thought, in full: what it is, when it was learned, where from,
    /// what it's linked to, and what the weave said about it.
    private func detailPanel(node: BrainEngine.Node) -> some View {
        let tint = color(for: node.kind)
        let links = engine.edgesTouching(node.id)
        let insightLines = links.filter(\.isInsight).compactMap(\.insightText)
        let fullText = engine.text(for: node.id)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    ThoughtShapeIcon(kind: node.kind, size: 26, face: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.kind.label)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(tint)
                        Text(node.createdAt, format: .dateTime.year().month().day())
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer()
                Button { engine.selectedNode = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.arcaPress)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(fullText.isEmpty ? node.label : fullText)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !node.source.isEmpty {
                        Label(L("출처: \(sourceLabel(node.source))", "Source: \(sourceLabel(node.source))"), systemImage: "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                    }

                    if !insightLines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("엮인 인사이트", "Woven insights"))
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(Color(hex: BrainEngine.NodeKind.insight.hex))
                            ForEach(Array(insightLines.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "sparkle").font(.caption2).padding(.top, 3)
                                        .foregroundStyle(Color(hex: BrainEngine.NodeKind.insight.hex))
                                    Text(line).font(.caption).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                        }
                    }

                    if !links.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("연결된 생각 \(links.count)", "\(links.count) linked thoughts"))
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                            ForEach(links.prefix(8), id: \.id) { edge in
                                let otherId = edge.a == node.id ? edge.b : edge.a
                                if let other = engine.node(otherId) {
                                    Button {
                                        engine.selectedNode = otherId
                                    } label: {
                                        HStack(spacing: 8) {
                                            ThoughtShapeIcon(kind: other.kind, size: 12)
                                            Text(other.label).font(.caption).lineLimit(1)
                                                .foregroundStyle(.white.opacity(0.85))
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.white.opacity(0.3))
                                        }
                                        .padding(.horizontal, 8).padding(.vertical, 6)
                                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.arcaPress)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)

            HStack(spacing: 8) {
                CopyButton(text: { fullText.isEmpty ? node.label : fullText }, title: L("복사", "Copy"), compact: false)
                Spacer()
                if node.kind != .session {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(L("잊기", "Forget"), systemImage: "trash").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.arcaPress)
                    .foregroundStyle(.orange)
                    .confirmationDialog(L("이 기억을 지울까요?", "Forget this memory?"), isPresented: $confirmDelete) {
                        Button(L("잊기", "Forget"), role: .destructive) { engine.delete(nodeId: node.id, context: context) }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.15).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(tint.opacity(0.45)))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        )
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "chat": return L("대화", "Chat")
        case "meeting": return L("회의", "Meeting")
        case "brain": return L("브레인", "Brain")
        case "manual": return L("직접 입력", "Manual")
        case "membase": return "Membase"
        case "obsidian": return "Obsidian"
        case "session": return L("회의록", "Meeting note")
        default: return source
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                ForEach(BrainEngine.NodeKind.allCases, id: \.self) { kind in
                    ThoughtShapeIcon(kind: kind, size: 34, face: true)
                }
            }
            Text(L("아직 생각이 하나도 없어요 — 녹음하고, 대화하고, 연결해 보세요. 배운 것들이 여기서 살아가요.",
                   "No thoughts yet — record, chat, connect. What ARCA learns lives here."))
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                engine.load(context: context)
            } label: {
                Label(L("새로고침", "Refresh"), systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.arcaPress)
            .foregroundStyle(ArcaFace.ember)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The silhouettes. Each is a closed path around `center` fitting `radius`;
/// `seed` wobbles the organic ones so no two blobs are identical.
enum ThoughtShapes {
    static func path(kind: BrainEngine.NodeKind, center c: CGPoint, radius r: CGFloat, seed: Double) -> Path {
        switch kind {
        case .user:
            // Rounded square — steady, foundational.
            return Path(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                        cornerRadius: r * 0.42)
        case .preference:
            // Cloud — three bumps on a base.
            var p = Path()
            p.addEllipse(in: CGRect(x: c.x - r * 1.05, y: c.y - r * 0.25, width: r * 1.1, height: r * 1.1))
            p.addEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.95, width: r * 1.25, height: r * 1.25))
            p.addEllipse(in: CGRect(x: c.x + r * 0.05, y: c.y - r * 0.35, width: r * 1.0, height: r * 1.0))
            p.addRoundedRect(in: CGRect(x: c.x - r * 0.9, y: c.y - r * 0.05, width: r * 1.8, height: r * 0.9), cornerSize: CGSize(width: r * 0.35, height: r * 0.35))
            return p
        case .project:
            // Tall capsule — something being built.
            return Path(roundedRect: CGRect(x: c.x - r * 0.72, y: c.y - r * 1.1, width: r * 1.44, height: r * 2.2),
                        cornerRadius: r * 0.72)
        case .fact:
            // Wobbly blob.
            var p = Path()
            let points = 8
            var pts: [CGPoint] = []
            for i in 0..<points {
                let a = Double(i) / Double(points) * 2 * .pi
                let wob = 1 + 0.12 * sin(Double(i) * 2.3 + seed * 5)
                pts.append(CGPoint(x: c.x + CGFloat(cos(a) * wob) * r, y: c.y + CGFloat(sin(a) * wob) * r))
            }
            p.move(to: midpoint(pts[points - 1], pts[0]))
            for i in 0..<points {
                let next = pts[(i + 1) % points]
                p.addQuadCurve(to: midpoint(pts[i], next), control: pts[i])
            }
            p.closeSubpath()
            return p
        case .insight:
            // Soft 6-point star / sparkle.
            var p = Path()
            let spikes = 6
            for i in 0..<(spikes * 2) {
                let a = Double(i) / Double(spikes * 2) * 2 * .pi - .pi / 2
                let rr = i.isMultiple(of: 2) ? r * 1.15 : r * 0.72
                let pt = CGPoint(x: c.x + CGFloat(cos(a)) * rr, y: c.y + CGFloat(sin(a)) * rr)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        case .session:
            // Speech bubble with a tail.
            var p = Path(roundedRect: CGRect(x: c.x - r * 1.05, y: c.y - r * 0.85, width: r * 2.1, height: r * 1.7),
                         cornerRadius: r * 0.55)
            p.move(to: CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.8))
            p.addLine(to: CGPoint(x: c.x - r * 0.55, y: c.y + r * 1.25))
            p.addLine(to: CGPoint(x: c.x + r * 0.15, y: c.y + r * 0.82))
            p.closeSubpath()
            return p
        }
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

/// A tiny SwiftUI rendering of a kind's character, for legends and lists.
struct ThoughtShapeIcon: View {
    let kind: BrainEngine.NodeKind
    var size: CGFloat = 14
    var face = false

    var body: some View {
        Canvas { ctx, canvasSize in
            let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let r = min(canvasSize.width, canvasSize.height) * 0.36
            let body = ThoughtShapes.path(kind: kind, center: c, radius: r, seed: 1.7)
            ctx.fill(body, with: .color(Color(hex: kind.hex)))
            if face {
                let ink = Color(red: 0.08, green: 0.08, blue: 0.14)
                for sign in [-1.0, 1.0] {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x + CGFloat(sign) * r * 0.32 - r * 0.09, y: c.y - r * 0.2, width: r * 0.18, height: r * 0.22)), with: .color(ink))
                }
                var mouth = Path()
                mouth.move(to: CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.28))
                mouth.addQuadCurve(to: CGPoint(x: c.x + r * 0.3, y: c.y + r * 0.28), control: CGPoint(x: c.x, y: c.y + r * 0.5))
                ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: max(1, r * 0.1), lineCap: .round))
            }
        }
        .frame(width: size * 1.4, height: size * 1.4)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
