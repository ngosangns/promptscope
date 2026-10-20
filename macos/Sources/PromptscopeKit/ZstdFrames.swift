import Foundation

/// Inflates a DSH `.jsonl.zstd` log with the `zstd` binary. Apple's Compression
/// framework has no zstd algorithm, and `/usr/bin/zstd` is not present on every Mac,
/// so this looks the binary up on `PATH` and then in the usual Homebrew locations.
enum ZstdCommand {
    static func inflate(url: URL, firstLineOnly: Bool) -> String? {
        guard let binary = locate() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-dc", "--", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        if firstLineOnly {
            return readPrefix(output.fileHandleForReading, process)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func readPrefix(_ handle: FileHandle, _ process: Process) -> String? {
        // Listing needs the session row plus the first turn, which land in the first
        // frames. 256 KB covers that and stops before a long transcript. zstd does
        // not flush a single line while the pipe stays open, so this is one read.
        let data = handle.readData(ofLength: 256 * 1024)
        process.terminate()
        process.waitUntilExit()
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    private static func locate() -> String? {
        if let onPath = which() { return onPath }
        for candidate in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func which() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["zstd"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        // `which` only sees this process's PATH. SwiftPM tests have a full one.
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
