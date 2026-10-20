import Foundation

/// DeepSeek Harness writes one append-only session log, `session.vN.jsonl` or
/// the same name with `.zstd`. v4 is the only generation this reader accepts.
/// The standing prompt is the rendered system message plus the user rows whose
/// source says what they are: instructions, the skill catalog, and runtime
/// snapshots. Tool schemas live on the latest `request/header`.
enum DshAnalyzer {
    static func report(_ ref: SessionRef) -> SessionReport {
        let url = URL(fileURLWithPath: ref.locator)
        guard let text = DshLog.text(url: url) else {
            return empty(ref, note: "Không giải nén được log DSH.")
        }
        return analyze(ref, text: text)
    }

    private static func analyze(_ ref: SessionRef, text: String) -> SessionReport {
        var version: Int?
        var standing: [SliceKind: Int] = [:]
        var transcript: [SliceKind: Int] = [:]
        var skills: [SkillMeasure] = []
        var rulesBytes = 0
        var runtimeBytes = 0
        var timeBytes = 0
        var catalogBytes = 0
        var tools: [String: ToolMeasure] = [:]
        var callNames: [String: String] = [:]
        var heavy: [(String, Int)] = []
        var turns: [TurnMeasure] = []
        var trajectory: [TrajectoryEntry] = []
        var currentTurn = 0
        var promptTokens: Int?
        var contextWindow: Int?
        var model: String?
        var prunedTokens = 0
        var prunedRanges = 0
        var sawTurn = false
        var turnIndex = 0
        var userBytes = 0
        var replyBytes = 0
        var inTurn = false
        var openPreview = ""

        func closeTurn() {
            guard inTurn else { return }
            turns.append(TurnMeasure(index: turnIndex, preview: openPreview, userBytes: userBytes, replyBytes: replyBytes))
            inTurn = false
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let object = JSONFile.lineObject(String(line)) else { continue }
            let type = object["type"] as? String ?? ""
            let data = object["data"] as? [String: Any] ?? [:]
            switch type {
            case "session":
                version = dshInt(object["version"])
            case "turn/start":
                sawTurn = true
                currentTurn = dshInt(data["turn"]) ?? currentTurn + 1
            case "system/message":
                let text = dshMessageText(data["message"])
                standing[.system] = text.utf8.count
            case "user/message":
                let source = data["source"] as? [String: Any] ?? [:]
                let kind = source["kind"] as? String ?? ""
                let text = dshContentText(data["content"])
                switch kind {
                case "agent-instructions":
                    rulesBytes = text.utf8.count
                case "skill-catalog":
                    catalogBytes = text.utf8.count
                    skills = dshParseSkills(text)
                case "runtime-context":
                    runtimeBytes = text.utf8.count
                case "time-context":
                    timeBytes = text.utf8.count
                case "user":
                    if inTurn { closeTurn() }
                    trajectory.append(TrajectoryEntry(
                        index: trajectory.count, at: dshMillis(object["time"]), turn: max(currentTurn, turnIndex + 1),
                        kind: "user", label: PromptText.preview(text, limit: 80), bytes: text.utf8.count
                    ))
                    turnIndex += 1
                    openPreview = PromptText.preview(text, limit: 140)
                    userBytes = text.utf8.count
                    replyBytes = 0
                    inTurn = true
                    transcript[.user, default: 0] += text.utf8.count
                default:
                    break
                }
            case "request/header":
                // A series repeats the same catalog. Last header wins, matching the other agents.
                guard let header = data["header"] as? [String: Any],
                      let listed = header["tools"] as? [[String: Any]] else { break }
                standing[.toolDefs] = 0
                var definitions: [String: Int] = [:]
                for tool in listed {
                    let name = tool["name"] as? String ?? "tool"
                    let size = (try? JSONSerialization.data(withJSONObject: tool))?.count ?? 0
                    standing[.toolDefs, default: 0] += size
                    definitions[name] = size
                }
                for (name, size) in definitions {
                    var row = tools[name] ?? ToolMeasure(name: name)
                    row.definitionBytes = size
                    tools[name] = row
                }
                if let config = header["config"] as? [String: Any] {
                    model = dshNonEmpty(config["model"]) ?? model
                }
            case "request/context":
                contextWindow = dshInt(data["contextWindow"]) ?? contextWindow
                model = dshNonEmpty(data["model"]) ?? model
            case "tool/call":
                let name = data["name"] as? String ?? "tool"
                if let callID = data["callId"] as? String { callNames[callID] = name }
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: dshMillis(object["time"]), turn: currentTurn,
                    kind: "tool", label: name, bytes: (data["arguments"] as? String ?? "").utf8.count
                ))
                var row = tools[name] ?? ToolMeasure(name: name)
                row.calls += 1
                tools[name] = row
            case "tool/result":
                let message = data["message"] as? [String: Any] ?? [:]
                let callID = message["toolCallId"] as? String ?? ""
                let name = callNames[callID] ?? "tool"
                let size = dshContentText(message["content"]).utf8.count
                var row = tools[name] ?? ToolMeasure(name: name)
                row.resultBytes += size
                tools[name] = row
                transcript[.toolResult, default: 0] += size
                replyBytes += size
                if size > 0 { heavy.append((name, size)) }
                if let index = trajectory.lastIndex(where: { $0.kind == "tool" && $0.label == name && $0.durationMs == nil }) {
                    trajectory[index].bytes += size
                    if let start = trajectory[index].at, let end = dshMillis(object["time"]), end >= start {
                        trajectory[index].durationMs = end - start
                    }
                }
            case "assistant/message":
                let message = data["message"] as? [String: Any] ?? [:]
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: dshMillis(object["time"]), turn: currentTurn,
                    kind: "assistant", label: PromptText.preview(dshContentText(message["content"]), limit: 80),
                    bytes: dshContentText(message["content"]).utf8.count
                ))
                let parts = message["content"] as? [[String: Any]] ?? []
                for part in parts {
                    let size = (part["text"] as? String ?? "").utf8.count
                    if part["type"] as? String == "reasoning" {
                        transcript[.reasoning, default: 0] += size
                    } else {
                        transcript[.assistant, default: 0] += size
                    }
                    replyBytes += size
                }
                if let usage = data["usage"] as? [String: Any] {
                    promptTokens = dshInt(usage["inputTokens"]) ?? promptTokens
                }
            case "compaction/start":
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: dshMillis(object["time"]), turn: currentTurn,
                    kind: "compaction", label: "bắt đầu nén", bytes: 0
                ))
            case "compaction/prune":
                prunedRanges += 1
                prunedTokens += dshInt(data["shadowedTokenCount"]) ?? 0
            default:
                break
            }
        }
        if inTurn { closeTurn() }
        if rulesBytes > 0 { standing[.rules] = rulesBytes }
        if catalogBytes > 0 { standing[.skills] = catalogBytes }
        let snapshotBytes = runtimeBytes + timeBytes
        if snapshotBytes > 0 { standing[.other] = snapshotBytes }

        var notes = [
            "Prompt đứng là system prompt đã render, cộng luật, catalog skill và snapshot runtime. Schema tool lấy từ request/header mới nhất.",
            "Token đầu vào là inputTokens của lượt assistant cuối, không phải byte/4.",
            "DSH không ghi đường dẫn SKILL.md, nên không có kích thước đĩa hay số lần đọc.",
        ]
        if !sawTurn {
            notes.append("Log không có turn nào.")
        }
        if let version, version != 4 {
            notes.append("Log phiên bản \(version) chưa được đọc. Chỉ v4.")
        }
        if prunedRanges > 0 {
            notes.append("Compaction đã che \(prunedRanges) đoạn, \(prunedTokens) token ước lượng của harness.")
        }
        var reportRef = ref
        if let model, reportRef.model == nil { reportRef.model = model }
        let percent: Double? = {
            guard let promptTokens, let contextWindow, contextWindow > 0 else { return nil }
            return 100 * Double(promptTokens) / Double(contextWindow)
        }()
        let ranked = heavy.sorted { $0.1 > $1.1 }.prefix(8).enumerated().map { index, item in
            HeavyResult(rank: index + 1, tool: item.0, bytes: item.1)
        }
        return SessionReport(
            ref: reportRef,
            standing: dshPack(standing),
            transcript: dshPack(transcript),
            sections: [],
            skills: skills,
            mcp: mcpServers(tools.values),
            tools: tools.values.sorted { lhs, rhs in
                if lhs.calls != rhs.calls { return lhs.calls > rhs.calls }
                return lhs.name < rhs.name
            },
            turns: turns,
            trajectory: trajectory,
            heavy: ranked,
            steering: [],
            contextPercent: percent,
            contextWindow: contextWindow,
            promptTokens: promptTokens,
            notes: notes,
            truncated: false
        )
    }

    private static func empty(_ ref: SessionRef, note: String) -> SessionReport {
        SessionReport(
            ref: ref, standing: [], transcript: [], sections: [], skills: [], mcp: [], tools: [],
            turns: [], heavy: [], steering: [], contextPercent: nil, contextWindow: nil,
            notes: [note], truncated: true
        )
    }
}

enum DshLog {
    /// Plain `.jsonl` is what the tests write. A `.zstd` log is inflated with the `zstd` binary.
    static func text(url: URL) -> String? {
        if url.pathExtension == "zstd" {
            return ZstdCommand.inflate(url: url, firstLineOnly: false)
        }
        let (text, _) = Files.readText(url: url, maxBytes: 64 * 1024 * 1024)
        return text.isEmpty && !FileManager.default.fileExists(atPath: url.path) ? nil : text
    }

    /// The session row is the first line, so the library list stops there.
    static func prefix(url: URL) -> String? {
        if url.pathExtension == "zstd" {
            return ZstdCommand.inflate(url: url, firstLineOnly: true)
        }
        return text(url: url)
    }

    /// The first session row, for the library list. Stops once cwd, depth, and a real user line are known.
    static func header(url: URL) -> DshHeader {
        guard let text = prefix(url: url) else { return DshHeader() }
        var header = DshHeader()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let object = JSONFile.lineObject(String(line)) else { continue }
            switch object["type"] as? String {
            case "session":
                header.version = dshInt(object["version"])
                header.id = dshNonEmpty(object["id"]) ?? header.id
                header.cwd = object["cwd"] as? String ?? header.cwd
                if let millis = dshInt(object["createdAt"]) {
                    header.created = Date(timeIntervalSince1970: Double(millis) / 1000)
                }
                header.subagent = (dshInt(object["delegationDepth"]) ?? 0) > 0
                header.agent = dshNonEmpty(object["agentPreset"])
            case "request/context":
                let data = object["data"] as? [String: Any] ?? [:]
                header.model = dshNonEmpty(data["model"]) ?? header.model
            case "user/message":
                let data = object["data"] as? [String: Any] ?? [:]
                let source = data["source"] as? [String: Any] ?? [:]
                if source["kind"] as? String == "user", header.title.isEmpty {
                    header.title = PromptText.preview(dshContentText(data["content"]), limit: 90)
                }
            case "turn/start":
                header.hasTurn = true
            default:
                break
            }
            if header.hasTurn && !header.title.isEmpty && header.model != nil && header.version != nil {
                break
            }
        }
        return header
    }

}

struct DshHeader {
    var version: Int?
    var id = ""
    var cwd = ""
    var title = ""
    var model: String?
    var agent: String?
    var created: Date?
    var subagent = false
    var hasTurn = false
}

private func dshMessageText(_ message: Any?) -> String {
    guard let message = message as? [String: Any] else { return "" }
    return dshContentText(message["content"])
}

private func dshContentText(_ content: Any?) -> String {
    guard let parts = content as? [Any] else { return "" }
    return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
}

/// Catalog rows look like ``- `name`: summary``.
private func dshParseSkills(_ text: String) -> [SkillMeasure] {
    let pattern = #"(?m)^[ \t]*- `([^`]+)`:\s*"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var order: [String] = []
    var byName: [String: SkillMeasure] = [:]
    for (index, match) in matches.enumerated() {
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        let start = match.range.location
        let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
        let block = ns.substring(with: NSRange(location: start, length: max(end - start, 0)))
        let measure = SkillMeasure(
            name: name,
            catalogBytes: block.utf8.count,
            summary: PromptText.preview(block, limit: 180),
            path: nil,
            origin: "catalog"
        )
        if var existing = byName[name] {
            if measure.catalogBytes > existing.catalogBytes {
                existing.catalogBytes = measure.catalogBytes
                existing.summary = measure.summary
            }
            byName[name] = existing
        } else {
            order.append(name)
            byName[name] = measure
        }
    }
    return order.compactMap { byName[$0] }
}

/// `mcp__server__tool` is one flat list in the header. The server is the middle piece.
/// `mcp__server__tool` is one flat list in the header. The server is the middle piece.
private func mcpServers(_ tools: Dictionary<String, ToolMeasure>.Values) -> [McpMeasure] {
    var grouped: [String: [ToolMeasure]] = [:]
    for tool in tools {
        guard let server = mcpServer(tool.name) else { continue }
        grouped[server, default: []].append(tool)
    }
    return grouped.keys.sorted().map { server in
        let rows = grouped[server] ?? []
        let prefix = "mcp__\(server)__"
        let names = rows.map { String($0.name.dropFirst(prefix.count)) }.sorted()
        return McpMeasure(
            name: server,
            catalogBytes: rows.reduce(0) { $0 + $1.definitionBytes },
            toolCount: names.count,
            status: "schema",
            tools: names,
            blurb: ""
        )
    }
}

private func dshMillis(_ value: Any?) -> Int? {
    guard let number = dshInt(value), number > 1_000_000_000_000 else { return nil }
    return number
}

private func dshInt(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

private func dshPack(_ map: [SliceKind: Int]) -> [Slice] {
    SliceKind.allCases.compactMap { kind in
        guard let bytes = map[kind], bytes > 0 else { return nil }
        return Slice(kind: kind, bytes: bytes)
    }
}

private func dshNonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func mcpServer(_ name: String) -> String? {
    let pieces = name.components(separatedBy: "__")
    guard pieces.count >= 3, pieces[0] == "mcp", !pieces[1].isEmpty else { return nil }
    return pieces[1]
}
