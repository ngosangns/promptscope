import Foundation
import PromptscopeKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

/// Marketing version. The release script replaces this assignment from the
/// repo-root VERSION file before `swift build`, and checks the result with
/// `--version`. `promptscope update` smoke-tests that same line.
let releaseVersion = "0.0.0-dev"

guard let command = arguments.first else {
    fail("usage: promptscope scan | report grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path> | update")
}

switch command {
case "--version", "-V", "version":
    print("promptscope \(releaseVersion)")
    exit(0)
case "--help", "-h", "help":
    print("""
    promptscope — measures the prompt of sessions on this machine

    usage: promptscope scan
          promptscope report grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path>
          promptscope update [--check] [--json] [--force]
    """)
    exit(0)
case "update":
    runUpdate(Array(arguments.dropFirst()))
default:
    break
}

switch command {
case "scan":
    let scan = LibraryScanner.scan(
        grokHome: LibraryScanner.defaultGrokHome,
        kiroHome: LibraryScanner.defaultKiroHome,
        ompHome: LibraryScanner.defaultOmpHome,
        piHome: LibraryScanner.defaultPiHome,
        devinHome: LibraryScanner.defaultDevinHome,
        dshHome: LibraryScanner.defaultDshHome
    )
    let counts = Dictionary(grouping: scan.sessions, by: \.source).mapValues(\.count)
    print("sessions \(scan.sessions.count)")
    for source in AgentSource.allCases {
        print("  \(source.label) \(counts[source] ?? 0)")
    }
    print("empty cli skipped \(scan.skippedEmptyCLI)")
    for note in scan.notes { print(note) }
case "report":
    guard arguments.count >= 3 else {
        fail("usage: promptscope-cli report grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path>")
    }
    // The window passes the library id (`dsh:<session>`) as the source argument.
    let sourceName = arguments[1].split(separator: ":", maxSplits: 1).first.map(String.init) ?? arguments[1]
    let source: AgentSource
    switch sourceName {
    case "grok": source = .grok
    case "kiro-ide": source = .kiroIDE
    case "kiro-cli": source = .kiroCLI
    case "omp": source = .omp
    case "pi": source = .pi
    case "devin": source = .devin
    case "dsh": source = .dsh
    default: fail("source must be grok, kiro-ide, kiro-cli, omp, pi, devin, or dsh")
    }
    let path = URL(fileURLWithPath: arguments[2]).standardizedFileURL.path
    let ref = SessionRef(
        id: "\(source.rawValue):cli",
        source: source,
        sessionID: URL(fileURLWithPath: path).lastPathComponent,
        title: URL(fileURLWithPath: path).lastPathComponent,
        cwd: "",
        model: nil,
        agent: nil,
        createdAt: nil,
        updatedAt: nil,
        locator: path,
        transcriptBytes: 0,
        isSubagent: false,
        isTemporary: false,
        contextPercent: nil,
        fingerprint: "cli"
    )
    let report = SessionAnalyzer.report(for: ref)
    if arguments.count >= 4, arguments[3] == "--json" {
        let payload: [String: Any] = [
            "entries": report.trajectory.map { entry in
                [
                    "at": entry.at as Any,
                    "turn": entry.turn,
                    "kind": entry.kind,
                    "label": entry.label,
                    "bytes": entry.bytes,
                    "durationMs": entry.durationMs as Any,
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            fail("could not write trajectory")
        }
        print(text)
    } else {
        print(ReportText.plain(report))
    }
default:
    fail("unknown command: \(command)")
}

/// `promptscope update` is the Go updater installed beside this binary. It
/// replaces this file by renaming a new inode, which a running Mach-O cannot do
/// to itself. A `swift run` build has no sibling and says so.
func runUpdate(_ args: [String]) -> Never {
    guard let updater = installedUpdater() else {
        fail("promptscope update: promptscope-update not found next to this binary. Install with task cli:install or a release build.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: updater)
    process.arguments = ["update"] + args
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fail("promptscope update: could not run \(updater): \(error)")
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

func installedUpdater() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = executable.deletingLastPathComponent().appendingPathComponent("promptscope-update-\(releaseVersion)").path
    if FileManager.default.isExecutableFile(atPath: sibling) {
        return sibling
    }
    return nil
}
