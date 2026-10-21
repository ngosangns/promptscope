import Foundation

/// Pi and OMP share one JSONL session log. Pi stores the standing prompt in a
/// system message `sections` object. OMP stores only a digest hash plus usage.
enum PiFamilyAnalyzer {
    static func report(_ ref: SessionRef) -> SessionReport {
        analyze(ref, full: true)
    }

    static func digest(_ ref: SessionRef) -> SessionDigest {
        analyze(ref, full: false).digest()
    }

    private static func analyze(_ ref: SessionRef, full: Bool) -> SessionReport {
        let url = URL(fileURLWithPath: ref.locator)
        var acc = Accumulator(source: ref.source)
        let cap = full ? 32 * 1024 * 1024 : 768 * 1024
        acc.truncated = Files.forEachLine(url: url, maxBytes: cap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            acc.consume(object)
            return true
        }
        if !full {
            acc.applyUsageTail(Files.tail(url: url, maxBytes: 256 * 1024))
        }
        acc.finish()
        let report = acc.report(ref)
        return report
    }
}

private struct Accumulator {
    var source: AgentSource
    var standing: [SliceKind: Int] = [:]
    var transcript: [SliceKind: Int] = [:]
    var sections: [SectionMeasure] = []
    var skills: [SkillMeasure] = []
    var mcp: [McpMeasure] = []
    var tools: [String: ToolMeasure] = [:]
    var steering: [NamedBytes] = []
    var turns: [TurnMeasure] = []
    var trajectory: [TrajectoryEntry] = []
    var heavy: [(tool: String, bytes: Int)] = []
    var contextPercent: Double?
    var contextWindow: Int?
    var promptTokens: Int?
    var nonMessageTokens: Int?
    var sawSections = false
    var truncated = false
    private var callEntries: [String: Int] = [:]
    private var toolStarts: [String: Int] = [:]
    private var turnIndex = 0
    private var turnPreview = ""
    private var userBytes = 0
    private var replyBytes = 0
    private var inTurn = false

    // Older Swift marks the memberwise init private when any property is private,
    // so PiFamilyAnalyzer in this file cannot call it. Keep an explicit init.
    init(source: AgentSource) {
        self.source = source
    }

    mutating func consume(_ object: [String: Any]) {
        guard object["type"] as? String == "message" else {
            consumeEvent(object)
            return
        }
        guard let message = object["message"] as? [String: Any] else { return }
        let role = message["role"] as? String ?? ""
        if role == "system", message["sections"] is [String: Any] {
            applySections(message)
            return
        }
        switch role {
        case "user":
            closeTurn()
            let text = contentText(message["content"])
            turnIndex += 1
            turnPreview = PromptText.preview(text, limit: 140)
            trajectory.add(
                at: Clock.millis(message["timestamp"]) ?? Clock.millis(object["timestamp"]), turn: turnIndex,
                kind: "user", label: turnPreview, bytes: text.utf8.count
            )
            userBytes = text.utf8.count
            replyBytes = 0
            inTurn = true
            add(.user, text.utf8.count, standing: false)
        case "assistant":
            consumeAssistant(message, object)
        case "toolResult":
            let text = contentText(message["content"])
            let name = message["toolName"] as? String ?? "tool"
            add(.toolResult, text.utf8.count, standing: false)
            noteTool(name, call: false, result: text.utf8.count)
            heavy.append((name, text.utf8.count))
            let at = Clock.millis(message["timestamp"]) ?? Clock.millis(object["timestamp"])
            let failed = message["isError"] as? Bool ?? false
            let id = message["toolCallId"] as? String ?? ""
            if let index = callEntries[id] {
                trajectory.close(index, at: at, bytes: text.utf8.count, failed: failed)
                callEntries[id] = nil
            } else {
                trajectory.add(
                    at: at, turn: turnIndex, kind: "tool", label: name, bytes: text.utf8.count, failed: failed
                )
            }
            replyBytes += text.utf8.count
        default:
            let text = contentText(message["content"])
            add(.other, text.utf8.count, standing: false)
            replyBytes += text.utf8.count
        }
    }

    mutating func applyUsageTail(_ tail: String) {
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1 { lines.removeFirst() }
        for line in lines {
            guard let object = JSONFile.lineObject(line),
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { continue }
            noteUsage(message)
        }
    }

    mutating func finish() {
        closeTurn()
        if source == .omp && !sawSections {
            // The note is attached in report().
        }
    }

    func report(_ ref: SessionRef) -> SessionReport {
        var notes = [
            "Tokens marked ~ are byte/4. Input tokens, when present, come from the usage of the last assistant message (input + cache read).",
        ]
        if source == .omp && !sawSections {
            notes.append("OMP does not store the system prompt text, only system-prompt-digest. The skill catalog and MCP are not in this file.")
        }
        if let nonMessageTokens {
            notes.append("Non-message tokens at the last turn: \(nonMessageTokens).")
        }
        if truncated {
            notes.append("The file is longer than the part that was read. Open the session to read more.")
        }
        let heavyRanked = heavy.sorted { $0.bytes > $1.bytes }.prefix(8).enumerated().map { index, item in
            HeavyResult(rank: index + 1, tool: item.tool, bytes: item.bytes)
        }
        return SessionReport(
            ref: ref,
            standing: slices(standing),
            transcript: slices(transcript),
            sections: sections,
            skills: skills.sorted { $0.catalogBytes > $1.catalogBytes },
            mcp: mcp,
            tools: tools.values.sorted { $0.calls > $1.calls },
            turns: turns,
            trajectory: trajectory,
            heavy: heavyRanked,
            steering: steering,
            contextPercent: contextPercent,
            contextWindow: contextWindow,
            promptTokens: promptTokens,
            notes: notes,
            truncated: truncated
        )
    }

    private mutating func applySections(_ message: [String: Any]) {
        guard let sections = message["sections"] as? [String: Any] else { return }
        sawSections = true
        var next: [SliceKind: Int] = [:]
        var listed: [SectionMeasure] = []
        func take(_ key: String, _ kind: SliceKind) {
            guard let text = sections[key] as? String, !text.isEmpty else { return }
            let bytes = text.utf8.count
            next[kind, default: 0] += bytes
            listed.append(SectionMeasure(name: key, bytes: bytes, preview: PromptText.preview(text, limit: 120)))
            if key == "skills" { replaceSkills(parsePiSkills(text)) }
            if key == "mcp_servers" { mcp = parsePiMcp(text) }
            if key == "project_context" { steering = projectFiles(text) }
        }
        take("preamble", .system)
        take("tools", .toolDefs)
        take("rules", .rules)
        take("docs", .other)
        take("project_context", .steering)
        take("skills", .skills)
        take("cwd", .other)
        take("mcp_servers", .mcp)
        if let added = message["toolsAdded"] as? [Any], JSONSerialization.isValidJSONObject(added),
           let data = try? JSONSerialization.data(withJSONObject: added) {
            next[.toolDefs, default: 0] += data.count
            for item in added {
                guard let tool = item as? [String: Any], let name = tool["name"] as? String else { continue }
                let size = (try? JSONSerialization.data(withJSONObject: tool))?.count ?? 0
                var row = tools[name] ?? ToolMeasure(name: name)
                row.definitionBytes = size
                tools[name] = row
            }
        }
        standing = next
        self.sections = listed
    }

    private mutating func consumeAssistant(_ message: [String: Any], _ object: [String: Any]) {
        let parts = message["content"] as? [Any] ?? []
        // Pi stamps the message with the request start and the entry with the end.
        // OMP records the span itself: `duration`, `ttft`, `completedAt`.
        let started = Clock.millis(message["timestamp"])
        let finished = Clock.millis(message["completedAt"]) ?? Clock.millis(object["timestamp"])
        let span = jsonDouble(message["duration"]).map { Int($0) }
            ?? { if let started, let finished, finished >= started { return finished - started } else { return nil } }()
        let usage = message["usage"] as? [String: Any]
        let prompt = usage.map { (jsonInt($0["input"]) ?? 0) + (jsonInt($0["cacheRead"]) ?? 0) }.flatMap { $0 > 0 ? $0 : nil }
        var first = true
        func lead() -> Int? { defer { first = false }; return first ? span : nil }
        for part in parts {
            guard let item = part as? [String: Any] else { continue }
            switch item["type"] as? String {
            case "text":
                let text = item["text"] as? String ?? ""
                add(.assistant, text.utf8.count, standing: false)
                replyBytes += text.utf8.count
                if !text.isEmpty {
                    trajectory.add(
                        at: started ?? finished, turn: turnIndex, kind: "assistant",
                        label: PromptText.preview(text, limit: 80), bytes: text.utf8.count, durationMs: lead(), tokens: prompt
                    )
                }
            case "thinking":
                let text = item["thinking"] as? String ?? item["text"] as? String ?? ""
                add(.reasoning, text.utf8.count, standing: false)
                replyBytes += text.utf8.count
                if !text.isEmpty {
                    trajectory.add(
                        at: started ?? finished, turn: turnIndex, kind: "reasoning", label: "reasoning",
                        bytes: text.utf8.count, durationMs: lead(), tokens: prompt
                    )
                }
            case "toolCall":
                let name = item["name"] as? String ?? "tool"
                let args = argumentText(item["arguments"])
                noteTool(name, call: true, result: 0)
                noteSkillUse(name: name, arguments: item["arguments"], text: args)
                let id = item["id"] as? String ?? ""
                let index = trajectory.add(
                    at: toolStarts[id] ?? finished ?? started, turn: turnIndex,
                    kind: TrailLabel.isSubagent(name) ? "subagent" : "tool",
                    label: TrailLabel.tool(name, item["arguments"], intent: item["intent"] as? String),
                    bytes: args.utf8.count, tokens: prompt
                )
                if !id.isEmpty { callEntries[id] = index }
            default:
                break
            }
        }
        noteUsage(message)
        let stop = message["stopReason"] as? String ?? ""
        if stop == "error" || stop == "aborted" || stop == "length" {
            let reason = message["errorMessage"] as? String ?? stop
            trajectory.add(
                at: finished ?? started, turn: max(turnIndex, 1), kind: "error",
                label: stop == "error" ? "request failed · " + PromptText.preview(reason, limit: 70) : "reply \(stop)",
                durationMs: first ? span : nil, failed: true
            )
        }
    }

    /// Entries that are not chat messages: compactions, model and mode changes,
    /// the injected reminders, background-job notices, and how the session ended.
    private mutating func consumeEvent(_ object: [String: Any]) {
        let type = object["type"] as? String ?? ""
        let at = Clock.millis(object["timestamp"])
        let turn = max(turnIndex, 1)
        switch type {
        case "compaction":
            let before = jsonInt(object["tokensBefore"])
            let after = jsonInt(object["tokensAfter"])
            let method = object["method"] as? String ?? "compaction"
            let range = (before != nil && after != nil) ? " \(before!) → \(after!) tokens" : ""
            trajectory.add(
                at: at, turn: turn, kind: "compaction", label: "\(method)\(range)",
                bytes: (object["summary"] as? String ?? "").utf8.count, tokens: before
            )
        case "model_change":
            let model = object["model"] as? String
                ?? [object["provider"] as? String, object["modelId"] as? String].compactMap { $0 }.joined(separator: "/")
            if !model.isEmpty { trajectory.add(at: at, turn: turn, kind: "notice", label: "model → \(model)") }
        case "mode_change":
            if let mode = object["mode"] as? String { trajectory.add(at: at, turn: turn, kind: "notice", label: "mode → \(mode)") }
        case "ttsr_injection":
            let rules = (object["injectedRules"] as? [String] ?? []).joined(separator: ", ")
            trajectory.add(at: at, turn: turn, kind: "notice", label: "rules injected · \(PromptText.preview(rules, limit: 60))")
        case "custom":
            let data = object["data"] as? [String: Any]
            switch object["customType"] as? String {
            case "tool_execution_start":
                if let id = data?["toolCallId"] as? String, let started = Clock.millis(data?["startedAt"]) {
                    toolStarts[id] = started
                }
            case "session_exit":
                let reason = data?["reason"] as? String ?? "exit"
                trajectory.add(
                    at: Clock.millis(data?["recordedAt"]) ?? at, turn: turn, kind: "error",
                    label: "session ended · \(reason)", failed: data?["kind"] as? String == "signal"
                )
            case "goal-completed":
                let used = jsonInt(data?["tokensUsed"]).map { " · \($0) tokens" } ?? ""
                trajectory.add(
                    at: at, turn: turn, kind: "notice", label: "goal completed\(used)",
                    durationMs: jsonInt(data?["timeUsedSeconds"]).map { $0 * 1000 }
                )
            default:
                break
            }
        case "custom_message":
            let kind = object["customType"] as? String ?? "message"
            let details = object["details"] as? [String: Any]
            let ignored: Set<String> = ["image-attachment", "goal-mode-context", "firstmate-sessionstart-nudge"]
            guard !ignored.contains(kind) else { break }
            let size = (object["content"] as? String ?? "").utf8.count
            var label = kind
            var duration: Int?
            var failed = false
            switch kind {
            case "skill-prompt":
                label = "skill invoked · " + (details?["name"] as? String ?? "?")
            case "async-result":
                let job = (details?["jobs"] as? [[String: Any]])?.first
                label = "background job done · " + PromptText.preview(job?["label"] as? String ?? "", limit: 50)
                duration = jsonInt(job?["durationMs"])
            case "irc:incoming":
                label = "message from agent " + (details?["from"] as? String ?? "?")
            case "thinking-loop-redirect", "tool-call-loop-redirect", "todo-error-reminder", "interrupted-thinking":
                label = "guard · \(kind)"
                failed = true
            default:
                break
            }
            trajectory.add(at: at, turn: turn, kind: "notice", label: label, bytes: size, durationMs: duration, failed: failed)
        default:
            break
        }
    }

    private mutating func noteUsage(_ message: [String: Any]) {
        guard let usage = message["usage"] as? [String: Any] else { return }
        let input = jsonInt(usage["input"]) ?? 0
        let cache = jsonInt(usage["cacheRead"]) ?? 0
        let total = input + cache
        if total > 0 { promptTokens = total }
        if let percent = jsonDouble(usage["contextPercent"]), percent > 0 {
            contextPercent = percent
            if total > 0 {
                let raw = Double(total) / (percent / 100)
                let nearest = (raw / 1000).rounded() * 1000
                contextWindow = abs(nearest - raw) / raw < 0.02 ? Int(nearest) : Int(raw.rounded())
            }
        }
        if let snap = message["contextSnapshot"] as? [String: Any] {
            nonMessageTokens = jsonInt(snap["nonMessageTokens"]) ?? nonMessageTokens
        }
    }

    private mutating func noteSkillUse(name: String, arguments: Any?, text: String) {
        if name == "skill", let object = arguments as? [String: Any] {
            let skill = (object["name"] as? String) ?? (object["skill"] as? String)
            if let skill, !skill.isEmpty { noteRead(skill) }
        }
        for path in PromptText.skillPaths(in: text) {
            if let skill = PromptText.skillName(from: path) { noteRead(skill, path: path) }
        }
    }

    private mutating func noteRead(_ name: String, path: String? = nil) {
        if let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].readCount += 1
            if skills[index].path == nil { skills[index].path = path }
            if skills[index].diskBytes == nil { skills[index].diskBytes = SkillFiles.diskBytes(path ?? skills[index].path) }
            return
        }
        skills.append(SkillMeasure(
            name: name,
            catalogBytes: 0,
            summary: "",
            path: path,
            origin: skillOrigin(path),
            diskBytes: SkillFiles.diskBytes(path),
            readCount: 1
        ))
    }

    private mutating func replaceSkills(_ catalog: [SkillMeasure]) {
        var reads: [String: Int] = [:]
        for skill in skills { reads[skill.name, default: 0] += skill.readCount }
        var merged = catalog
        for index in merged.indices {
            merged[index].readCount = reads[merged[index].name] ?? 0
            reads[merged[index].name] = nil
        }
        for (name, count) in reads where count > 0 {
            merged.append(SkillMeasure(
                name: name, catalogBytes: 0, summary: "", path: nil, origin: "unknown", readCount: count
            ))
        }
        skills = merged
    }

    private mutating func noteTool(_ name: String, call: Bool, result: Int) {
        var row = tools[name] ?? ToolMeasure(name: name)
        if call { row.calls += 1 }
        row.resultBytes += result
        tools[name] = row
    }

    private mutating func closeTurn() {
        guard inTurn else { return }
        turns.append(TurnMeasure(index: turnIndex, preview: turnPreview, userBytes: userBytes, replyBytes: replyBytes))
        inTurn = false
    }

    private mutating func add(_ kind: SliceKind, _ bytes: Int, standing isStanding: Bool) {
        guard bytes > 0 else { return }
        if isStanding { standing[kind, default: 0] += bytes }
        else { transcript[kind, default: 0] += bytes }
    }

    private func slices(_ map: [SliceKind: Int]) -> [Slice] {
        SliceKind.allCases.compactMap { kind in
            guard let bytes = map[kind], bytes > 0 else { return nil }
            return Slice(kind: kind, bytes: bytes)
        }
    }
}

private func parsePiSkills(_ text: String) -> [SkillMeasure] {
    var skills: [SkillMeasure] = []
    for block in text.components(separatedBy: "<skill>").dropFirst() {
        let body = block.components(separatedBy: "</skill>").first ?? block
        guard let name = xmlValue("name", body), !name.isEmpty else { continue }
        let path = xmlValue("location", body)
        let summary = xmlValue("description", body) ?? ""
        skills.append(SkillMeasure(
            name: name,
            catalogBytes: body.utf8.count,
            summary: PromptText.preview(summary, limit: 180),
            path: path,
            origin: skillOrigin(path),
            diskBytes: SkillFiles.diskBytes(path)
        ))
    }
    return skills
}

private func parsePiMcp(_ text: String) -> [McpMeasure] {
    var servers: [McpMeasure] = []
    var bucket: [String] = []
    func flush() {
        guard let first = bucket.first else { return }
        let block = bucket.joined(separator: "\n")
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { bucket.removeAll(); return }
        var rest = trimmed.dropFirst(2)
        if rest.hasPrefix("mcp__") { rest = rest.dropFirst(5) }
        let status: String
        let name: String
        if let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            name = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            status = String(rest[rest.index(after: open)..<close])
        } else {
            name = String(rest.prefix { $0 != ":" && $0 != " " })
            status = "listed"
        }
        let blurb = block.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")
        if !name.isEmpty {
            servers.append(McpMeasure(
                name: name,
                catalogBytes: block.utf8.count,
                toolCount: nil,
                status: status,
                tools: [],
                blurb: PromptText.preview(blurb, limit: 180)
            ))
        }
        bucket.removeAll()
    }
    for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(lineSub)
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
            flush()
            bucket = [line]
        } else if !bucket.isEmpty {
            bucket.append(line)
        }
    }
    flush()
    return servers
}

private func projectFiles(_ text: String) -> [NamedBytes] {
    let marker = "<project_instructions"
    let parts = text.components(separatedBy: marker).dropFirst()
    return parts.compactMap { part in
        guard let path = xmlAttribute("path", "<project_instructions" + part) else { return nil }
        let body = part.components(separatedBy: "</project_instructions>").first ?? part
        return NamedBytes(name: path, bytes: body.utf8.count, detail: "project_instructions")
    }
}

private func xmlValue(_ tag: String, _ text: String) -> String? {
    guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>"), open.upperBound <= close.lowerBound else {
        return nil
    }
    return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func xmlAttribute(_ name: String, _ text: String) -> String? {
    guard let range = text.range(of: "\(name)=\"") else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
}

private func contentText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [Any] else { return "" }
    return parts.compactMap { part -> String? in
        guard let item = part as? [String: Any] else { return nil }
        return item["text"] as? String
    }.joined(separator: "\n")
}

private func argumentText(_ arguments: Any?) -> String {
    if let text = arguments as? String { return PromptText.normalizeSlashes(text) }
    guard let arguments, JSONSerialization.isValidJSONObject(arguments),
          let data = try? JSONSerialization.data(withJSONObject: arguments) else { return "" }
    return PromptText.normalizeSlashes(String(decoding: data, as: UTF8.self))
}


private func jsonInt(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}

private func jsonDouble(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let number = value as? NSNumber { return number.doubleValue }
    return nil
}
