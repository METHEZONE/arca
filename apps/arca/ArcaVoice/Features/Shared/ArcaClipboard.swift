import SwiftUI
import ArcaVoiceKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copy to the clipboard, on either platform.
///
/// The app had no pasteboard code at all, which meant the one thing a user most
/// obviously wants to do with a finished meeting note — paste it into Slack, an
/// email, a doc — was the one thing it couldn't do.
enum ArcaClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A copy button that confirms itself.
///
/// Copying is invisible by nature: the clipboard gives no feedback, so without a
/// state change the user cannot tell whether the tap registered and taps again.
/// The label flips to "복사했어요" for a beat, which is the whole reason this is a
/// view rather than a one-line call.
struct CopyButton: View {
    let text: () -> String
    var title: String = L("복사", "Copy")
    var doneTitle: String = L("복사했어요", "Copied")
    var compact = false

    @State private var justCopied = false

    private var label: String { justCopied ? doneTitle : title }
    private var symbol: String { justCopied ? "checkmark" : "doc.on.doc" }

    var body: some View {
        Button {
            ArcaClipboard.copy(text())
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            withAnimation(.spring(duration: 0.25)) { justCopied = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.2)) { justCopied = false }
            }
        } label: {
            // Two branches rather than a ternary on `labelStyle`: the icon-only and
            // title-and-icon styles are different types and can't share one.
            Group {
                if compact {
                    Label(label, systemImage: symbol).labelStyle(.iconOnly)
                } else {
                    Label(label, systemImage: symbol).labelStyle(.titleAndIcon)
                }
            }
            .font(compact ? .caption : .callout.weight(.semibold))
            .foregroundStyle(justCopied ? Color.green : Color.accentColor)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.arcaPress)
        .help(L("회의록을 마크다운으로 복사합니다", "Copy the note as markdown"))
        .accessibilityLabel(justCopied ? doneTitle : title)
    }
}

/// Builds the copyable markdown for a session. Shared by every copy affordance so
/// the clipboard, the vault and the daily digest can't drift apart.
enum SessionClipboardText {
    static func markdown(for session: RecordingSession) -> String {
        guard let note = session.note,
              let summary = note.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            // No summary yet — fall back to the transcript, which is still the
            // thing the user has and might want to paste.
            return transcript(for: session)
        }
        return MeetingNoteMarkdown.clipboardNote(MeetingNoteMarkdown.Content(
            title: session.title,
            date: session.createdAt,
            summary: summary,
            decisions: MeetingNoteMarkdown.decodeDecisions(from: note.decisionsJSON),
            actionItems: MeetingNoteMarkdown.decodeActionItems(from: note.actionItemsJSON),
            durationSeconds: session.duration))
    }

    static func transcript(for session: RecordingSession) -> String {
        let turns = session.segments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.start < $1.start }
        guard !turns.isEmpty else { return session.title }
        var lines = ["# \(session.title)", ""]
        for turn in turns {
            let speaker = turn.speakerKey ?? L("발화자", "Speaker")
            lines.append("**\(speaker)**: \(turn.text)")
        }
        return lines.joined(separator: "\n")
    }
}
