import Foundation
import SwiftUI
import SwiftData
import ArcaVoiceKit

/// Drives the "memory brain" — a living, force-directed map of the user's
/// memories and session notes. Baseline edges come from shared keywords,
/// computed locally; the AI-discovered connections ("weave") are the ones
/// that should feel alive: they glow, and they persist back as memories.
@MainActor
@Observable
final class BrainEngine {
    /// One color and one silhouette per kind — the whole point of the redesign:
    /// a glance at the brain tells you what kind of thoughts live there.
    enum NodeKind: String, Sendable, CaseIterable {
        case user, preference, project, fact, insight, session

        static func from(kindRaw: String) -> NodeKind {
            NodeKind(rawValue: kindRaw) ?? .fact
        }

        var label: String {
            switch self {
            case .user: return L("나에 대해", "About me")
            case .preference: return L("취향", "Preferences")
            case .project: return L("프로젝트", "Projects")
            case .fact: return L("사실", "Facts")
            case .insight: return L("인사이트", "Insights")
            case .session: return L("회의", "Meetings")
            }
        }

        /// Headspace-bright flat palette.
        var hex: UInt32 {
            switch self {
            case .user: return 0xFFC531
            case .preference: return 0xFF6FA8
            case .project: return 0x4C8DFF
            case .fact: return 0x3DC26F
            case .insight: return 0x9B7BFF
            case .session: return 0xFF7A1A
            }
        }
    }

    struct Node: Identifiable, Sendable {
        let id: String
        var label: String
        var kind: NodeKind
        var weight: Double
        var position: CGPoint
        var velocity: CGPoint = .zero
        var createdAt: Date = .now
        var source: String = ""
        var seeded = false
        /// Cluster index (by memory source) — nodes from the same place pool
        /// into the same "lobe" of the brain.
        var group: Int = 0
        /// Normalized connectivity 0…1 — hubs sit deeper in the center and
        /// render bigger/brighter.
        var degree: Double = 0
    }

    /// A signal traveling along one synapse — spawned by the simulation,
    /// drawn by the view as a bright dot running the edge's curve.
    struct Firing: Sendable {
        let edgeId: String
        let start: Double
        let duration: Double
    }

    struct Edge: Identifiable, Sendable {
        let id: String
        var a: String
        var b: String
        var strength: Double
        var isInsight: Bool = false
        var insightText: String? = nil
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var selectedNode: String?
    private(set) var isWeaving = false
    var lastError: String?
    /// In-flight synapse signals (pruned as they land).
    private(set) var firings: [Firing] = []
    private var nextFireAt: Double = 1.5
    /// Number of distinct source groups in the current load.
    private(set) var groupCount: Int = 1

    /// Full source text per node id — kept out of `Node` so the struct stays
    /// small (Canvas redraws read `nodes`/`edges` every animation frame).
    private var nodeText: [String: String] = [:]
    /// Back-reference to the store row, for the detail panel's delete.
    private var identifiers: [String: PersistentIdentifier] = [:]

    /// Layout temperature. Forces are scaled by it and it cools every tick,
    /// so the map settles and then holds still — a still map is one you can
    /// click. Breathing and blinking are drawn, not simulated.
    private(set) var alpha: Double = 1
    var isSettled: Bool { alpha < 0.012 }
    /// Kinds hidden by the legend filter (empty = show everything).
    var hiddenKinds: Set<NodeKind> = []

    func text(for nodeId: String) -> String { nodeText[nodeId] ?? "" }
    func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    /// Reheats the layout (after a reload or a drag) so it re-settles.
    func reheat(_ to: Double = 0.6) { alpha = max(alpha, to) }

    /// Deletes a memory node's row. Sessions are not deletable from here.
    func delete(nodeId: String, context: ModelContext) {
        guard let identifier = identifiers[nodeId],
              let fact = context.model(for: identifier) as? MemoryFact else { return }
        context.delete(fact)
        try? context.save()
        selectedNode = nil
        load(context: context)
    }

    private let endpoint = ArcaCloud.anthropicMessagesURL
    private var model: String {
        UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
    }

    private static let maxNodes = 150

    /// The engine's own clock, advanced once per `tick(size:)` — drives the
    /// idle drift force without needing a dt/date parameter on `tick`.
    private var simTime: Double = 0

    // MARK: - Load

    /// Builds nodes from memories and noted sessions, and connects the ones
    /// that share significant keywords. Positions/velocities of nodes that
    /// survive a reload are kept so the map doesn't jump.
    func load(context: ModelContext) {
        struct Candidate {
            let id: String
            let label: String
            let text: String
            let kind: NodeKind
            let createdAt: Date
            let source: String
        }

        let facts = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []

        var ids: [String: PersistentIdentifier] = [:]
        var candidates: [Candidate] = facts.map { fact in
            let id = "fact-\(String(describing: fact.persistentModelID))"
            ids[id] = fact.persistentModelID
            return Candidate(
                id: id,
                label: String(fact.text.prefix(40)),
                text: fact.text,
                kind: NodeKind.from(kindRaw: fact.kindRaw),
                createdAt: fact.createdAt,
                source: fact.sourceRaw)
        }
        identifiers = ids
        for session in sessions {
            guard let summary = session.note?.summaryMarkdown, !summary.isEmpty else { continue }
            candidates.append(Candidate(
                id: "session-\(String(describing: session.persistentModelID))",
                label: session.title,
                text: "\(session.title). \(summary)",
                kind: .session,
                createdAt: session.createdAt,
                source: "session"))
        }

        candidates.sort { $0.createdAt > $1.createdAt }
        let capped = Array(candidates.prefix(Self.maxNodes))
        nodeText = Dictionary(uniqueKeysWithValues: capped.map { ($0.id, $0.text) })

        // Memories from the same source pool into the same lobe.
        var groupIndex: [String: Int] = [:]
        for c in capped where groupIndex[c.source] == nil {
            groupIndex[c.source] = groupIndex.count
        }
        groupCount = max(groupIndex.count, 1)

        var previous: [String: (CGPoint, CGPoint)] = [:]
        for node in nodes { previous[node.id] = (node.position, node.velocity) }

        nodes = capped.map { c in
            let kept = previous[c.id]
            let (pos, vel) = kept ?? (Self.initialPosition(for: c.id), .zero)
            let baseWeight: Double = c.kind == .session ? 0.6 : (c.kind == .insight ? 0.75 : 0.45)
            var node = Node(id: c.id, label: c.label, kind: c.kind, weight: baseWeight,
                            position: pos, velocity: vel, group: groupIndex[c.source] ?? 0)
            node.createdAt = c.createdAt
            node.source = c.source
            node.seeded = kept != nil
            return node
        }
        alpha = 1
        edges = Self.buildBaselineEdges(nodes: nodes, nodeText: nodeText)

        // Connectivity → hubs: normalized degree drives size and centering.
        var degreeById: [String: Int] = [:]
        for edge in edges {
            degreeById[edge.a, default: 0] += 1
            degreeById[edge.b, default: 0] += 1
        }
        let maxDegree = Double(max(degreeById.values.max() ?? 1, 1))
        for i in nodes.indices {
            nodes[i].degree = Double(degreeById[nodes[i].id] ?? 0) / maxDegree
        }
    }

    // MARK: - Simulation

    /// One step of the force-directed layout: Coulomb repulsion between all
    /// pairs, spring attraction along edges, gravity toward the center, and
    /// velocity damping. O(n^2) is cheap at <=150 nodes — fine for 60fps.
    func tick(size: CGSize) {
        let n = nodes.count
        guard n > 0, size.width > 1, size.height > 1 else { return }
        seedUnplaced(size: size)
        guard !isSettled else {
            // Still map: only the occasional spark travels an edge.
            simTime += 1.0 / 60.0
            fireSynapse()
            return
        }

        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)

        // Repulsion — every node pushes every other node away. The constant
        // adapts to density (gravity·π·R³/n): equilibrium spacing then fills
        // the containment disc for ANY node count, instead of a fixed
        // constant that overflows the boundary once the brain grows and
        // stacks nodes along it.
        let sideForRepulsion = min(Double(size.width), Double(size.height))
        let repulsionR = max(40, sideForRepulsion * 0.42)
        let repulsionK = min(Self.repulsionCap,
                             Self.gravityK * .pi * repulsionR * repulsionR * repulsionR
                                 / Double(max(n, 8)))
        let minDist2 = Self.minDistance * Self.minDistance
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                var dist2 = Double(dx * dx + dy * dy)
                if dist2 < minDist2 { dist2 = minDist2 }
                let dist = dist2.squareRoot()
                let force = repulsionK / dist2
                let ux = Double(dx) / dist, uy = Double(dy) / dist
                fx[i] += ux * force; fy[i] += uy * force
                fx[j] -= ux * force; fy[j] -= uy * force
            }
        }

        // Spring attraction along edges — stronger edges rest at a shorter length.
        var indexById: [String: Int] = Dictionary(minimumCapacity: n)
        for (i, node) in nodes.enumerated() { indexById[node.id] = i }
        for edge in edges {
            guard let i = indexById[edge.a], let j = indexById[edge.b] else { continue }
            let dx = Double(nodes[j].position.x - nodes[i].position.x)
            let dy = Double(nodes[j].position.y - nodes[i].position.y)
            let dist = max((dx * dx + dy * dy).squareRoot(), 1)
            let rest = Self.springRestLength(strength: edge.strength)
            let force = Self.springK * (dist - rest)
            let ux = dx / dist, uy = dy / dist
            fx[i] += ux * force; fy[i] += uy * force
            fx[j] -= ux * force; fy[j] -= uy * force
        }

        // Gravity — hubs (high degree) get pulled deeper toward the center,
        // so well-connected memories sit at the brain's core and leaf notes
        // drift to the cortex. Each lobe (source group) also has an anchor
        // placed around the center that its nodes lean toward — memories from
        // one place pool together organically instead of spreading uniformly.
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        let shortSide = min(Double(size.width), Double(size.height))
        let containR = max(40, shortSide * 0.42)
        for i in 0..<n {
            let hubPull = Self.gravityK * (0.6 + 0.9 * nodes[i].degree)
            fx[i] += (cx - Double(nodes[i].position.x)) * hubPull
            fy[i] += (cy - Double(nodes[i].position.y)) * hubPull

            if groupCount > 1 {
                let angle = Double(nodes[i].group) * 2.399963 // golden angle
                let ax = cx + cos(angle) * containR * 0.45
                let ay = cy + sin(angle) * containR * 0.45
                fx[i] += (ax - Double(nodes[i].position.x)) * Self.lobeK
                fy[i] += (ay - Double(nodes[i].position.y)) * Self.lobeK
            }
        }

        // Soft radial containment instead of rectangular walls. Walls made
        // overflow nodes STACK along the border in a rigid grid (the exact
        // failure mode this replaced); a radial spring past the boundary
        // keeps the mass a soft organic disc with nothing to line up against.
        for i in 0..<n {
            let dx = Double(nodes[i].position.x) - cx
            let dy = Double(nodes[i].position.y) - cy
            let r = (dx * dx + dy * dy).squareRoot()
            if r > containR {
                let pull = (r - containR) * Self.containK / max(r, 1)
                fx[i] -= dx * pull
                fy[i] -= dy * pull
            }
        }

        simTime += 1.0 / 60.0
        fireSynapse()

        // Integrate, damp, and clamp speed — all scaled by the cooling alpha
        // so the map settles and stops. The radial containment above is the
        // boundary; positions are never hard-clamped.
        alpha *= Self.cooling
        let speedClamp = min(Self.maxSpeed, max(4, shortSide * 0.4)) * max(alpha, 0.05)
        for i in 0..<n {
            var vx = (Double(nodes[i].velocity.x) + fx[i] * alpha) * Self.damping
            var vy = (Double(nodes[i].velocity.y) + fy[i] * alpha) * Self.damping
            let speed = (vx * vx + vy * vy).squareRoot()
            if speed > speedClamp {
                let scale = speedClamp / speed
                vx *= scale; vy *= scale
            }
            nodes[i].position = CGPoint(x: nodes[i].position.x + CGFloat(vx),
                                        y: nodes[i].position.y + CGFloat(vy))
            nodes[i].velocity = CGPoint(x: CGFloat(vx), y: CGFloat(vy))
        }
    }

    /// Progress 0…1 of a firing at the engine's current clock, eased.
    func firingProgress(_ firing: Firing) -> Double {
        let raw = min(max((simTime - firing.start) / firing.duration, 0), 1)
        // easeInOut
        return raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
    }

    // Force constants. Stability reasoning: worst-case repulsion at the min
    // distance clamp can spike well above maxSpeed, but the per-axis speed
    // clamp bounds it every frame, and damping (0.82) halves residual
    // velocity roughly every 3-4 ticks so clusters relax instead of
    // oscillating. Springs, gravity, and the lobe pull are all far under the
    // speed clamp. The radial containment spring is the boundary backstop —
    // no hard position clamp exists, by design.
    /// Ceiling for the adaptive repulsion constant (huge canvases, few nodes).
    private static let repulsionCap: Double = 24000
    private static let springK: Double = 0.02
    private static let gravityK: Double = 0.015
    private static let damping: Double = 0.82
    private static let maxSpeed: Double = 28
    private static let minDistance: Double = 24
    /// Per-tick multiplier on the layout temperature; ~4 s to stillness at 60 fps.
    private static let cooling: Double = 0.982

    /// Synapse firing: every second or two a random edge carries a signal
    /// (insight edges fire more). The view draws the traveling spark.
    private func fireSynapse() {
        if simTime >= nextFireAt, !edges.isEmpty {
            let insightEdges = edges.filter(\.isInsight)
            let pool = insightEdges.isEmpty ? edges : edges + insightEdges
            if let edge = pool.randomElement() {
                firings.append(Firing(edgeId: edge.id, start: simTime,
                                      duration: Double.random(in: 0.7...1.1)))
            }
            nextFireAt = simTime + Double.random(in: 1.2...2.8)
        }
        firings.removeAll { simTime - $0.start > $0.duration }
    }

    /// New nodes start on a golden-angle spiral around the canvas center,
    /// grouped by kind, so the sim only has to tidy, not migrate a cloud in.
    private func seedUnplaced(size: CGSize) {
        let cx = size.width / 2, cy = size.height / 2
        let radius = min(size.width, size.height) * 0.38
        var placed = 0
        for i in nodes.indices where !nodes[i].seeded {
            let kindIndex = Double(NodeKind.allCases.firstIndex(of: nodes[i].kind) ?? 0)
            let angle = kindIndex / Double(NodeKind.allCases.count) * 2 * .pi
                + Self.seeded01(nodes[i].id.hashValue) * 0.9 - 0.45
            let r = radius * (0.25 + 0.75 * Self.seeded01(nodes[i].id.hashValue ^ 0x9e37))
            nodes[i].position = CGPoint(x: cx + CGFloat(cos(angle)) * r, y: cy + CGFloat(sin(angle)) * r)
            nodes[i].seeded = true
            placed += 1
        }
        if placed > 0 { alpha = 1 }
    }
    /// Pull toward the node's source-group anchor — strong enough to pool
    /// lobes, weak enough that keyword springs can still bridge them.
    private static let lobeK: Double = 0.004
    /// Radial boundary spring per px past the containment radius.
    private static let containK: Double = 0.06

    private static func springRestLength(strength: Double) -> Double {
        max(30, 130 - 90 * min(max(strength, 0), 1))
    }

    // MARK: - Baseline (keyword) edges

    private static func buildBaselineEdges(nodes: [Node], nodeText: [String: String]) -> [Edge] {
        guard nodes.count > 1 else { return [] }
        var tokens: [String: Set<String>] = [:]
        tokens.reserveCapacity(nodes.count)
        for node in nodes {
            tokens[node.id] = keywords(from: nodeText[node.id] ?? node.label)
        }

        struct Candidate { let i: Int; let j: Int; let strength: Double }
        var candidates: [Candidate] = []
        for i in 0..<nodes.count {
            guard let ti = tokens[nodes[i].id], !ti.isEmpty else { continue }
            for j in (i + 1)..<nodes.count {
                guard let tj = tokens[nodes[j].id], !tj.isEmpty else { continue }
                let overlap = ti.intersection(tj).count
                guard overlap > 0 else { continue }
                let union = ti.union(tj).count
                let jaccard = Double(overlap) / Double(max(union, 1))
                guard jaccard >= 0.12 else { continue }
                candidates.append(Candidate(i: i, j: j, strength: min(1, jaccard * 2.5)))
            }
        }
        candidates.sort { $0.strength > $1.strength }

        var degree: [Int: Int] = [:]
        var result: [Edge] = []
        for c in candidates {
            let da = degree[c.i, default: 0], db = degree[c.j, default: 0]
            guard da < 3, db < 3 else { continue }
            degree[c.i] = da + 1
            degree[c.j] = db + 1
            result.append(Edge(id: "\(nodes[c.i].id)~\(nodes[c.j].id)",
                                a: nodes[c.i].id, b: nodes[c.j].id, strength: c.strength))
        }
        return result
    }

    private static let stopwords: Set<String> = [
        "this", "that", "these", "those", "with", "from", "have", "has", "had",
        "were", "been", "being", "would", "could", "should", "their", "there",
        "which", "about", "into", "only", "some", "more", "than", "then", "them",
        "such", "doing", "does", "done", "your", "what", "when", "where", "will",
        "just", "very", "also", "they", "because", "after", "before", "while",
        "during", "between", "through", "without", "within", "other", "another",
        "every", "each", "much", "many", "most", "least", "over", "under",
        "again", "still", "even", "like", "make", "made", "take", "took",
        "come", "came", "going", "gone", "really", "actually", "probably",
        "here", "well", "want", "need", "know", "think", "thing", "things",
    ]

    private static func keywords(from text: String) -> Set<String> {
        var result = Set<String>()
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let w = String(word)
            guard w.count >= 4, !stopwords.contains(w) else { continue }
            result.insert(w)
        }
        return result
    }

    /// Deterministic-ish spread across an arbitrary starting canvas; the
    /// simulation itself carries nodes to their settled positions from here.
    private static func initialPosition(for id: String) -> CGPoint {
        let h = id.hashValue
        let x = seeded01(h)
        let y = seeded01(h ^ 0x5bd1_e995)
        return CGPoint(x: CGFloat(150 + x * 500), y: CGFloat(150 + y * 500))
    }

    private static func seeded01(_ seed: Int) -> Double {
        var x = UInt64(bitPattern: Int64(seed))
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        x = x &* 0xc4ce_b9fe_1a85_ec53
        x ^= x >> 33
        return Double(x % 1_000_000) / 1_000_000.0
    }

    // MARK: - Selection

    func edgesTouching(_ nodeId: String) -> [Edge] {
        edges.filter { $0.a == nodeId || $0.b == nodeId }
    }

    func nodeMatches(_ nodeId: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = "\(nodeText[nodeId] ?? "") \(nodes.first(where: { $0.id == nodeId })?.label ?? "")"
        return haystack.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Weave (AI-discovered insights)

    /// Sends recent memories/session notes to Claude and asks it to name
    /// non-obvious connections between them. Marked edges glow; each
    /// discovered insight is also saved as a new memory so it persists.
    func weaveInsights(context: ModelContext) async {
        guard !isWeaving else { return }
        guard let apiKey = ArcaCloud.anthropicKey, !apiKey.isEmpty else {
            lastError = "Add an Anthropic key in Settings to weave insights."
            return
        }
        let candidates = Array(nodes.filter { $0.kind != .insight }.prefix(40))
        guard candidates.count >= 2 else {
            lastError = "Not enough memories yet to find connections."
            return
        }

        isWeaving = true
        lastError = nil
        defer { isWeaving = false }

        do {
            let found = try await Self.callWeave(candidates: candidates, nodeText: nodeText,
                                                  apiKey: apiKey, model: model, endpoint: endpoint)
            guard !found.isEmpty else {
                lastError = "No new connections found this time."
                return
            }
            let validIds = Set(nodes.map(\.id))
            for item in found {
                guard item.aId != item.bId, validIds.contains(item.aId), validIds.contains(item.bId) else { continue }
                let strength = min(max(item.strength, 0), 1)
                if let idx = edges.firstIndex(where: { Self.samePair($0, item.aId, item.bId) }) {
                    edges[idx].isInsight = true
                    edges[idx].insightText = item.insight
                    edges[idx].strength = max(edges[idx].strength, strength)
                } else {
                    edges.append(Edge(id: "insight-\(item.aId)~\(item.bId)-\(UUID().uuidString.prefix(6))",
                                       a: item.aId, b: item.bId, strength: strength,
                                       isInsight: true, insightText: item.insight))
                }
                bumpWeight(item.aId)
                bumpWeight(item.bId)
                context.insert(MemoryFact(text: item.insight, kind: "insight", source: "brain"))
                CompanionProgress.shared.award(.insightWoven)
            }
            try? context.save()
        } catch {
            lastError = Self.friendlyMessage(for: error)
        }
    }

    private func bumpWeight(_ id: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].weight = min(1.0, nodes[idx].weight + 0.25)
    }

    private static func samePair(_ edge: Edge, _ a: String, _ b: String) -> Bool {
        (edge.a == a && edge.b == b) || (edge.a == b && edge.b == a)
    }

    private struct WeaveResult { let aId: String; let bId: String; let insight: String; let strength: Double }

    private static func callWeave(candidates: [Node], nodeText: [String: String], apiKey: String,
                                   model: String, endpoint: URL) async throws -> [WeaveResult] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 60

        let tool: [String: Any] = [
            "name": "weave_insights",
            "description": "Find non-obvious, meaningful connections between the user's memories and session notes.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "insights": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "aId": ["type": "string", "description": "id of the first note"],
                                "bId": ["type": "string", "description": "id of the second note, different from aId"],
                                "insight": ["type": "string",
                                            "description": "One sentence, in English, explaining the non-obvious connection between the two notes"],
                                "strength": ["type": "number", "description": "0-1, how meaningful/confident this connection is"],
                            ],
                            "required": ["aId", "bId", "insight", "strength"],
                        ] as [String: Any],
                        "description": "3-8 non-obvious, meaningful connections. Skip anything trivial or already obvious from either note alone.",
                    ],
                ],
                "required": ["insights"],
            ] as [String: Any],
        ]

        let lines = candidates.map { node -> String in
            let text = nodeText[node.id] ?? node.label
            return "- id: \(node.id) [\(node.kind.rawValue)] \(String(text.prefix(200)))"
        }.joined(separator: "\n")

        let userText = """
        Below are notes from the user's memory and recorded sessions. Find non-obvious, \
        meaningful connections between DIFFERENT notes — a shared theme, a cause-and-effect, \
        a recurring concern, a plan that depends on another. Skip pairs that only share a \
        generic word or are already obviously related. Reference notes only by their id.

        Notes:
        \(lines)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "weave_insights"],
            "messages": [["role": "user", "content": [["type": "text", "text": userText]]]],
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw WeaveError.api((response as? HTTPURLResponse)?.statusCode ?? 0, message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let raw = input["insights"] as? [[String: Any]] else {
            throw WeaveError.noToolUse
        }
        return raw.compactMap { entry in
            guard let aId = entry["aId"] as? String, let bId = entry["bId"] as? String,
                  let insight = entry["insight"] as? String, !insight.isEmpty else { return nil }
            let strength = (entry["strength"] as? Double) ?? Double(entry["strength"] as? Int ?? 0)
            return WeaveResult(aId: aId, bId: bId, insight: insight, strength: strength)
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        UserFacingError.message(for: error)
    }

    enum WeaveError: Error, LocalizedError {
        case api(Int, String)
        case noToolUse
        var errorDescription: String? {
            switch self {
            case .api(let status, let message): return "Weaving failed (HTTP \(status)): \(message)"
            case .noToolUse: return "Couldn't parse ARCA's response"
            }
        }
    }
}
