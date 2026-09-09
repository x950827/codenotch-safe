import Foundation

/// The complete JSONL conversation Codenotch is allowed to initiate with
/// Codex. It asks for no account details, threads, messages, or credentials.
enum CodexAppServerProtocol {
    private static let initialize =
        #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codenotch_safe_local","title":"Codenotch Safe Local","version":"1.0.0"}}}"#
    private static let initialized = #"{"method":"initialized","params":{}}"#
    private static let readRateLimits = #"{"method":"account/rateLimits/read","id":1}"#

    /// Kept as one inspectable value for the security test. Production sends
    /// these same messages in order, but waits for response 0 before the final
    /// two and keeps stdin open until response 1 arrives.
    static let input = [initialize, initialized, readRateLimits]
        .joined(separator: "\n") + "\n"

    static func exchange(
        send: (String) throws -> Void,
        receive: () throws -> String?,
        closeInput: () -> Void
    ) throws -> [LimitWindow] {
        defer { closeInput() }

        try send(initialize)
        _ = try response(id: 0, receive: receive)

        try send(initialized)
        try send(readRateLimits)
        let rateLimitResponse = try response(id: 1, receive: receive)
        return try parse(rateLimitResponse)
    }

    /// Wait for one matching response while ignoring notifications and replies
    /// to other ids. Closing stdin before this returns lets current app-server
    /// versions shut down before their asynchronous rate-limit read completes.
    private static func response(
        id: Int,
        receive: () throws -> String?
    ) throws -> String {
        while let line = try receive() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let message = object as? [String: Any],
                  (message["id"] as? NSNumber)?.intValue == id
            else { continue }

            if message["error"] != nil { throw UsageProviderError.needsAuth }
            guard message["result"] != nil else {
                throw UsageProviderError.badResponse(status: 0)
            }
            return line
        }
        throw UsageProviderError.badResponse(status: 0)
    }

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

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let writer = input.fileHandleForWriting
        let reader = CodexJSONLineReader(handle: output.fileHandleForReading)
        let windows: [LimitWindow]
        do {
            windows = try CodexAppServerProtocol.exchange(
                send: { message in
                    writer.write(Data((message + "\n").utf8))
                },
                receive: { reader.next() },
                closeInput: { writer.closeFile() }
            )
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw UsageProviderError.badResponse(status: Int(process.terminationStatus))
        }
        return windows
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

/// Incremental newline framing for app-server stdout. `readDataToEndOfFile`
/// cannot be used here because stdin must remain open while the requested
/// response is pending, so neither side would be able to finish first.
private final class CodexJSONLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return String(data: line, encoding: .utf8)
            }

            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll(keepingCapacity: false) }
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
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
