import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the bundled Python (spaCy) analyzer as a subprocess and decodes its JSON.
enum PythonEngine {

    /// Absolute path to the project root, used as a development fallback when the
    /// app is run via `swift run` rather than from a packaged .app bundle.
    private static let devRoot = "/Users/robertalvarez/langcheck"

    /// Locate the Python interpreter: prefer the copy bundled in the .app,
    /// fall back to the project venv during development.
    static func pythonURL() -> URL? {
        if let res = Bundle.main.resourceURL {
            let standalone = res.appendingPathComponent("pyengine/python/bin/python3")
            if FileManager.default.isExecutableFile(atPath: standalone.path) { return standalone }

            let venv = res.appendingPathComponent("pyengine/venv/bin/python3")
            if FileManager.default.isExecutableFile(atPath: venv.path) { return venv }
        }
        let dev = URL(fileURLWithPath: "\(devRoot)/venv/bin/python3")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    /// Directory that contains cli.py + analyzer.py (the working dir for the run).
    static func engineDirURL() -> URL? {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("pyengine")
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("cli.py").path) {
                return bundled
            }
        }
        let dev = URL(fileURLWithPath: devRoot)
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent("cli.py").path) {
            return dev
        }
        return nil
    }

    /// Synchronous — call from a background task. Sends `text` to stdin and
    /// decodes the resulting report (or throws an EngineError with details).
    static func analyze(text: String, phrase: String?, clean: Bool) throws -> Report {
        guard let python = pythonURL(), let dir = engineDirURL() else {
            throw EngineError(message:
                "Could not find the bundled Python engine. If running from source, make sure "
                + "\(devRoot)/venv and cli.py exist; if packaged, re-run the build step.")
        }

        let proc = Process()
        proc.executableURL = python
        var args = [dir.appendingPathComponent("cli.py").path]
        if let phrase, !phrase.isEmpty { args += ["--phrase", phrase] }
        if clean { args += ["--clean"] }
        proc.arguments = args
        proc.currentDirectoryURL = dir   // so `import analyzer` resolves

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe

        // Drain stderr on a separate queue so a full pipe buffer can't deadlock us.
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try proc.run()
        } catch {
            throw EngineError(message: "Failed to launch Python: \(error.localizedDescription)")
        }

        if let data = text.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        group.wait()

        if let report = try? JSONDecoder().decode(Report.self, from: outData) {
            return report
        }
        // Engine reported a structured error?
        if let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
           let msg = obj["error"] as? String {
            throw EngineError(message: msg)
        }
        let errText = String(data: stderrData, encoding: .utf8) ?? ""
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let detail = (errText + "\n" + outText).trimmingCharacters(in: .whitespacesAndNewlines)
        throw EngineError(message: "The analysis engine returned no valid result.\n\n\(detail)")
    }
}
