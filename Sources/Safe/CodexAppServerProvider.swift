import Foundation

/// The complete JSONL conversation Codenotch is allowed to initiate with
/// Codex. It asks for no account details, threads, messages, or credentials.
enum CodexAppServerProtocol {
    static let input = [
        #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codenotch_safe_local","title":"Codenotch Safe Local","version":"1.0.0"}}}"#,
        #"{"method":"initialized","params":{}}"#,
        #"{"method":"account/rateLimits/read","id":1}"#,
    ].joined(separator: "\n") + "\n"

    static func parse(_ output: String) throws -> [LimitWindow] {
        for line in output.split(whereSeparator: \Character.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let message = object as? [String: Any],
                  (message["id"] as? NSNumber)?.intValue == 1
            else { continue }

            if message["error"] != nil { throw UsageProviderError.needsAuth }
            guard let result = message["result"] as? [String: Any] else {
                throw UsageProviderError.badResponse(status: 0)
            }

            let indexed = result["rateLimitsByLimitId"] as? [String: Any]
            let selected = indexed?["codex"] as? [String: Any]
                ?? result["rateLimits"] as? [String: Any]
            guard let limits = selected else {
                throw UsageProviderError.nothingMetered("Codex reported no usage windows")
            }

            var windows: [LimitWindow] = []
            for (id, value) in [("primary", limits["primary"]),
                                ("secondary", limits["secondary"])] {
                guard let window = value as? [String: Any],
                      let percent = (window["usedPercent"] as? NSNumber)?.doubleValue,
                      percent.isFinite
                else { continue }
                let minutes = (window["windowDurationMins"] as? NSNumber)?.doubleValue ?? 0
                let resetsAt = (window["resetsAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(LimitWindow(
                    id: id,
                    label: CodexUsage.label(windowSeconds: minutes * 60, fallback: id),
                    usedFraction: percent / 100,
                    resetsAt: resetsAt
                ))
            }
            guard !windows.isEmpty else {
                throw UsageProviderError.nothingMetered("Codex reported no usage windows")
            }
            return windows
        }
        throw UsageProviderError.badResponse(status: 0)
    }
}

/// One fixed invocation of the locally installed Codex CLI.
struct CodexAppServerExecutable: Sendable {
    static let arguments = ["app-server"]
    static let timeout: TimeInterval = 20

    let binary: URL

    static func locate(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        root: URL = URL(fileURLWithPath: "/"),
        fileManager: FileManager = .default
    ) -> CodexAppServerExecutable? {
        // Prefer the signed app's bundled executable. A user PATH entry may be
        // a shell wrapper with routing preconditions that do not apply to the
        // ChatGPT app and that Finder-launched Codenotch cannot satisfy.
        let relativePaths = [
            root.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
            root.appendingPathComponent("opt/homebrew/bin/codex"),
            root.appendingPathComponent("usr/local/bin/codex"),
            home.appendingPathComponent(".local/bin/codex"),
        ]
        guard let binary = relativePaths.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else { return nil }
        return CodexAppServerExecutable(binary: binary)
    }

    func readRateLimits() async throws -> [LimitWindow] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try run() })
            }
        }
    }

    private func run() throws -> [LimitWindow] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments
        process.currentDirectoryURL = scratch
        process.environment = Self.sanitizedEnvironment()

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        input.fileHandleForWriting.write(Data(CodexAppServerProtocol.input.utf8))
        input.fileHandleForWriting.closeFile()

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw UsageProviderError.badResponse(status: Int(process.terminationStatus))
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw UsageProviderError.badResponse(status: 0)
        }
        return try CodexAppServerProtocol.parse(text)
    }

    /// Preserve ordinary locale and network routing while preventing API keys
    /// from changing the CLI's normal account-session precedence.
    private static func sanitizedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowed = [
            "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "SHELL",
            "LANG", "LC_ALL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
            "CODEX_HOME",
        ]
        var environment = allowed.reduce(into: [String: String]()) { result, key in
            if let value = source[key] { result[key] = value }
        }
        environment["PATH"] = environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["TMPDIR"] = environment["TMPDIR"] ?? NSTemporaryDirectory()
        return environment
    }
}

actor CodexAppServerProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"
    nonisolated let glyph = ProviderGlyph.openai

    private let readWindows: @Sendable () async throws -> [LimitWindow]

    init(executable: CodexAppServerExecutable? = .locate()) {
        if let executable {
            self.readWindows = { try await executable.readRateLimits() }
        } else {
            self.readWindows = { throw UsageProviderError.needsAuth }
        }
    }

    init(readWindows: @escaping @Sendable () async throws -> [LimitWindow]) {
        self.readWindows = readWindows
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let windows = try await readWindows()
        Log.usage.debug("codex: read \(windows.count) normalized windows from app-server")
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: windows,
            headlineID: windows.first?.id
        )
    }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.openai.codex", name: "Codex")
    }
}
