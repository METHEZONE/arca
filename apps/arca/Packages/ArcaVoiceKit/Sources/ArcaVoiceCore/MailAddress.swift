import Foundation

public enum MailAddress {
    /// "Name <a@b.com>" → "a@b.com"; a bare address passes through; anything
    /// that isn't shaped like a single address ("a@b.com via X", unbalanced
    /// brackets, "a@b@c") → "". The result is used verbatim as a send target,
    /// so refusing beats guessing.
    public static func address(from sender: String) -> String {
        if let open = sender.lastIndex(of: "<"), let close = sender.lastIndex(of: ">"),
           open < close {
            let inner = String(sender[sender.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            return isPlausibleAddress(inner) ? inner : ""
        }
        let trimmed = sender.trimmingCharacters(in: .whitespaces)
        return isPlausibleAddress(trimmed) ? trimmed : ""
    }

    /// Minimal shape check: one @, non-empty local part, dotted domain, no
    /// whitespace or angle brackets.
    static func isPlausibleAddress(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else {
            return false
        }
        return !candidate.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
    }
}
