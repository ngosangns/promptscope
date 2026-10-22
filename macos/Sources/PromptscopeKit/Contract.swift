import Foundation

/// `version` and `schema`, plus the help lines for the commands the contract
/// requires to exit 0. Scan, report and update stay in the CLI executable.
public enum PromptscopeDispatch {
    public enum Action: Equatable {
        case exit(code: Int32, stdout: String, stderr: String)
        case update(args: [String])
    }

    public static let schemaVersion = 1

    public static func dispatch(
        _ arguments: [String],
        releaseVersion: String,
        environment: PromptscopeEnvironment = .live
    ) -> Action {
        guard let command = arguments.first else {
            return finish(code: 2, message: "missing command", hint: "run: promptscope --help", json: false)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--version", "-V":
            return .exit(code: 0, stdout: versionLine(releaseVersion), stderr: "")
        case "--help", "-h", "help":
            return .exit(code: 0, stdout: rootHelp + "\n", stderr: "")
        case "version":
            return version(rest, releaseVersion: releaseVersion)
        case "schema":
            return schema(rest)
        case "update":
            if rest.contains(where: { $0 == "--help" || $0 == "-h" }) {
                return .exit(code: 0, stdout: updateHelp + "\n", stderr: "")
            }
            return .update(args: rest)
        case "scan":
            return scanCommand(rest, environment: environment)
        case "report":
            return reportCommand(rest, environment: environment)
        case "sessions":
            return sessionsCommand(rest, environment: environment)
        case "skill":
            return skillCommand(rest, environment: environment)
        default:
            return finish(
                code: 2,
                message: "unknown command: \(command)",
                hint: "run: promptscope --help",
                json: false
            )
        }
    }

    static let rootHelp = """
    promptscope — measures the prompt of sessions on this machine

    usage: promptscope sessions list [--json] [--source S] [--since ISO|7d] [--cwd PATH] [--query TEXT] [--limit N] [--include-subagents] [--include-temporary]
          promptscope sessions show <id> [--json]
          promptscope scan [--json]
          promptscope report <id> | grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path> [--json] [--section NAME] [--summary] [--no-text] [--max-bytes N]
          promptscope update [--check] [--json] [--force]
          promptscope skill install [--dest DIR] [--json] [--dry-run]
          promptscope skill check [--dest DIR] [--json]
          promptscope version [--json]
          promptscope schema [--json] [<command>]
    """

    static let versionHelp = """
    usage: promptscope version [--json]

    Prints promptscope X.Y.Z. With --json, prints name, version, schemaVersion and commit.
    """

    static let schemaHelp = """
    usage: promptscope schema [--json] [<command>]

    Lists each command as "path  R|M|D  summary". R is read, M mutates, D is destructive.
    With --json, prints the schema catalog, or one command when a name is given.
    """

    static let reportHelp = """
    usage: promptscope report <id> [--json] [--section NAME] [--summary] [--no-text] [--max-bytes N]
          promptscope report grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path> [--json] [--section NAME] [--summary] [--no-text] [--max-bytes N]

    Measures one session. <id> is source:session, the same id sessions list prints, and is looked up with LibraryScanner.
    The two-argument form takes a source and a locator. The source may be a library id such as dsh:<session>; only the part before the colon is used.
    With no extra flags, --json prints the object the window reads.
    --section NAME (repeatable, or a comma list) prints only those keys.
    --summary prints totals: standing bytes, transcript bytes, estimated tokens (standing bytes / 4), context numbers, counts, and the top 5 heavy tool names.
    --no-text keeps the full shape and sets free-text fields that can hold transcript, user, or tool content to null.
    --max-bytes N truncates JSON arrays so the document fits and sets truncated to true.
    """

    static let scanHelp = """
    usage: promptscope scan [--json]

    Counts sessions per source. Without --json the text is unchanged.
    --json prints sessions, bySource, skippedEmptyCli, and notes.
    """

    static let sessionsHelp = """
    usage: promptscope sessions list [--json] [--source S] [--since ISO|7d] [--cwd PATH] [--query TEXT] [--limit N] [--include-subagents] [--include-temporary]
          promptscope sessions show <id> [--json]

    list prints one line per session, or one JSON document with --json.
    Ids match the window: <source>:<session>. Subagents and temporary sessions are hidden unless the matching flag is set.
    show prints one row and summary numbers. A missing id exits 3.
    """

    static let sessionsListHelp = """
    usage: promptscope sessions list [--json] [--source S] [--since ISO|7d] [--cwd PATH] [--query TEXT] [--limit N] [--include-subagents] [--include-temporary]

    One session per line, newest update first. --json prints the same rows.
    Titles are metadata. The transcript is not included.
    --since takes an ISO 8601 time or a span such as 7d, 24h, or 30m.
    --query matches title, cwd, id, model, and agent. It does not search the transcript.
    """

    static let sessionsShowHelp = """
    usage: promptscope sessions show <id> [--json]

    One row plus summary numbers for a session id from sessions list.
    Exits 3 when the id is not in the library.
    """

    static let skillHelp = """
    usage: promptscope skill install [--dest DIR] [--json] [--dry-run]
          promptscope skill check [--dest DIR] [--json]

    install writes the embedded skill. The default directory is ~/.agents/skills/promptscope.
    check compares that directory with the embedded skill. Exit 8 is drift. Exit 3 means the directory is missing.
    """

    static let updateHelp = """
    usage: promptscope update [--check] [--json] [--force]

    Downloads and installs the latest release. This command runs the updater next to the installed binary.
    """

    private struct CommandSpec {
        var name: String
        var summary: String
        var mutates: Bool
        var destructive: Bool
        var flags: [String]
        /// Nil when the command has no JSON output. `scan` is text until `scan --json` exists.
        var schemaName: String?

        var tag: String {
            if destructive { return "D" }
            if mutates { return "M" }
            return "R"
        }

        /// Two spaces between the path, the letter and the summary.
        var line: String { "\(name)  \(tag)  \(summary)" }
    }

    private static let commands: [CommandSpec] = [
        CommandSpec(
            name: "sessions list",
            summary: "lists sessions on this machine",
            mutates: false,
            destructive: false,
            flags: ["--json", "--source", "--since", "--cwd", "--query", "--limit", "--include-subagents", "--include-temporary"],
            schemaName: "sessions-list"
        ),
        CommandSpec(
            name: "sessions show",
            summary: "shows one session and its summary",
            mutates: false,
            destructive: false,
            flags: ["--json"],
            schemaName: "sessions-show"
        ),
        CommandSpec(
            name: "scan",
            summary: "counts sessions per source",
            mutates: false,
            destructive: false,
            flags: ["--json"],
            schemaName: "scan"
        ),
        CommandSpec(
            name: "report",
            summary: "measures one session",
            mutates: false,
            destructive: false,
            flags: ["--json", "--section", "--summary", "--no-text", "--max-bytes"],
            schemaName: "report"
        ),
        CommandSpec(
            name: "update",
            summary: "downloads and installs the latest release",
            mutates: true,
            destructive: false,
            flags: ["--check", "--json", "--force"],
            schemaName: "update"
        ),
        CommandSpec(
            name: "skill install",
            summary: "writes the promptscope skill",
            mutates: true,
            destructive: false,
            flags: ["--dest", "--json", "--dry-run"],
            schemaName: "skill-install"
        ),
        CommandSpec(
            name: "skill check",
            summary: "compares the installed skill with this binary",
            mutates: false,
            destructive: false,
            flags: ["--dest", "--json"],
            schemaName: "skill-check"
        ),
        CommandSpec(
            name: "version",
            summary: "prints the version and schema version",
            mutates: false,
            destructive: false,
            flags: ["--json"],
            schemaName: "version"
        ),
        CommandSpec(
            name: "schema",
            summary: "prints command schemas",
            mutates: false,
            destructive: false,
            flags: ["--json"],
            schemaName: "schema"
        ),
    ]

    private static func versionLine(_ releaseVersion: String) -> String {
        "promptscope \(releaseVersion)\n"
    }

    private static func version(_ args: [String], releaseVersion: String) -> Action {
        let parsed = split(args)
        if parsed.help {
            return .exit(code: 0, stdout: versionHelp + "\n", stderr: "")
        }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope version --help", json: parsed.json)
        }
        if let extra = parsed.positionals.first {
            return usage("unexpected argument: \(extra)", hint: "run: promptscope version --help", json: parsed.json)
        }
        if parsed.json {
            let text = versionJSON(releaseVersion: releaseVersion, commit: nil)
            return .exit(code: 0, stdout: text + "\n", stderr: "")
        }
        return .exit(code: 0, stdout: versionLine(releaseVersion), stderr: "")
    }

    private static func schema(_ args: [String]) -> Action {
        let parsed = split(args)
        if parsed.help {
            return .exit(code: 0, stdout: schemaHelp + "\n", stderr: "")
        }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope schema --help", json: parsed.json)
        }
        let name = parsed.positionals.isEmpty ? nil : parsed.positionals.joined(separator: " ")
        if let name, !commands.contains(where: { $0.name == name }) {
            return usage("unknown command: \(name)", hint: "run: promptscope schema", json: parsed.json)
        }
        if !parsed.json {
            let lines: [String]
            if let name, let spec = commands.first(where: { $0.name == name }) {
                lines = [spec.line]
            } else {
                lines = commands.map(\.line)
            }
            return .exit(code: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
        }
        let specs = name.map { wanted in commands.filter { $0.name == wanted } } ?? commands
        switch jsonDocument(specs: specs, catalog: name == nil, json: true) {
        case .text(let text):
            return .exit(code: 0, stdout: text + "\n", stderr: "")
        case .stop(let action):
            return action
        }
    }

    /// `version --json`. `commit` is null unless a build stamps one.
    static func versionJSON(releaseVersion: String, commit: String?) -> String {
        let commitJSON = commit.map(JSONText.string) ?? "null"
        return "{\"name\":\"promptscope\",\"version\":\(JSONText.string(releaseVersion)),\"schemaVersion\":\(schemaVersion),\"commit\":\(commitJSON)}"
    }

    private enum Built {
        case text(String)
        case stop(Action)
    }

    private static func jsonDocument(specs: [CommandSpec], catalog: Bool, json: Bool) -> Built {
        var entries: [String: Any] = [:]
        var single: [String: Any]?
        for spec in specs {
            switch entry(spec, json: json) {
            case .stop(let action):
                return .stop(action)
            case .object(let object):
                entries[spec.name] = object
                single = object
            }
        }
        let payload: Any
        if catalog {
            guard let errorSchema = parsedSchema("error") else {
                return .stop(brokenSchema("error", json: json))
            }
            payload = [
                "name": "promptscope",
                "schemaVersion": schemaVersion,
                "commands": entries,
                "error": errorSchema,
            ] as [String: Any]
        } else if let single {
            payload = single
        } else {
            return .stop(brokenSchema("catalog", json: json))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return .stop(brokenSchema("catalog", json: json))
        }
        return .text(text)
    }

    private enum Entry {
        case object([String: Any])
        case stop(Action)
    }

    private static func entry(_ spec: CommandSpec, json: Bool) -> Entry {
        let output: Any
        if let schemaName = spec.schemaName {
            guard let object = parsedSchema(schemaName) else {
                return .stop(brokenSchema(schemaName, json: json))
            }
            output = object
        } else {
            output = NSNull()
        }
        return .object([
            "summary": spec.summary,
            "mutates": spec.mutates,
            "destructive": spec.destructive,
            "flags": spec.flags,
            "output": output,
        ])
    }

    private static func parsedSchema(_ name: String) -> Any? {
        guard let text = EmbeddedSchemas.text(named: name),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object
    }

    private static func brokenSchema(_ name: String, json: Bool) -> Action {
        let message = "embedded schema \(name) is not valid JSON"
        if json {
            let text = JSONText.error(code: "failed-generic", exit: 1, message: message, hint: nil)
            return .exit(code: 1, stdout: text + "\n", stderr: "")
        }
        return .exit(code: 1, stdout: "", stderr: JSONText.errorLines(message: message, hint: nil))
    }

    static func usage(_ message: String, hint: String, json: Bool) -> Action {
        finish(code: 2, message: message, hint: hint, json: json)
    }

    static func finish(code: Int32, message: String, hint: String?, json: Bool) -> Action {
        let name: String
        switch code {
        case 2: name = "usage"
        case 3: name = "unavailable"
        case 4: name = "protocol"
        case 5: name = "failed"
        case 6: name = "needs-confirm"
        case 7: name = "unauthorized"
        case 8: name = "conflict"
        default: name = "failed-generic"
        }
        if json {
            let text = JSONText.error(code: name, exit: Int(code), message: message, hint: hint)
            return .exit(code: code, stdout: text + "\n", stderr: "")
        }
        return .exit(code: code, stdout: "", stderr: JSONText.errorLines(message: message, hint: hint))
    }

    private struct Parsed {
        var help = false
        var json = false
        var positionals: [String] = []
        var problem: String?
    }

    /// `--help` / `-h` wins. A later `--json` still selects the JSON error form.
    private static func split(_ args: [String]) -> Parsed {
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return Parsed(help: true)
        }
        var parsed = Parsed()
        parsed.json = args.contains("--json")
        var seenJSON = false
        for arg in args {
            if arg == "--json" {
                if seenJSON {
                    parsed.problem = "duplicate flag: --json"
                    return parsed
                }
                seenJSON = true
                continue
            }
            if arg.hasPrefix("-") {
                parsed.problem = "unknown flag: \(arg)"
                return parsed
            }
            parsed.positionals.append(arg)
        }
        return parsed
    }
}

enum JSONText {
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    static func error(code: String, exit: Int, message: String, hint: String?) -> String {
        var inner = "{\"code\":\(string(code)),\"exit\":\(exit),\"message\":\(string(message))"
        if let hint {
            inner += ",\"hint\":\(string(hint))"
        }
        inner += "}"
        return "{\"error\":\(inner)}"
    }

    static func errorLines(message: String, hint: String?) -> String {
        var text = "promptscope: \(message)\n"
        if let hint {
            text += "hint: \(hint)\n"
        }
        return text
    }

    static func document(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
