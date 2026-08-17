import Foundation

/// One call recording exported out of A. 전화 (에이닷), parsed from what the app
/// writes to iCloud Drive.
///
/// A. saves two kinds of file, both named
/// `{상대이름}_{번호}_{YYYYMMDD}_{HHMMSS}.{ext}`:
///
///   `.txt`  the full export — header, A.'s own summary, and a speaker-attributed
///           transcript with `MM:SS` offsets. Nothing needs transcribing.
///   `.m4a`  audio only, which still has to go through the normal pipeline.
///
/// The filename alone carries the contact, the phone number, and the exact start
/// time, so even the audio-only case arrives with more context than a recording
/// made inside ARCA.
public struct ParsedPhoneCall: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        /// As written by A. — `나` or `상대방`.
        public let speaker: String
        public let start: TimeInterval
        public let text: String

        public init(speaker: String, start: TimeInterval, text: String) {
            self.speaker = speaker
            self.start = start
            self.text = text
        }
    }

    public let contactName: String
    /// Formatted as A. wrote it (`010-8551-3625`) when the body was available,
    /// otherwise the bare digits from the filename.
    public let phoneNumber: String
    public let startedAt: Date
    public let duration: TimeInterval
    /// A.'s own call summary, if the export included one. Fed to ARCA's
    /// summarizer as prior notes rather than thrown away — it is a second read
    /// on the same call, produced with audio ARCA never had.
    public let adotSummary: String?
    public let turns: [Turn]

    public init(contactName: String, phoneNumber: String, startedAt: Date,
                duration: TimeInterval, adotSummary: String? = nil, turns: [Turn] = []) {
        self.contactName = contactName
        self.phoneNumber = phoneNumber
        self.startedAt = startedAt
        self.duration = duration
        self.adotSummary = adotSummary
        self.turns = turns
    }

    public var hasTranscript: Bool { !turns.isEmpty }
}

public enum PhoneCallTranscriptParser {
    /// What the filename alone establishes. Returns nil when the name does not
    /// match A.'s convention, which is how unrelated files in a watched folder
    /// are skipped.
    public static func parseFileName(_ fileName: String) -> (name: String, digits: String, startedAt: Date)? {
        let stem = (fileName as NSString).deletingPathExtension
        // Parsed from the right: a contact name may itself contain underscores
        // ("SKT 대리담당 나쁜_01097269991_..." is one name, but "한국_샤크탱크_..."
        // would not be), so only the trailing three fields are positional.
        let parts = stem.components(separatedBy: "_")
        guard parts.count >= 4 else { return nil }
        let time = parts[parts.count - 1]
        let day = parts[parts.count - 2]
        let digits = parts[parts.count - 3]
        let name = parts[0..<(parts.count - 3)].joined(separator: "_")

        guard day.count == 8, time.count == 6,
              day.allSatisfy(\.isNumber), time.allSatisfy(\.isNumber),
              digits.count >= 8, digits.allSatisfy(\.isNumber),
              !name.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        formatter.dateFormat = "yyyyMMddHHmmss"
        guard let date = formatter.date(from: day + time) else { return nil }
        return (name, digits, date)
    }

    /// Parses a full `.txt` export. `fileName` supplies the start time, which is
    /// unambiguous there; the body's Korean date line is not parsed for it.
    public static func parse(body: String, fileName: String) -> ParsedPhoneCall? {
        guard let named = parseFileName(fileName) else { return nil }

        let lines = body.components(separatedBy: .newlines)
        let header = headerFields(in: lines)
        let sections = sectionRanges(in: lines)

        let summary = sections["[통화요약]"].map { range in
            lines[range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let turns = sections["[녹음 내용]"].map { turnsIn(lines: Array(lines[$0])) } ?? []

        return ParsedPhoneCall(
            contactName: header.name ?? named.name,
            phoneNumber: header.phone ?? named.digits,
            startedAt: named.startedAt,
            duration: header.duration ?? turns.last.map { $0.start } ?? 0,
            adotSummary: (summary?.isEmpty == false) ? summary : nil,
            turns: turns)
    }

    /// The audio-only case: everything the filename gives, no transcript.
    public static func parseAudioOnly(fileName: String, duration: TimeInterval) -> ParsedPhoneCall? {
        guard let named = parseFileName(fileName) else { return nil }
        return ParsedPhoneCall(contactName: named.name, phoneNumber: named.digits,
                               startedAt: named.startedAt, duration: duration)
    }

    // MARK: - Header

    struct Header {
        var name: String?
        var phone: String?
        var duration: TimeInterval?
    }

    /// Reads `한국 샤크탱크 쿠팡플레이(010-8551-3625) 님과의 통화` and `54분 46초`.
    /// The body's phone number is preferred over the filename's because it is
    /// already formatted the way a Notion phone column should read.
    static func headerFields(in lines: [String]) -> Header {
        var header = Header()
        for line in lines.prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if header.name == nil,
               let match = trimmed.firstMatch(of: /^(.+)\(([0-9\-+ ]{7,})\)\s*님과의 통화$/) {
                header.name = String(match.output.1).trimmingCharacters(in: .whitespaces)
                header.phone = String(match.output.2).trimmingCharacters(in: .whitespaces)
            }
            if header.duration == nil, let seconds = duration(from: trimmed) {
                header.duration = seconds
            }
        }
        return header
    }

    /// `54분 46초`, `1분 46초`, `1시간 2분 3초`.
    static func duration(from line: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var matched = false
        for match in line.matches(of: /(\d+)\s*(시간|분|초)/) {
            let value = Double(String(match.output.1)) ?? 0
            switch String(match.output.2) {
            case "시간": total += value * 3600
            case "분": total += value * 60
            default: total += value
            }
            matched = true
        }
        return matched ? total : nil
    }

    // MARK: - Sections

    /// Line ranges owned by each `[...]` section marker.
    static func sectionRanges(in lines: [String]) -> [String: Range<Int>] {
        var markers: [(name: String, index: Int)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                markers.append((trimmed, index))
            }
        }
        var result: [String: Range<Int>] = [:]
        for (offset, marker) in markers.enumerated() {
            let end = offset + 1 < markers.count ? markers[offset + 1].index : lines.count
            result[marker.name] = (marker.index + 1)..<end
        }
        return result
    }

    /// Parses the `[녹음 내용]` body, where each turn is a `{화자} {MM:SS}` line
    /// followed by its text.
    static func turnsIn(lines: [String]) -> [ParsedPhoneCall.Turn] {
        var turns: [ParsedPhoneCall.Turn] = []
        var speaker: String?
        var start: TimeInterval = 0
        var buffer: [String] = []

        func flush() {
            guard let speaker else { buffer.removeAll(); return }
            let text = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                turns.append(.init(speaker: speaker, start: start, text: text))
            }
            buffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let match = trimmed.firstMatch(of: /^(\S+)\s+(\d{1,2}:\d{2}(?::\d{2})?)$/) {
                flush()
                speaker = String(match.output.1)
                start = offset(from: String(match.output.2))
            } else {
                buffer.append(trimmed)
            }
        }
        flush()
        return turns
    }

    /// `MM:SS` or `HH:MM:SS` into seconds.
    static func offset(from stamp: String) -> TimeInterval {
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
    }
}
