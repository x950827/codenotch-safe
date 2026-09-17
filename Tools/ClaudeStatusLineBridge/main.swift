import Darwin
import Foundation

/// Receives Claude Code's status-line JSON, saves only normalized rate-limit
/// fields, then forwards the original bytes to the user's existing status-line
/// executable. Nothing from stdin is printed or logged by this process.
@main
enum ClaudeStatusLineBridge {
    static func main() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        var arguments = Array(CommandLine.arguments.dropFirst())
        let cacheURL = extractCacheURL(arguments: &arguments)

        if let record = try? ClaudeStatusLineRecord.capture(input) {
            try? persist(record, to: cacheURL)
        }

        if arguments.first == "--" { arguments.removeFirst() }
        guard let executable = arguments.first else { return }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(arguments.dropFirst())
        child.standardOutput = FileHandle.standardOutput
        child.standardError = FileHandle.standardError
        let childInput = Pipe()
        child.standardInput = childInput

        do {
            try child.run()
            childInput.fileHandleForWriting.write(input)
            try? childInput.fileHandleForWriting.close()
            child.waitUntilExit()
            exit(child.terminationStatus)
        } catch {
            exit(127)
        }
    }

    private static func extractCacheURL(arguments: inout [String]) -> URL {
        guard arguments.count >= 2, arguments[0] == "--cache-file" else {
            return ClaudeStatusLineRecord.defaultCacheURL()
        }
        let file = URL(fileURLWithPath: arguments[1])
        arguments.removeFirst(2)
        return file
    }

    private static func persist(_ record: ClaudeStatusLineRecord, to file: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try record.encoded().write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
