import SwiftUI
import ArcaVoiceKit

/// The one markdown renderer for everything ARCA writes — chat replies,
/// meeting notes, day reports.
///
/// `Text(LocalizedStringKey:)` only understands inline markdown, so headings,
/// bullets and code fences came out as literal `#`, `-` and backticks. This
/// splits the text into blocks first (headings, bullets, numbered items, code
/// fences, paragraphs), styles each block, and hands only the inline runs to
/// `AttributedString(markdown:)`.
struct MarkdownText: View {
    let markdown: String
    var font: Font = .system(.body, design: .rounded)
    var tint: Color = ArcaFace.ember

    init(_ markdown: String, font: Font = .system(.body, design: .rounded), tint: Color = ArcaFace.ember) {
        self.markdown = markdown
        self.font = font
        self.tint = tint
    }

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                render(block, isFirst: index == 0)
            }
        }
        .font(font)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlockParser.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .system(.title3, design: .rounded, weight: .bold)
                      : level == 2 ? .system(.headline, design: .rounded, weight: .bold)
                      : .system(.subheadline, design: .rounded, weight: .semibold))
                .padding(.top, isFirst ? 0 : 6)
        case .paragraph(let text):
            inline(text)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(tint.opacity(0.85)).frame(width: 5, height: 5).offset(y: -2)
                        inline(item)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item)
                    }
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.6)).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .divider:
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// A fenced code block: monospaced, dimmed card, language tag, copy button.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").lowercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if ArcaClipboard.copy(code) {
                        withAnimation { copied = true }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.4))
                            withAnimation { copied = false }
                        }
                    }
                } label: {
                    Label(copied ? L("복사했어요", "Copied") : L("복사", "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.04))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }
}

/// Line-oriented block parser. Deliberately small: the model's output is
/// CommonMark-ish prose, not documentation with nested structures.
enum MarkdownBlockParser {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        case quote(String)
        case code(language: String?, code: String)
        case divider
    }

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var codeLines: [String]?
        var codeLanguage: String?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if var lines = codeLines {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, code: lines.joined(separator: "\n")))
                    codeLines = nil; codeLanguage = nil
                } else {
                    lines.append(rawLine); codeLines = lines
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                let lang = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLanguage = lang.isEmpty ? nil : lang
                codeLines = []
                continue
            }
            if line.isEmpty { flushAll(); continue }
            if line == "---" || line == "***" || line == "___" { flushAll(); blocks.append(.divider); continue }

            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { flushAll(); blocks.append(.heading(min(level, 3), text)); continue }
            }
            // A line that is nothing but a bold span reads as a header.
            if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4,
               !line.dropFirst(2).dropLast(2).contains("**") {
                flushAll(); blocks.append(.heading(3, String(line.dropFirst(2).dropLast(2)))); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
                bullets.append(String(line.dropFirst(2)))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[line.startIndex..<dot].allSatisfy(\.isNumber),
               !line[line.startIndex..<dot].isEmpty, line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
                numbered.append(String(line[line.index(dot, offsetBy: 2)...]))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                quote.append(String(line.dropFirst(2)))
                continue
            }
            flushLists()
            paragraph.append(line)
        }
        if let lines = codeLines { blocks.append(.code(language: codeLanguage, code: lines.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }
}
