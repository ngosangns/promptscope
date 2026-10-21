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
            return empty(ref, note: "Could not decompress the DSH log.")
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
        var stepStart: Int?
        var callEntries: [String: Int] = [:]
        var jobEntries: [String: Int] = [:]
        var compactionEntries: [String: Int] = [:]
        var turnEntry: Int?
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
            case "step/start":
                stepStart = dshMillis(object["time"])
            case "turn/end":
                let reason = (data["reason"] as? [String: Any])?["kind"] as? String ?? "completed"
                trajectory.close(turnEntry, at: dshMillis(object["time"]))
                if reason != "completed" {
                    trajectory.add(
                        at: dshMillis(object["time"]), turn: max(currentTurn, 1), kind: "error",
                        label: "turn \(reason)", failed: true
                    )
                }
            case "llm/retry":
                let failure = data["failure"] as? [String: Any] ?? [:]
                let retry = dshInt(data["retry"]).map { " \($0)/\(dshInt(data["maxRetries"]) ?? 0)" } ?? ""
                trajectory.add(
                    at: dshMillis(object["time"]), turn: max(currentTurn, 1), kind: "retry",
                    label: "retry\(retry) · " + PromptText.preview(
                        (failure["code"] as? String ?? "") + " " + (failure["message"] as? String ?? ""), limit: 70
                    ),
                    durationMs: dshInt(data["delayMs"]), failed: true
                )
            case "assistant/attempt":
                for item in data["stream"] as? [[String: Any]] ?? [] {
                    let chunk = item["chunk"] as? [String: Any]
                    guard chunk?["type"] as? String == "finish",
                          let reason = chunk?["reason"] as? [String: Any],
                          reason["kind"] as? String == "error" else { continue }
                    let failure = reason["failure"] as? [String: Any] ?? [:]
                    trajectory.add(
                        at: dshMillis(item["time"]) ?? dshMillis(object["time"]), turn: max(currentTurn, 1),
                        kind: "error", label: "request failed · " + PromptText.preview(failure["message"] as? String ?? "", limit: 70),
                        failed: true
                    )
                }
            case "job/registered":
                let id = data["jobId"] as? String ?? ""
                let label = data["label"] as? String ?? "job"
                let index = trajectory.add(
                    at: dshInt(data["startedAt"]) ?? dshMillis(object["time"]), turn: max(currentTurn, 1),
                    kind: "job", label: PromptText.preview(label, limit: 70)
                )
                if !id.isEmpty { jobEntries[id] = index }
            case "job/settled":
                let status = data["status"] as? String ?? "completed"
                let detail = data["detail"] as? String ?? ""
                let bad = status != "completed" || detail.contains("exit code:") && !detail.hasSuffix("exit code: 0")
                let index = jobEntries[data["jobId"] as? String ?? ""]
                trajectory.close(index, at: dshInt(data["finishedAt"]) ?? dshMillis(object["time"]), failed: bad)
                if let index, index < trajectory.count, status != "completed" {
                    trajectory[index].label += " · \(status)"
                }
            case "todo/write":
                let todos = data["todos"] as? [[String: Any]] ?? []
                let done = todos.filter { $0["status"] as? String == "completed" }.count
                trajectory.add(
                    at: dshMillis(object["time"]), turn: max(currentTurn, 1), kind: "notice",
                    label: "todos \(done)/\(todos.count) done"
                )
            case "model/selection":
                trajectory.add(
                    at: dshMillis(object["time"]), turn: max(currentTurn, 1), kind: "notice",
                    label: "model → \(data["provider"] as? String ?? "?")/\(data["model"] as? String ?? "?")"
                )
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
                case "skill-invocation":
                    trajectory.add(
                        at: dshMillis(object["time"]), turn: max(currentTurn, 1), kind: "notice",
                        label: "skill invoked · " + PromptText.preview(text, limit: 60), bytes: text.utf8.count
                    )
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
                    turnEntry = trajectory.count - 1
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
                let callID = data["callId"] as? String ?? ""
                if !callID.isEmpty { callNames[callID] = name }
                let arguments = data["arguments"] as? String ?? ""
                let index = trajectory.add(
                    at: dshMillis(object["time"]), turn: currentTurn,
                    kind: TrailLabel.isSubagent(name) ? "subagent" : "tool",
                    label: TrailLabel.tool(name, arguments), bytes: arguments.utf8.count
                )
                if !callID.isEmpty { callEntries[callID] = index }
                var row = tools[name] ?? ToolMeasure(name: name)
                row.calls += 1
                tools[name] = row
            case "tool/result":
                let message = data["message"] as? [String: Any] ?? [:]
                let callID = message["toolCallId"] as? String ?? ""
                let name = callNames[callID] ?? "tool"
                let body = dshContentText(message["content"])
                let size = body.utf8.count
                var row = tools[name] ?? ToolMeasure(name: name)
                row.resultBytes += size
                tools[name] = row
                transcript[.toolResult, default: 0] += size
                replyBytes += size
                if size > 0 { heavy.append((name, size)) }
                let failed = message["isError"] as? Bool ?? false
                trajectory.close(callEntries[callID], at: dshMillis(object["time"]), bytes: size, failed: failed)
            case "assistant/message":
                let message = data["message"] as? [String: Any] ?? [:]
                let at = dshMillis(object["time"])
                let began = stepStart ?? at
                let usage = data["usage"] as? [String: Any]
                // The prompt the provider saw is fresh input plus the cached prefix.
                let input = dshInt(usage?["inputTokens"]).map { $0 + (dshInt(usage?["cacheReadTokens"]) ?? 0) }
                let parts = message["content"] as? [[String: Any]] ?? []
                var first = true
                func think() -> Int? {
                    guard first, let at, let began, at >= began else { return nil }
                    first = false
                    return at - began
                }
                for part in parts {
                    let size = (part["text"] as? String ?? "").utf8.count
                    let type = part["type"] as? String
                    if type == "reasoning" {
                        transcript[.reasoning, default: 0] += size
                        if size > 0 {
                            trajectory.add(
                                at: began, turn: currentTurn, kind: "reasoning", label: "reasoning", bytes: size,
                                durationMs: think(), tokens: input
                            )
                        }
                    } else if type == "text" {
                        transcript[.assistant, default: 0] += size
                        if size > 0 {
                            trajectory.add(
                                at: began, turn: currentTurn, kind: "assistant",
                                label: PromptText.preview(part["text"] as? String ?? "", limit: 80), bytes: size,
                                durationMs: think(), tokens: input
                            )
                        }
                    } else {
                        transcript[.assistant, default: 0] += size
                    }
                    replyBytes += size
                }
                // A cached prefix is billed apart but is still in the prompt: a session whose
                // every request hits the cache records inputTokens 0.
                if let input { promptTokens = input }
                if message["interrupted"] as? Bool == true || data["interrupted"] as? Bool == true {
                    trajectory.add(at: at, turn: currentTurn, kind: "error", label: "reply interrupted", failed: true)
                }
            case "compaction/start":
                let id = data["compactionId"] as? String ?? ""
                let index = trajectory.add(
                    at: dshMillis(object["time"]), turn: currentTurn, kind: "compaction", label: "compaction"
                )
                if !id.isEmpty { compactionEntries[id] = index }
            case "compaction/summary":
                let index = compactionEntries[data["compactionId"] as? String ?? ""]
                if let index, index < trajectory.count {
                    let hidden = dshInt(data["shadowedTokenCount"]) ?? 0
                    let summary = dshContentText(data["summary"]).utf8.count
                    trajectory[index].bytes = summary
                    trajectory[index].label = "compaction · \(hidden) tokens → summary"
                }
            case "compaction/end":
                trajectory.close(compactionEntries[data["compactionId"] as? String ?? ""], at: dshMillis(object["time"]))
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
            "The standing prompt is the rendered system prompt plus rules, skill catalog and runtime snapshot. The tool schema comes from the latest request/header.",
            "Input tokens are inputTokens of the last assistant turn, not byte/4.",
            "DSH does not record SKILL.md paths, so there is no disk size or read count.",
        ]
        if !sawTurn {
            notes.append("The log has no turns.")
        }
        if let version, version != 4 {
            notes.append("Log version \(version) is not read. Only v4.")
        }
        if prunedRanges > 0 {
            notes.append("Compaction hid \(prunedRanges) ranges, \(prunedTokens) tokens estimated by the harness.")
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
