import Foundation
import SwiftData
import ArcaVoiceKit

/// ARCA's ambient operations: reads your world (Gmail, Slack, Calendar via
/// Composio), turns actionable inbound into tasks, drafts Slack replies for
/// your approval, and writes the daily briefing — what to do, what to ask of
/// people, what got done. Nothing outbound ever fires without Approve.
@MainActor
@Observable
final class AmbientOps {
    static let shared = AmbientOps()

    struct Briefing: Equatable {
        var today: [String]
        var asks: [String]
        var done: [String]
        var generatedAt: Date
    }

    private(set) var briefing: Briefing?
    private(set) var isBriefing = false
    private(set) var isHarvesting = false
    private(set) var lastHarvestAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var accountByToolkit: [String: String] = [:]

    // MARK: - Composio plumbing

    private var composioKey: String? {
        let k = KeychainStore.get(.composio); return (k?.isEmpty == false) ? k : nil
    }
    private var composioUser: String? {
        UserDefaults.standard.string(forKey: "composioUserId")
    }
    private var anthropicKey: String? {
        let k = KeychainStore.get(.anthropic); return (k?.isEmpty == false) ? k : nil
    }
    private var model: String {
        UserDefaults.standard.string(forKey: "chatModel") ?? "claude-sonnet-5"
    }

    private func account(for toolkit: String) async -> String? {
        if let cached = accountByToolkit[toolkit] { return cached }
        guard let key = composioKey, let user = composioUser else { return nil }
        // Prefer the shared ~/.arca map on macOS; fall back to the API.
        if let conn = ArcaConfig.loadConnections(),
           let id = conn.connectedAccounts?[toolkit.uppercased()], !id.isEmpty {
            accountByToolkit[toolkit] = id
            return id
        }
        var request = URLRequest(url: URL(string:
            "https://backend.composio.dev/api/v3/connected_accounts?user_ids=\(user)")!)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let id = item["id"] as? String,
                  let tk = (item["toolkit"] as? [String: Any])?["slug"] as? String else { continue }
            accountByToolkit[tk.lowercased()] = id
        }
        return accountByToolkit[toolkit]
    }

    private func execute(_ slug: String, toolkit: String,
                         arguments: [String: Any]) async throws -> [String: Any] {
        guard let key = composioKey, let user = composioUser,
              let account = await account(for: toolkit) else {
            throw OpsError.notConnected(toolkit)
        }
        var request = URLRequest(url: URL(string:
            "https://backend.composio.dev/api/v3/tools/execute/\(slug)")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "connected_account_id": account, "user_id": user, "arguments": arguments,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await uploadBody(URLSession.shared, for: request, body: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpsError.api(slug, status)
        }
        return (json["data"] as? [String: Any]) ?? [:]
    }

    // MARK: - Harvest: inbox → tasks + reply drafts

    /// Pulls recent Gmail + Slack, asks Claude to triage, creates tasks for
    /// the actionable ones and reply proposals for Slack messages worth
    /// answering. Throttled; dedupes by fingerprint across runs.
    func harvest(context: ModelContext, force: Bool = false) async {
        guard UserDefaults.standard.object(forKey: "ambientHarvest") as? Bool ?? true else { return }
        guard anthropicKey != nil, composioKey != nil else { return }
        if !force, let last = lastHarvestAt, Date.now.timeIntervalSince(last) < 10 * 60 { return }
        guard !isHarvesting else { return }
        isHarvesting = true
        defer { isHarvesting = false }
        lastHarvestAt = .now

        var inbound: [[String: String]] = []

        if let data = try? await execute("GMAIL_FETCH_EMAILS", toolkit: "gmail",
                                         arguments: ["max_results": 8, "query": "is:unread newer_than:1d"]) {
            let messages = (data["messages"] as? [[String: Any]]) ?? []
            for m in messages {
                let sender = (m["sender"] as? String) ?? ""
                let subject = (m["subject"] as? String) ?? ""
                let preview = ((m["preview"] as? [String: Any])?["body"] as? String)
                    ?? (m["messageText"] as? String) ?? ""
                inbound.append(["source": "gmail", "author": sender, "title": subject,
                                "body": String(preview.prefix(400)), "channel": "", "ts": ""])
            }
        }

        var slackSeen = Set<String>()
        for query in SlackHarvestFilter.searchQueries(after: Self.yesterday()) {
            guard let data = try? await execute(
                "SLACK_SEARCH_MESSAGES",
                toolkit: "slack",
                arguments: ["query": query, "count": 6, "sort": "timestamp", "sort_dir": "desc"]
            ) else { continue }
            let matches = ((data["messages"] as? [String: Any])?["matches"] as? [[String: Any]]) ?? []
            for m in matches {
                let channelInfo = m["channel"] as? [String: Any]
                let channel = (channelInfo?["id"] as? String)
                    ?? (channelInfo?["name"] as? String) ?? ""
                let author = (m["username"] as? String) ?? (m["user"] as? String) ?? ""
                let body = String(((m["text"] as? String) ?? "").prefix(400))
                let key = "\(channel)|\(author)|\(body.prefix(120))"
                guard !slackSeen.contains(key),
                      SlackHarvestFilter.shouldKeep(text: body, author: author)
                else { continue }
                slackSeen.insert(key)
                inbound.append(["source": "slack",
                                "author": author,
                                "title": "",
                                "body": body,
                                "channel": channel,
                                "ts": (m["ts"] as? String) ?? ""])
                if slackSeen.count >= 10 { break }
            }
            if slackSeen.count >= 10 { break }
        }

        guard !inbound.isEmpty else { return }

        // Skip anything we've already triaged.
        var seen = Set(UserDefaults.standard.stringArray(forKey: "harvestSeen") ?? [])
        let fresh = inbound.filter { !seen.contains(Self.fingerprint($0)) }
        guard !fresh.isEmpty else { return }

        do {
            let triaged = try await triage(fresh)
            let ownerName = AppServices.shared.ownerName
            for (index, verdict) in triaged {
                guard index < fresh.count else { continue }
                let item = fresh[index]
                seen.insert(Self.fingerprint(item))
                if verdict.actionable, !verdict.taskTitle.isEmpty {
                    let task = TodoTask(title: verdict.taskTitle, detail: verdict.taskDetail,
                                        source: item["source"] ?? "inbox")
                    context.insert(task)
                    Task { await TaskEngine.shared.classify(task) }
                }
                if verdict.wantsReply, item["source"] == "slack",
                   let channel = item["channel"], !channel.isEmpty,
                   !verdict.replyDraft.isEmpty {
                    context.insert(ReplyProposal(
                        source: "slack", channel: channel,
                        threadTs: item["ts"] ?? "",
                        author: item["author"] ?? "",
                        original: item["body"] ?? "",
                        draft: verdict.replyDraft.replacingOccurrences(
                            of: "{me}", with: ownerName)))
                }
            }
            try? context.save()
            UserDefaults.standard.set(Array(seen.suffix(500)), forKey: "harvestSeen")
            RelaySync.shared.scheduleSync()
            lastError = nil
        } catch {
            lastError = String(error.localizedDescription.prefix(140))
        }
    }

    private struct Verdict {
        var actionable: Bool
        var taskTitle: String
        var taskDetail: String
        var wantsReply: Bool
        var replyDraft: String
    }

    private func triage(_ items: [[String: String]]) async throws -> [(Int, Verdict)] {
        guard let key = anthropicKey else { throw OpsError.noKey }
        let listing = items.enumerated().map { i, item in
            "[\(i)] source=\(item["source"] ?? "") from=\(item["author"] ?? "") \(item["title"] ?? "") — \(item["body"] ?? "")"
        }.joined(separator: "\n")

        let tool: [String: Any] = [
            "name": "triage_inbox",
            "description": "Triage inbound messages into tasks and reply drafts.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer"],
                                "actionable": ["type": "boolean",
                                               "description": "true only if this genuinely needs the user to do something"],
                                "taskTitle": ["type": "string", "description": "short imperative task title, English"],
                                "taskDetail": ["type": "string"],
                                "wantsReply": ["type": "boolean",
                                               "description": "true if a short reply from the user is expected (slack only)"],
                                "replyDraft": ["type": "string",
                                               "description": "the reply to send, matching the original message's language and tone; empty if none"],
                            ],
                            "required": ["index", "actionable", "taskTitle", "taskDetail", "wantsReply", "replyDraft"],
                        ],
                    ],
                ],
                "required": ["items"],
            ] as [String: Any],
        ]
        let prompt = """
        You are ARCA, triaging the user's inbound messages. Newsletters, receipts, \
        automated notifications, FYI-only chatter, and messages written by the user \
        → not actionable, no reply. Real human asks directed at the user or explicit \
        pings → actionable task and, for Slack, a short natural reply draft in the \
        sender's language.

        \(listing)
        """
        let body: [String: Any] = [
            "model": model, "max_tokens": 1500,
            "tools": [tool], "tool_choice": ["type": "tool", "name": "triage_inbox"],
            "messages": [["role": "user", "content": [["type": "text", "text": prompt]]]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await uploadBody(URLSession.shared, for: request, body: payload)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let tu = content.first(where: { ($0["type"] as? String) == "tool_use" }),
              let input = tu["input"] as? [String: Any],
              let raw = input["items"] as? [[String: Any]] else {
            throw OpsError.badTriage
        }
        return raw.compactMap { d in
            guard let index = d["index"] as? Int else { return nil }
            return (index, Verdict(
                actionable: (d["actionable"] as? Bool) ?? false,
                taskTitle: (d["taskTitle"] as? String) ?? "",
                taskDetail: (d["taskDetail"] as? String) ?? "",
                wantsReply: (d["wantsReply"] as? Bool) ?? false,
                replyDraft: (d["replyDraft"] as? String) ?? ""))
        }
    }

    // MARK: - Approvals

    /// The user said yes — send it (Slack), mark the proposal.
    func approve(_ proposal: ReplyProposal, context: ModelContext) async {
        var args: [String: Any] = ["channel": proposal.channel, "text": proposal.draft]
        if !proposal.threadTs.isEmpty { args["thread_ts"] = proposal.threadTs }
        do {
            _ = try await execute("SLACK_SEND_MESSAGE", toolkit: "slack", arguments: args)
            proposal.stateRaw = "sent"
            proposal.sentAt = .now
            #if os(macOS)
            AppServices.shared.notch.celebrate("Replied to \(proposal.author)")
            #endif
        } catch {
            proposal.stateRaw = "failed"
            lastError = String(error.localizedDescription.prefix(140))
        }
        try? context.save()
    }

    func skip(_ proposal: ReplyProposal, context: ModelContext) {
        proposal.stateRaw = "skipped"
        try? context.save()
    }

    // MARK: - Daily briefing

    /// What to do today, what to ask of people, what already got done.
    func generateBriefing(context: ModelContext) async {
        guard let key = anthropicKey, !isBriefing else { return }
        isBriefing = true
        defer { isBriefing = false }

        var facts: [String] = []
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)

        // Calendar next 24h (best effort).
        let iso = ISO8601DateFormatter()
        if let data = try? await execute("GOOGLECALENDAR_EVENTS_LIST", toolkit: "googlecalendar",
                                         arguments: ["calendarId": "primary", "maxResults": 12,
                                                     "timeMin": iso.string(from: .now),
                                                     "timeMax": iso.string(from: .now.addingTimeInterval(86_400)),
                                                     "singleEvents": true, "orderBy": "startTime"]) {
            let events = (data["items"] as? [[String: Any]]) ?? []
            for e in events {
                let title = (e["summary"] as? String) ?? "(untitled)"
                let start = ((e["start"] as? [String: Any])?["dateTime"] as? String)
                    ?? ((e["start"] as? [String: Any])?["date"] as? String) ?? ""
                facts.append("CALENDAR: \(title) at \(start)")
            }
        }

        let tasks = (try? context.fetch(FetchDescriptor<TodoTask>())) ?? []
        for task in tasks where task.state != .done && task.state != .trashed {
            facts.append("OPEN TASK [\(task.actionKindRaw)]: \(task.title) — \(task.autonomyRationale)")
        }
        for task in tasks where task.state == .done && task.updatedAt >= dayStart {
            facts.append("DONE TODAY: \(task.title)")
        }
        let sessions = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        for session in sessions where session.createdAt >= dayStart {
            let summary = session.note?.summaryMarkdown.map { String($0.prefix(160)) } ?? ""
            facts.append("SESSION TODAY: \(session.title) — \(summary)")
        }

        let tool: [String: Any] = [
            "name": "daily_briefing",
            "description": "Compose the user's daily briefing.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "today": ["type": "array", "items": ["type": "string"],
                              "description": "3-6 bullets: what to do today, ordered by importance"],
                    "asks": ["type": "array", "items": ["type": "string"],
                             "description": "0-4 bullets: what to request from teammates/others"],
                    "done": ["type": "array", "items": ["type": "string"],
                             "description": "0-6 bullets: what got done today"],
                ],
                "required": ["today", "asks", "done"],
            ] as [String: Any],
        ]
        let prompt = """
        Compose today's briefing for the user from these facts. Concise, specific, \
        English. If a task needs someone else's input, surface it under asks.

        \(facts.isEmpty ? "(no facts — say so gracefully)" : facts.joined(separator: "\n"))
        """
        do {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            let body: [String: Any] = [
                "model": model, "max_tokens": 900,
                "tools": [tool], "tool_choice": ["type": "tool", "name": "daily_briefing"],
                "messages": [["role": "user", "content": [["type": "text", "text": prompt]]]],
            ]
            let payload = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await uploadBody(URLSession.shared, for: request, body: payload)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let tu = content.first(where: { ($0["type"] as? String) == "tool_use" }),
                  let input = tu["input"] as? [String: Any] else {
                throw OpsError.badTriage
            }
            briefing = Briefing(
                today: (input["today"] as? [String]) ?? [],
                asks: (input["asks"] as? [String]) ?? [],
                done: (input["done"] as? [String]) ?? [],
                generatedAt: .now)
            lastError = nil
        } catch {
            lastError = String(error.localizedDescription.prefix(140))
        }
    }

    // MARK: - Helpers

    private static func fingerprint(_ item: [String: String]) -> String {
        "\(item["source"] ?? "")|\(item["author"] ?? "")|\(item["title"] ?? "")|\(String((item["body"] ?? "").prefix(80)))"
    }

    private static func yesterday() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now.addingTimeInterval(-86_400))
    }

    enum OpsError: Error, LocalizedError {
        case notConnected(String)
        case noKey
        case api(String, Int)
        case badTriage

        var errorDescription: String? {
            switch self {
            case .notConnected(let toolkit): return "\(toolkit) isn't connected yet — check Settings → Connectors."
            case .noKey: return "Anthropic key needed."
            case .api(let slug, let status): return "\(slug) failed (HTTP \(status))."
            case .badTriage: return "Couldn't parse the triage response."
            }
        }
    }
}
