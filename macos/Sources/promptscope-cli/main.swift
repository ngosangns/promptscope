import Foundation
import PromptscopeKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

guard let command = arguments.first else {
    fail("dùng: promptscope-cli scan | report grok|kiro-ide|kiro-cli|omp|pi|devin <đường dẫn>")
}

switch command {
case "scan":
    let scan = LibraryScanner.scan(
        grokHome: LibraryScanner.defaultGrokHome,
        kiroHome: LibraryScanner.defaultKiroHome,
        ompHome: LibraryScanner.defaultOmpHome,
        piHome: LibraryScanner.defaultPiHome,
        devinHome: LibraryScanner.defaultDevinHome
    )
    let counts = Dictionary(grouping: scan.sessions, by: \.source).mapValues(\.count)
    print("sessions \(scan.sessions.count)")
    for source in AgentSource.allCases {
        print("  \(source.label) \(counts[source] ?? 0)")
    }
    print("cli rỗng đã bỏ \(scan.skippedEmptyCLI)")
    for note in scan.notes { print(note) }
case "report":
    guard arguments.count >= 3 else {
        fail("dùng: promptscope-cli report grok|kiro-ide|kiro-cli|omp|pi|devin <đường dẫn>")
    }
    let source: AgentSource
    switch arguments[1] {
    case "grok": source = .grok
    case "kiro-ide": source = .kiroIDE
    case "kiro-cli": source = .kiroCLI
    case "omp": source = .omp
    case "pi": source = .pi
    case "devin": source = .devin
    default: fail("nguồn phải là grok, kiro-ide, kiro-cli, omp, pi, hoặc devin")
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
    print(ReportText.plain(SessionAnalyzer.report(for: ref)))
default:
    fail("lệnh không rõ: \(command)")
}
