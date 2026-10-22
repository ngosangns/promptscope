import Foundation

extension PromptscopeDispatch {
    static func scanCommand(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(args, bools: ["json"], values: [], repeats: [])
        if parsed.help { return .exit(code: 0, stdout: scanHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope scan --help", json: parsed.json)
        }
        if let extra = parsed.positionals.first {
            return usage("unexpected argument: \(extra)", hint: "run: promptscope scan --help", json: parsed.json)
        }
        let scan = environment.roots.scan()
        if !parsed.json {
            return ok(scanText(scan))
        }
        var bySource: [String: Int] = [:]
        for source in AgentSource.allCases { bySource[source.rawValue] = 0 }
        for session in scan.sessions {
            bySource[session.source.rawValue, default: 0] += 1
        }
        let payload: [String: Any] = [
            "sessions": scan.sessions.count,
            "bySource": bySource,
            "skippedEmptyCli": scan.skippedEmptyCLI,
            "notes": scan.notes,
        ]
        return jsonOK(payload, failure: "could not write scan")
    }

    static func sessionsCommand(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        if args.isEmpty || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
            return .exit(code: 0, stdout: sessionsHelp + "\n", stderr: "")
        }
        let rest = Array(args.dropFirst())
        switch args[0] {
        case "list":
            return sessionsList(rest, environment: environment)
        case "show":
            return sessionsShow(rest, environment: environment)
        default:
            return usage(
                "unknown command: sessions \(args[0])",
                hint: "run: promptscope sessions --help",
                json: rest.contains("--json")
            )
        }
    }

    static func sessionsList(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(
            args,
            bools: ["json", "include-subagents", "include-temporary"],
            values: ["source", "since", "cwd", "query", "limit"],
            repeats: []
        )
        if parsed.help { return .exit(code: 0, stdout: sessionsListHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope sessions list --help", json: parsed.json)
        }
        if let extra = parsed.positionals.first {
            return usage("unexpected argument: \(extra)", hint: "run: promptscope sessions list --help", json: parsed.json)
        }
        let options: ListOptions
        switch ListOptions.make(parsed, now: environment.now) {
        case .options(let value):
            options = value
        case .problem(let message):
            return usage(message, hint: "run: promptscope sessions list --help", json: parsed.json)
        }
        let rows = options.apply(environment.roots.scan().sessions)
        if !parsed.json {
            let text = rows.map(sessionLine).joined(separator: "\n")
            return ok(text.isEmpty ? "" : text + "\n")
        }
        return jsonOK(["sessions": rows.map(sessionObject)], failure: "could not write sessions")
    }

    static func sessionsShow(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(args, bools: ["json"], values: [], repeats: [])
        if parsed.help { return .exit(code: 0, stdout: sessionsShowHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope sessions show --help", json: parsed.json)
        }
        guard let id = parsed.positionals.first else {
            return usage("missing session id", hint: "run: promptscope sessions show --help", json: parsed.json)
        }
        if parsed.positionals.count > 1 {
            return usage(
                "unexpected argument: \(parsed.positionals[1])",
                hint: "run: promptscope sessions show --help",
                json: parsed.json
            )
        }
        guard let ref = environment.roots.scan().sessions.first(where: { $0.id == id }) else {
            return finish(
                code: 3,
                message: "session not found: \(id)",
                hint: "run: promptscope sessions list",
                json: parsed.json
            )
        }
        switch loadReport(ref) {
        case .report(let report):
            let summary = ReportJSON.summary(report)
            if !parsed.json {
                return ok(showText(ref, summary: summary))
            }
            return jsonOK(
                ["session": sessionObject(ref), "summary": summary],
                failure: "could not write session"
            )
        case .stop(let action):
            return action(parsed.json)
        }
    }

    static func reportCommand(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(
            args,
            bools: ["json", "summary", "no-text"],
            values: ["max-bytes"],
            repeats: ["section"]
        )
        if parsed.help { return .exit(code: 0, stdout: reportHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope report --help", json: parsed.json)
        }
        var seenSections = Set<String>()
        let sections = (parsed.repeated["section"] ?? []).filter { seenSections.insert($0).inserted }
        if parsed.bools.contains("summary"), !sections.isEmpty {
            return usage(
                "use either --summary or --section",
                hint: "run: promptscope report --help",
                json: parsed.json
            )
        }
        for name in sections where !ReportJSON.sectionKeys.contains(name) {
            return usage(
                "unknown section: \(name)",
                hint: "sections: \(ReportJSON.sectionKeys.joined(separator: ", "))",
                json: parsed.json
            )
        }
        let maxBytes: Int?
        if let text = parsed.values["max-bytes"] {
            guard let number = Int(text), number > 0, String(number) == text else {
                return usage(
                    "--max-bytes needs a positive integer",
                    hint: "run: promptscope report --help",
                    json: parsed.json
                )
            }
            maxBytes = number
        } else {
            maxBytes = nil
        }
        let loaded: Loaded
        switch parsed.positionals.count {
        case 1:
            loaded = reportByID(parsed.positionals[0], environment: environment)
        case 2:
            loaded = reportByPath(source: parsed.positionals[0], path: parsed.positionals[1])
        default:
            if parsed.positionals.isEmpty {
                return usage("missing session", hint: "run: promptscope report --help", json: parsed.json)
            }
            return usage(
                "unexpected argument: \(parsed.positionals[2])",
                hint: "run: promptscope report --help",
                json: parsed.json
            )
        }
        let report: SessionReport
        switch loaded {
        case .report(let value):
            report = value
        case .stop(let action):
            return action(parsed.json)
        }
        let summary = parsed.bools.contains("summary")
        let noText = parsed.bools.contains("no-text")
        if !parsed.json {
            if summary { return ok(summaryText(report)) }
            if !sections.isEmpty { return ok(sectionText(report, keys: sections, noText: noText)) }
            return ok(ReportText.plain(report) + "\n")
        }
        var payload = ReportJSON.payload(report)
        if noText && !summary { payload = ReportJSON.redacted(payload) }
        var document: [String: Any]
        if summary {
            document = ReportJSON.summary(report)
        } else if !sections.isEmpty {
            document = ReportJSON.selecting(payload, keys: sections)
        } else {
            document = payload
        }
        if let maxBytes {
            document = ReportJSON.fitted(document, maxBytes: maxBytes)
        }
        return jsonOK(document, failure: "could not write trajectory")
    }

    static func skillCommand(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        if args.isEmpty || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
            return .exit(code: 0, stdout: skillHelp + "\n", stderr: "")
        }
        let rest = Array(args.dropFirst())
        switch args[0] {
        case "install":
            return skillInstall(rest, environment: environment)
        case "check":
            return skillCheck(rest, environment: environment)
        default:
            return usage(
                "unknown command: skill \(args[0])",
                hint: "run: promptscope skill --help",
                json: rest.contains("--json")
            )
        }
    }

    static func skillInstall(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(args, bools: ["json", "dry-run"], values: ["dest"], repeats: [])
        if parsed.help { return .exit(code: 0, stdout: skillHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope skill install --help", json: parsed.json)
        }
        if let extra = parsed.positionals.first {
            return usage("unexpected argument: \(extra)", hint: "run: promptscope skill install --help", json: parsed.json)
        }
        let dest = skillDest(parsed, environment: environment)
        let dryRun = parsed.bools.contains("dry-run")
        let names = EmbeddedSkill.files.keys.sorted()
        if !dryRun {
            do {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                for name in names {
                    guard let body = EmbeddedSkill.files[name] else { continue }
                    let url = dest.appendingPathComponent(name)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try Data(body.utf8).write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                }
            } catch {
                return finish(
                    code: 5,
                    message: "could not write skill: \(error.localizedDescription)",
                    hint: nil,
                    json: parsed.json
                )
            }
        }
        let payload: [String: Any] = [
            "dest": dest.path,
            "dryRun": dryRun,
            "files": names,
        ]
        if parsed.json { return jsonOK(payload, failure: "could not write skill install") }
        let verb = dryRun ? "would install" : "installed"
        return ok("\(verb) promptscope skill at \(dest.path)\n")
    }

    static func skillCheck(_ args: [String], environment: PromptscopeEnvironment) -> Action {
        let parsed = parseCommand(args, bools: ["json"], values: ["dest"], repeats: [])
        if parsed.help { return .exit(code: 0, stdout: skillHelp + "\n", stderr: "") }
        if let problem = parsed.problem {
            return usage(problem, hint: "run: promptscope skill check --help", json: parsed.json)
        }
        if let extra = parsed.positionals.first {
            return usage("unexpected argument: \(extra)", hint: "run: promptscope skill check --help", json: parsed.json)
        }
        let dest = skillDest(parsed, environment: environment)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) || !isDir.boolValue {
            return finish(
                code: 3,
                message: "skill directory is missing: \(dest.path)",
                hint: "run: promptscope skill install",
                json: parsed.json
            )
        }
        let diff = skillDiff(dest)
        let payload: [String: Any] = [
            "dest": dest.path,
            "different": diff.different,
            "extra": diff.extra,
            "inSync": diff.inSync,
            "missing": diff.missing,
        ]
        if parsed.json {
            guard let text = JSONText.document(payload) else {
                return finish(code: 5, message: "could not write skill check", hint: nil, json: true)
            }
            return .exit(code: diff.inSync ? 0 : 8, stdout: text + "\n", stderr: "")
        }
        if diff.inSync { return ok("in sync \(dest.path)\n") }
        var lines = ["drift \(dest.path)"]
        for name in diff.missing { lines.append("missing \(name)") }
        for name in diff.different { lines.append("different \(name)") }
        for name in diff.extra { lines.append("extra \(name)") }
        return .exit(code: 8, stdout: lines.joined(separator: "\n") + "\n", stderr: "")
    }
}

// MARK: - sessions

private struct ListOptions {
    var source: AgentSource?
    var since: Date?
    var cwd: String?
    var query: String?
    var limit: Int?
    var includeSubagents = false
    var includeTemporary = false

    enum Built {
        case options(ListOptions)
        case problem(String)
    }

    static func make(_ parsed: ParsedCommand, now: Date) -> Built {
        var options = ListOptions()
        options.includeSubagents = parsed.bools.contains("include-subagents")
        options.includeTemporary = parsed.bools.contains("include-temporary")
        if let source = parsed.values["source"] {
            guard let parsedSource = AgentSource(rawValue: source) else {
                return .problem("unknown source: \(source)")
            }
            options.source = parsedSource
        }
        if let since = parsed.values["since"] {
            guard let date = parseSince(since, now: now) else {
                return .problem("could not read --since: \(since)")
            }
            options.since = date
        }
        if let cwd = parsed.values["cwd"] {
            if cwd.isEmpty { return .problem("missing value for --cwd") }
            options.cwd = cwd
        }
        if let query = parsed.values["query"] {
            if query.isEmpty { return .problem("missing value for --query") }
            options.query = query
        }
        if let limit = parsed.values["limit"] {
            guard let number = Int(limit), number > 0, String(number) == limit else {
                return .problem("--limit needs a positive integer")
            }
            options.limit = number
        }
        return .options(options)
    }

    func apply(_ sessions: [SessionRef]) -> [SessionRef] {
        var rows = sessions.filter { ref in
            if ref.isSubagent && !includeSubagents { return false }
            if ref.isTemporary && !includeTemporary { return false }
            if let source, ref.source != source { return false }
            if let since {
                guard let updated = ref.updatedAt, updated >= since else { return false }
            }
            if let cwd, !cwdMatches(ref.cwd, filter: cwd) { return false }
            if let query, !queryMatches(ref, query: query) { return false }
            return true
        }
        rows.sort { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.id < rhs.id
            }
        }
        if let limit { rows = Array(rows.prefix(limit)) }
        return rows
    }
}

private func cwdMatches(_ cwd: String, filter: String) -> Bool {
    let left = URL(fileURLWithPath: cwd).standardizedFileURL.path
    let right = URL(fileURLWithPath: filter).standardizedFileURL.path
    if left == right { return true }
    let prefix = right.hasSuffix("/") ? right : right + "/"
    return left.hasPrefix(prefix)
}

private func queryMatches(_ ref: SessionRef, query: String) -> Bool {
    let haystack = [ref.title, ref.cwd, ref.id, ref.model ?? "", ref.agent ?? "", ref.source.rawValue]
        .joined(separator: "\n")
        .lowercased()
    return haystack.contains(query.lowercased())
}

private func parseSince(_ text: String, now: Date) -> Date? {
    if text.count >= 2, let unit = text.last, "dhm".contains(unit) {
        let number = text.dropLast()
        if let count = Int(number), count >= 0, number.allSatisfy(\.isNumber) {
            let seconds: TimeInterval
            switch unit {
            case "d": seconds = Double(count) * 86_400
            case "h": seconds = Double(count) * 3_600
            case "m": seconds = Double(count) * 60
            default: seconds = 0
            }
            return now.addingTimeInterval(-seconds)
        }
    }
    if let date = Dates.parse(text) { return date }
    let day = DateFormatter()
    day.calendar = Calendar(identifier: .gregorian)
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(secondsFromGMT: 0)
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: text)
}

private func sessionObject(_ ref: SessionRef) -> [String: Any] {
    [
        "agent": jsonString(ref.agent),
        "contextPercent": jsonDouble(ref.contextPercent),
        "createdAt": jsonDate(ref.createdAt),
        "cwd": ref.cwd,
        "id": ref.id,
        "isSubagent": ref.isSubagent,
        "isTemporary": ref.isTemporary,
        "locator": ref.locator,
        "model": jsonString(ref.model),
        "source": ref.source.rawValue,
        "title": ref.title,
        "transcriptBytes": ref.transcriptBytes,
        "updatedAt": jsonDate(ref.updatedAt),
    ]
}

private func sessionLine(_ ref: SessionRef) -> String {
    let updated = ref.updatedAt.map(UTCTime.string) ?? "-"
    let cwd = ref.cwd.isEmpty ? "-" : ref.cwd
    let title = ref.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return "\(ref.id)\t\(updated)\t\(ref.source.rawValue)\t\(ref.transcriptBytes)\t\(cwd)\t\(title)"
}

private func showText(_ ref: SessionRef, summary: [String: Any]) -> String {
    sessionLine(ref) + "\n" + summaryLines(summary)
}

private func summaryText(_ report: SessionReport) -> String {
    let ref = report.ref
    return ref.title + "\n" + sessionLine(ref) + "\n" + summaryLines(ReportJSON.summary(report))
}

private func summaryLines(_ summary: [String: Any]) -> String {
    var lines: [String] = []
    func int(_ key: String) -> String { "\(summary[key] as? Int ?? 0)" }
    func maybe(_ key: String) -> String {
        if summary[key] is NSNull || summary[key] == nil { return "-" }
        if let value = summary[key] as? Int { return "\(value)" }
        if let value = summary[key] as? Double { return String(value) }
        if let value = summary[key] as? NSNumber { return value.stringValue }
        return "-"
    }
    lines.append("standingBytes \(int("standingBytes"))")
    lines.append("transcriptBytes \(int("transcriptBytes"))")
    lines.append("estimatedTokens \(int("estimatedTokens"))")
    lines.append("contextPercent \(maybe("contextPercent"))")
    lines.append("contextWindow \(maybe("contextWindow"))")
    lines.append("promptTokens \(maybe("promptTokens"))")
    let counts = summary["counts"] as? [String: Any] ?? [:]
    for key in ["sections", "skills", "mcp", "tools", "turns", "entries"] {
        lines.append("\(key) \(counts[key] as? Int ?? 0)")
    }
    let heavy = summary["heavy"] as? [[String: Any]] ?? []
    for item in heavy {
        let label = item["label"] as? String ?? ""
        let bytes = item["bytes"] as? Int ?? 0
        lines.append("heavy \(label) \(bytes)")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func sectionText(_ report: SessionReport, keys: [String], noText: Bool) -> String {
    var lines: [String] = []
    for key in keys {
        lines.append(key)
        switch key {
        case "standing":
            for slice in report.standing where slice.bytes > 0 {
                lines.append("  \(slice.kind.rawValue) \(slice.bytes)")
            }
        case "transcript":
            for slice in report.transcript where slice.bytes > 0 {
                lines.append("  \(slice.kind.rawValue) \(slice.bytes)")
            }
        case "sections":
            for section in report.sections {
                lines.append("  \(section.name) \(section.bytes)")
            }
        case "skills":
            for skill in report.skills {
                lines.append("  \(skill.name) \(skill.catalogBytes)")
            }
        case "mcp":
            for server in report.mcp {
                lines.append("  \(server.name) \(server.catalogBytes)")
            }
        case "tools":
            for tool in report.tools {
                lines.append("  \(tool.name) \(tool.definitionBytes) \(tool.calls) \(tool.resultBytes)")
            }
        case "turns":
            for turn in report.turns {
                if noText {
                    lines.append("  \(turn.index) \(turn.userBytes) \(turn.replyBytes)")
                } else {
                    lines.append("  \(turn.index) \(turn.preview) \(turn.userBytes) \(turn.replyBytes)")
                }
            }
        case "heavy":
            for item in report.heavy {
                lines.append("  \(item.tool) \(item.bytes)")
            }
        case "steering":
            for item in report.steering {
                lines.append("  \(item.name) \(item.bytes)")
            }
        case "entries":
            if noText {
                lines.append("  \(report.trajectory.count)")
            } else {
                for entry in report.trajectory {
                    lines.append("  \(entry.kind) \(entry.label) \(entry.bytes)")
                }
            }
        case "notes":
            for note in report.notes { lines.append("  \(note)") }
        default:
            break
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

// MARK: - report loading

private enum Loaded {
    case report(SessionReport)
    case stop((Bool) -> PromptscopeDispatch.Action)
}

private func reportByID(_ id: String, environment: PromptscopeEnvironment) -> Loaded {
    let sourceName = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
    guard id.contains(":"), AgentSource(rawValue: sourceName) != nil else {
        return .stop { json in
            PromptscopeDispatch.usage(
                "session id must look like source:session",
                hint: "run: promptscope report --help",
                json: json
            )
        }
    }
    guard let ref = environment.roots.scan().sessions.first(where: { $0.id == id }) else {
        return .stop { json in
            PromptscopeDispatch.finish(
                code: 3,
                message: "session not found: \(id)",
                hint: "run: promptscope sessions list",
                json: json
            )
        }
    }
    return loadReport(ref)
}

private func reportByPath(source sourceArg: String, path pathArg: String) -> Loaded {
    let sourceName = sourceArg.split(separator: ":", maxSplits: 1).first.map(String.init) ?? sourceArg
    guard let source = AgentSource(rawValue: sourceName) else {
        return .stop { json in
            PromptscopeDispatch.usage(
                "source must be grok, kiro-ide, kiro-cli, omp, pi, devin, or dsh",
                hint: "run: promptscope report --help",
                json: json
            )
        }
    }
    let path = URL(fileURLWithPath: pathArg).standardizedFileURL.path
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
    return loadReport(ref)
}

private func loadReport(_ ref: SessionRef) -> Loaded {
    switch logStatus(ref) {
    case .ready:
        return .report(SessionAnalyzer.report(for: ref))
    case .missing:
        let path = ref.locator
        return .stop { json in
            PromptscopeDispatch.finish(
                code: 3,
                message: "session file not found: \(path)",
                hint: "run: promptscope sessions list",
                json: json
            )
        }
    case .unparsable:
        let path = ref.locator
        let source = ref.source.rawValue
        return .stop { json in
            PromptscopeDispatch.finish(
                code: 4,
                message: "could not parse \(source) log: \(path)",
                hint: "the file is not a \(source) session log",
                json: json
            )
        }
    }
}

private enum LogRead {
    case ready
    case missing
    case unparsable
}

private func logStatus(_ ref: SessionRef) -> LogRead {
    let url = URL(fileURLWithPath: ref.locator)
    switch ref.source {
    case .grok, .kiroIDE:
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue else { return .unparsable }
        let name = ref.source == .grok ? "chat_history.jsonl" : "messages.jsonl"
        let log = url.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: log.path) { return .ready }
        return jsonLines(log)
    case .kiroCLI:
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue { return .unparsable }
        if Files.size(url) == 0 { return .unparsable }
        if JSONFile.object(url: url) == nil { return .unparsable }
        return .ready
    case .omp, .pi:
        return jsonLines(url)
    case .devin:
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue || Files.size(url) == 0 { return .unparsable }
        if Files.size(url) > 12 * 1024 * 1024 { return .ready }
        if JSONFile.object(url: url, maxBytes: 12 * 1024 * 1024) == nil { return .unparsable }
        return .ready
    case .dsh:
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
        if isDir.boolValue { return .unparsable }
        guard let text = DshLog.text(url: url), !text.isEmpty else { return .unparsable }
        let parsed = text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            JSONFile.lineObject(String(line)) != nil
        }
        return parsed ? .ready : .unparsable
    }
}

private func jsonLines(_ url: URL) -> LogRead {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .missing }
    if isDir.boolValue { return .unparsable }
    if Files.size(url) == 0 { return .ready }
    var sawJSON = false
    var sawContent = false
    _ = Files.forEachLine(url: url, maxBytes: 256 * 1024) { line in
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        sawContent = true
        if JSONFile.lineObject(line) != nil {
            sawJSON = true
            return false
        }
        return true
    }
    if sawContent && !sawJSON { return .unparsable }
    return .ready
}

// MARK: - skill

private struct SkillDiff {
    var missing: [String]
    var different: [String]
    var extra: [String]
    var inSync: Bool { missing.isEmpty && different.isEmpty && extra.isEmpty }
}

private func skillDest(_ parsed: ParsedCommand, environment: PromptscopeEnvironment) -> URL {
    if let dest = parsed.values["dest"] {
        return URL(fileURLWithPath: dest).standardizedFileURL
    }
    return environment.skillDirectory.standardizedFileURL
}

private func skillDiff(_ dest: URL) -> SkillDiff {
    let expected = EmbeddedSkill.files
    var missing: [String] = []
    var different: [String] = []
    var seen = Set<String>()
    for name in expected.keys.sorted() {
        let url = dest.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            missing.append(name)
            continue
        }
        seen.insert(name)
        if text != expected[name] { different.append(name) }
    }
    var extra: [String] = []
    if let enumerator = FileManager.default.enumerator(
        at: dest,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        let base = dest.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            if seen.contains(relative) || expected[relative] != nil { continue }
            extra.append(relative)
        }
    }
    return SkillDiff(
        missing: missing,
        different: different,
        extra: extra.sorted()
    )
}

// MARK: - flags and JSON

struct ParsedCommand {
    var help = false
    var json = false
    var bools: Set<String> = []
    var values: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var positionals: [String] = []
    var problem: String?
}

func parseCommand(
    _ args: [String],
    bools: Set<String>,
    values: Set<String>,
    repeats: Set<String>
) -> ParsedCommand {
    /// A later `--json` still selects the JSON error form when an earlier flag is rejected.
    func done(_ parsed: ParsedCommand) -> ParsedCommand {
        var copy = parsed
        if args.contains("--json") { copy.json = true }
        return copy
    }
    if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
        var parsed = ParsedCommand()
        parsed.help = true
        parsed.json = args.contains("--json")
        return parsed
    }
    var parsed = ParsedCommand()
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--" {
            parsed.positionals.append(contentsOf: args[(index + 1)...])
            break
        }
        if !arg.hasPrefix("-") {
            parsed.positionals.append(arg)
            index += 1
            continue
        }
        let body: String
        let inline: String?
        if let equal = arg.dropFirst(2).firstIndex(of: "="), arg.hasPrefix("--") {
            body = String(arg.dropFirst(2)[..<equal])
            inline = String(arg[arg.index(after: equal)...])
        } else if arg.hasPrefix("--") {
            body = String(arg.dropFirst(2))
            inline = nil
        } else {
            parsed.problem = "unknown flag: \(arg)"
            return done(parsed)
        }
        if body.isEmpty {
            parsed.problem = "unknown flag: \(arg)"
            return done(parsed)
        }
        if bools.contains(body) {
            if inline != nil {
                parsed.problem = "\(flag(body)) does not take a value"
                return done(parsed)
            }
            if parsed.bools.contains(body) {
                parsed.problem = "duplicate flag: \(flag(body))"
                return done(parsed)
            }
            parsed.bools.insert(body)
            if body == "json" { parsed.json = true }
            index += 1
            continue
        }
        if repeats.contains(body) || values.contains(body) {
            let raw: String
            if let inline {
                raw = inline
            } else {
                let next = index + 1
                guard next < args.count, !args[next].hasPrefix("-") else {
                    parsed.problem = "missing value for \(flag(body))"
                    return done(parsed)
                }
                raw = args[next]
                index += 1
            }
            if raw.isEmpty {
                parsed.problem = "missing value for \(flag(body))"
                return done(parsed)
            }
            if repeats.contains(body) {
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parts.isEmpty {
                    parsed.problem = "missing value for \(flag(body))"
                    return done(parsed)
                }
                parsed.repeated[body, default: []].append(contentsOf: parts)
            } else if parsed.values[body] != nil {
                parsed.problem = "duplicate flag: \(flag(body))"
                return done(parsed)
            } else {
                parsed.values[body] = raw
            }
            index += 1
            continue
        }
        parsed.problem = "unknown flag: \(flag(body))"
        return done(parsed)
    }
    return done(parsed)
}

private func flag(_ name: String) -> String { "--\(name)" }

private func ok(_ text: String) -> PromptscopeDispatch.Action {
    .exit(code: 0, stdout: text, stderr: "")
}

private func jsonOK(_ object: Any, failure: String) -> PromptscopeDispatch.Action {
    guard let text = JSONText.document(object) else {
        return PromptscopeDispatch.finish(code: 5, message: failure, hint: nil, json: true)
    }
    return .exit(code: 0, stdout: text + "\n", stderr: "")
}

private func jsonString(_ value: String?) -> Any {
    guard let value else { return NSNull() }
    return value
}

private func jsonDouble(_ value: Double?) -> Any {
    guard let value else { return NSNull() }
    return value
}

private func jsonDate(_ value: Date?) -> Any {
    guard let value else { return NSNull() }
    return UTCTime.string(value)
}

enum UTCTime {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private func scanText(_ scan: LibraryScan) -> String {
    var lines = ["sessions \(scan.sessions.count)"]
    let counts = Dictionary(grouping: scan.sessions, by: \.source).mapValues(\.count)
    for source in AgentSource.allCases {
        lines.append("  \(source.label) \(counts[source] ?? 0)")
    }
    lines.append("empty cli skipped \(scan.skippedEmptyCLI)")
    lines.append(contentsOf: scan.notes)
    return lines.joined(separator: "\n") + "\n"
}
