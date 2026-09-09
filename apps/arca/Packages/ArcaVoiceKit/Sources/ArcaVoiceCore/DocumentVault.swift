import Foundation

/// The user's document vault — a local folder of official papers (사업자등록증,
/// 통장사본, certificates…) ARCA may attach to outbound email after approval.
/// Triage passes the *file listing* (names only) to the model and the model
/// picks an exact filename, so resolution is deterministic: no fuzzy matching,
/// no reading file contents, and nothing leaves the machine until the user
/// (or their standing autonomy level) says send.
public enum DocumentVault {
    /// UserDefaults key holding the vault folder path.
    public static let defaultsKey = "documentVaultPath"

    static let attachableExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "heic", "docx", "xlsx", "hwp", "hwpx", "zip",
    ]

    public static var folderURL: URL? {
        if let configured = UserDefaults.standard.string(forKey: defaultsKey),
           !configured.isEmpty {
            let url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath,
                          isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                return url
            }
        }
        // Default: ~/Documents/IDs when it exists (the conventional spot for
        // registration certs and IDs).
        let fallback = ArcaConfig.realHome
            .appendingPathComponent("Documents/IDs", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDir),
           isDir.boolValue {
            return fallback
        }
        return nil
    }

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let modifiedAt: Date
    }

    /// Top-level attachable files, newest first, capped so the triage prompt
    /// stays small.
    public static func entries(limit: Int = 40) -> [Entry] {
        guard let folder = folderURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                  options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url -> Entry? in
            guard attachableExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return Entry(name: url.lastPathComponent, url: url,
                         modifiedAt: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
        .prefix(limit)
        .map { $0 }
    }

    /// Exact-name lookup against the current listing (the model picks from the
    /// listing we gave it, so anything else is a refusal, not a guess).
    public static func resolve(_ filename: String) -> Entry? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return entries().first { $0.name == trimmed }
    }

    /// MIME type for the transport, from the file extension.
    public static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "hwp": return "application/x-hwp"
        case "hwpx": return "application/x-hwpx"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
