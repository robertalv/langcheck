import SwiftUI
import AppKit

/// One color per metric. Python span offsets are Unicode *scalar* offsets,
/// which line up with Swift's `String.UnicodeScalarView` indices.
enum MetricColors {
    static let map: [String: NSColor] = [
        "rather":             .systemRed,
        "in_before_gerund":   .systemOrange,
        "contractions":       .systemTeal,
        "will_shall":         .systemBlue,
        "possessive_gerund":  .systemPurple,
        "dropped_article":    .systemPink,
        "complementizer":     .systemGreen,
        "is_this":            .systemBrown,
        "top_degree_adverbs": .systemYellow,
    ]
    static func nsColor(for key: String) -> NSColor { map[key] ?? .systemGray }
    static func color(for key: String) -> Color { Color(nsColor: nsColor(for: key)) }
}

/// Read-only, scrollable NSTextView that paints the document with a background
/// color behind every enabled metric's spans.
struct HighlightedTextView: NSViewRepresentable {
    let text: String
    let metrics: [Metric]
    let enabled: Set<String>

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 10, height: 10)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textStorage?.setAttributedString(makeAttributed())
    }

    private func makeAttributed() -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        let scalars = text.unicodeScalars
        func index(_ offset: Int) -> String.Index? {
            scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex)
        }

        for metric in metrics where enabled.contains(metric.key) {
            let color = MetricColors.nsColor(for: metric.key).withAlphaComponent(0.35)
            for span in metric.highlightSpans {
                guard span.count == 2,
                      let lo = index(span[0]),
                      let hi = index(span[1]),
                      lo < hi else { continue }
                attr.addAttribute(.backgroundColor, value: color, range: NSRange(lo..<hi, in: text))
            }
        }
        return attr
    }
}
