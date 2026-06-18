import Foundation

/// Resolves "the box actually contains a file path" into the file's contents.
///
/// macOS sometimes inserts a dropped file's *path* (or a `file://` URL) into a
/// text view instead of its contents. This catches that case — and also lets a
/// user simply paste a path — so Analyze always works on the real text.
enum InputResolver {
    static func contents(forPathLike raw: String) -> (text: String, name: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("\n") else { return nil }   // multiline = real text

        var path: String?
        if s.hasPrefix("file://"), let url = URL(string: s) {
            path = url.path                    // decodes %20 etc.
        } else if s.hasPrefix("/") {
            path = s                           // POSIX path (literal spaces ok)
        }
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }

        let name = (path as NSString).lastPathComponent
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return (content, name)
        }
        if let data = FileManager.default.contents(atPath: path),
           let content = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1) {
            return (content, name)
        }
        return nil
    }
}
