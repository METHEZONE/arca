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
    enum NodeKind: String, Sendable {
        case memory, session, insight
    }

    struct Node: Identifiable, Sendable {
        let id: String
        var label: String
        var kind: NodeKind
        var weight: Double
        var position: CGPoint
        var velocity: CGPoint = .zero
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

    /// Full source text per node id — kept out of `Node` so the struct stays
    /// small (Canvas redraws read `nodes`/`edges` every animation frame).
    private var nodeText: [String: String] = [:]

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
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
        }

        let facts = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []

        var candidates: [Candidate] = facts.map { fact in
            Candidate(
                id: "fact-\(String(describing: fact.persistentModelID))",
                label: String(fact.text.prefix(40)),
                text: fact.text,
                kind: fact.kindRaw == "insight" ? .insight : .memory,
                createdAt: fact.createdAt)
        }
        for session in sessions {
            guard let summary = session.note?.summaryMarkdown, !summary.isEmpty else { continue }
            candidates.append(Candidate(
                id: "session-\(String(describing: session.persistentModelID))",
                label: session.title,
                text: "\(session.title). \(summary)",
                kind: .session,
                createdAt: session.createdAt))
        }

        candidates.sort { $0.createdAt > $1.createdAt }
        let capped = Array(candidates.prefix(Self.maxNodes))
        nodeText = Dictionary(uniqueKeysWithValues: capped.map { ($0.id, $0.text) })

        var previous: [String: (CGPoint, CGPoint)] = [:]
        for node in nodes { previous[node.id] = (node.position, node.velocity) }

        nodes = capped.map { c in
            let (pos, vel) = previous[c.id] ?? (Self.initialPosition(for: c.id), .zero)
            let baseWeight: Double = c.kind == .session ? 0.6 : (c.kind == .insight ? 0.75 : 0.4)
            return Node(id: c.id, label: c.label, kind: c.kind, weight: baseWeight, position: pos, velocity: vel)
        }
        edges = Self.buildBaselineEdges(nodes: nodes, nodeText: nodeText)
    }

    // MARK: - Simulation

    /// One step of the force-directed layout: Coulomb repulsion between all
    /// pairs, spring attraction along edges, gravity toward the center, and
    /// velocity damping. O(n^2) is cheap at <=150 nodes — fine for 60fps.
    func tick(size: CGSize) {
        let n = nodes.count
        guard n > 0, size.width > 1, size.height > 1 else { return }

        var fx = [Double](repeating: 0, count: n)
        var fy = [Double](repeating: 0, count: n)

        // Repulsion — every node pushes every other node away.
        let minDist2 = Self.minDistance * Self.minDistance
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                var dist2 = Double(dx * dx + dy * dy)
                if dist2 < minDist2 { dist2 = minDist2 }
                let dist = dist2.squareRoot()
                let force = Self.repulsionK / dist2
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

        // Gravity — a gentle pull toward the center so the map doesn't drift off.
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        for i in 0..<n {
            fx[i] += (cx - Double(nodes[i].position.x)) * Self.gravityK
            fy[i] += (cy - Double(nodes[i].position.y)) * Self.gravityK
        }

        // Gentle perpetual drift so the map still feels alive at rest, even
        // with zero insight edges — a per-node phase keeps it from looking
        // like uniform jitter. `simTime` is the engine's own clock so the
        // `tick(size:)` signature stays free of a dt/date parameter.
        simTime += 1.0 / 60.0
        for i in 0..<n {
            let phase = Self.seeded01(nodes[i].id.hashValue) * 2 * .pi
            fx[i] += sin(simTime * 0.5 + phase) * Self.driftK
            fy[i] += cos(simTime * 0.4 + phase * 1.3) * Self.driftK
        }

        // Integrate, damp, clamp speed, and keep positions on-canvas. Margin
        // and speed clamp scale with canvas size so the same constants work
        // for both a full-window BrainView and a 64pt BrainPreviewCard.
        let shortSide = min(Double(size.width), Double(size.height))
        let margin = max(6, min(60, shortSide * 0.12))
        let speedClamp = min(Self.maxSpeed, max(4, shortSide * 0.4))
        let maxX = max(Double(size.width) - margin, margin)
        let maxY = max(Double(size.height) - margin, margin)
        for i in 0..<n {
            var vx = (Double(nodes[i].velocity.x) + fx[i]) * Self.damping
            var vy = (Double(nodes[i].velocity.y) + fy[i]) * Self.damping
            let speed = (vx * vx + vy * vy).squareRoot()
            if speed > speedClamp {
                let scale = speedClamp / speed
                vx *= scale; vy *= scale
            }
            var px = Double(nodes[i].position.x) + vx
            var py = Double(nodes[i].position.y) + vy
            if px < margin { px = margin; vx *= -0.3 }
            if px > maxX { px = maxX; vx *= -0.3 }
            if py < margin { py = margin; vy *= -0.3 }
            if py > maxY { py = maxY; vy *= -0.3 }
            nodes[i].position = CGPoint(x: CGFloat(px), y: CGFloat(py))
            nodes[i].velocity = CGPoint(x: CGFloat(vx), y: CGFloat(vy))
        }
    }

    // Force constants. Dry-run reasoning: worst-case repulsion at the min
    // distance clamp is repulsionK / minDistance^2 ≈ 9000/576 ≈ 15.6 per
    // neighbor pair; summed across a small cluster this can spike well above
    // maxSpeed, but the per-axis speed clamp (28 px/tick) bounds it every
    // frame regardless, and damping (0.82) halves residual velocity roughly
    // every 3-4 ticks so clusters relax instead of oscillating. Springs pull
    // with at most springK * displacement (0.02 * a few hundred px ≈ single
    // digits) and gravity is similarly small (0.015 * half-canvas ≈ single
    // digits) — both far under the speed clamp, so they never dominate.
    // Position clamping with a soft bounce (-0.3) is the final backstop:
    // nodes can never leave the canvas no matter what the forces do.
    private static let repulsionK: Double = 9000
    private static let springK: Double = 0.02
    private static let gravityK: Double = 0.015
    private static let damping: Double = 0.82
    private static let maxSpeed: Double = 28
    private static let minDistance: Double = 24
    private static let driftK: Double = 0.6

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
        guard let apiKey = KeychainStore.get(.anthropic), !apiKey.isEmpty else {
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
        String(error.localizedDescription.prefix(140))
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
