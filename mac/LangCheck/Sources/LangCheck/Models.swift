import Foundation

/// Mirrors the JSON emitted by cli.py / analyzer.analyze_text.
/// Unknown keys (e.g. each metric's `stats`) are ignored by Codable.
struct Report: Codable {
    let meta: Meta
    let metrics: [Metric]
    /// The exact text the spans index into (post-clean if enabled).
    let text: String?
}

struct Meta: Codable {
    let words: Int
    let sentences: Int
    let characters: Int
    let source: String?
}

struct Metric: Codable, Identifiable {
    let key: String
    let title: String
    let headline: String
    let examples: [String]
    let note: String
    /// [[start, end], …] character (Unicode scalar) offsets of each hit.
    let spans: [[Int]]?

    var id: String { key }
    var highlightSpans: [[Int]] { spans ?? [] }
}
