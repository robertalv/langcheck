import Foundation

/// Custom entry point. `--selftest` exercises the Python bridge headlessly
/// (used by tooling/CI); otherwise we launch the normal SwiftUI app.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        } else {
            LangCheckApp.main()
        }
    }

    private static func runSelfTest() {
        // If a path arg is given, analyze THAT file end-to-end through the same
        // engine the Analyze button uses — proves whether real text yields data.
        if let probe = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("/") }),
           let resolved = InputResolver.contents(forPathLike: probe) {
            do {
                let report = try PythonEngine.analyze(text: resolved.text, phrase: nil, clean: false)
                let totalSpans = report.metrics.reduce(0) { $0 + $1.highlightSpans.count }
                print("FILE ANALYSIS OK — \(resolved.name): \(report.meta.words) words, \(report.meta.sentences) sentences, \(totalSpans) highlight spans")
                print("  analyzed-text length: \(report.text?.count ?? -1)")
                for metric in report.metrics {
                    print("  • \(metric.title): \(metric.headline)  [\(metric.highlightSpans.count) spans]")
                }
                exit(0)
            } catch {
                let message = (error as? EngineError)?.message ?? error.localizedDescription
                FileHandle.standardError.write(Data("FILE ANALYSIS FAIL — \(message)\n".utf8))
                exit(1)
            }
        }

        let sample = """
        I have grown rather angry. I shall state facts which only I know.
        To prove I am the one, I will trace them back to developer.
        I don't care, and your asking for details is this: please stop.
        """
        do {
            let report = try PythonEngine.analyze(
                text: sample,
                phrase: "the system checks out from one end to the other",
                clean: false)
            print("SELFTEST OK — \(report.meta.words) words, \(report.metrics.count) metrics")
            for metric in report.metrics {
                print("  • \(metric.title): \(metric.headline)")
            }

            // Verify the path-resolver safety net against a real file, if present.
            let probe = CommandLine.arguments.dropFirst().first { $0.hasPrefix("/") }
                ?? "/Users/robertalvarez/langcheck/COE.txt"
            if let resolved = InputResolver.contents(forPathLike: probe) {
                let words = resolved.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
                print("PATH-RESOLVE OK — \(resolved.name): \(words) words read from path")
            } else {
                print("PATH-RESOLVE — skipped (\(probe) not found)")
            }
            exit(0)
        } catch {
            let message = (error as? EngineError)?.message ?? error.localizedDescription
            FileHandle.standardError.write(Data("SELFTEST FAIL — \(message)\n".utf8))
            exit(1)
        }
    }
}
