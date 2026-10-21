import Foundation

/// Grok writes the rendered system prompt to `system_prompt.txt`. Skill catalogs
/// and MCP server blurbs are not in that file: they arrive as synthetic
/// `system_reminder` messages at the start of `chat_history.jsonl`. Built-in
/// tool schemas live in `tool_definitions.json`. MCP tool schemas are not inlined.
enum GrokAnalyzer {
    static let digestCap = 512 * 1024
    static let reportCap = 48 * 1024 * 1024

    public static func digest(_ ref: SessionRef) -> SessionDigest {
        analyze(ref, full: false).digest()
    }

    public static func report(_ ref: SessionRef) -> SessionReport {
        analyze(ref, full: true)
    }

    private static func analyze(_ ref: SessionRef, full: Bool) -> SessionReport {
        let root = URL(fileURLWithPath: ref.locator, isDirectory: true)
        var notes: [String] = []
        var truncated = false

        let systemURL = root.appendingPathComponent("system_prompt.txt")
        let systemText = (try? String(contentsOf: systemURL, encoding: .utf8)) ?? ""
        let systemBytes = systemText.isEmpty ? 0 : Files.size(systemURL)
        let sections = PromptText.sections(in: systemText)

        var tools = toolDefinitions(root.appendingPathComponent("tool_definitions.json"))
        let toolDefBytes = tools.reduce(0) { $0 + $1.definitionBytes }
        if tools.isEmpty, Files.size(root.appendingPathComponent("tool_definitions.json")) > 0 {
            notes.append("Could not read tool_definitions.json.")
        }

        var skills: [SkillMeasure] = []
        var mcp: [McpMeasure] = []
        var rulesBytes = 0
        var otherReminderBytes = 0
        var standingSkills = 0
        var standingMcp = 0
        var sawCompaction = false
        var sawQuery = false

        var transcript: [SliceKind: Int] = [:]
        var turns: [TurnMeasure] = []
        var currentTurn: Int?
        var callNames: [String: String] = [:]
        var heavy: [(String, Int)] = []
        var turnUser = 0
        var turnReply = 0

        func add(_ kind: SliceKind, _ bytes: Int) {
            guard bytes > 0 else { return }
            transcript[kind, default: 0] += bytes
        }

        func closeTurn() {
            guard let index = currentTurn, index < turns.count else { return }
            turns[index] = TurnMeasure(
                index: index + 1,
                preview: turns[index].preview,
                userBytes: turnUser,
                replyBytes: turnReply
            )
        }

        let chatURL = root.appendingPathComponent("chat_history.jsonl")
        let cap = full ? reportCap : digestCap
        truncated = Files.forEachLine(url: chatURL, maxBytes: cap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            let type = object["type"] as? String ?? ""
            let reason = object["synthetic_reason"] as? String
            let text = messageText(object["content"])
            let textBytes = text.utf8.count

            if type == "compaction_meta" || reason == "compaction_meta" {
                sawCompaction = true
            }

            if type == "system" {
                add(.system, textBytes)
                return !full && sawQuery ? false : true
            }
            if type == "reasoning" {
                let stored = encryptedBytes(object)
                add(.reasoning, stored > 0 ? stored : textBytes)
                if currentTurn != nil {
                    turnReply += stored > 0 ? stored : textBytes
                }
                return true
            }
            if type == "assistant" {
                add(.assistant, textBytes)
                turnReply += textBytes
                if let calls = object["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let id = call["id"] as? String ?? ""
                        let name = call["name"] as? String ?? "tool"
                        if !id.isEmpty { callNames[id] = name }
                        let arguments = call["arguments"] as? String ?? ""
                        noteTool(&tools, name: name, call: true, resultBytes: 0)
                        noteSkillReads(&skills, arguments: arguments)
                    }
                }
                return true
            }
            if type == "tool_result" {
                add(.toolResult, textBytes)
                turnReply += textBytes
                let id = object["tool_call_id"] as? String ?? ""
                let name = callNames[id] ?? "tool"
                noteTool(&tools, name: name, call: false, resultBytes: textBytes)
                considerHeavy(&heavy, tool: name, bytes: textBytes)
                return true
            }

            let isQuery = PromptText.userQuery(in: text) != nil && reason == nil
            if reason == "system_reminder" || (!isQuery && (text.contains("<user_rules") || text.contains("<user_info") || text.contains("skills are available") || text.contains("MCP servers"))) {
                if text.contains("skills are available") {
                    let parsed = attachDisk(PromptText.skills(in: text))
                    preserveReads(from: skills, into: &skills, replacement: parsed)
                    standingSkills = textBytes
                    add(.skills, textBytes)
                } else if text.contains("MCP servers") {
                    mcp = PromptText.mcpServers(in: text)
                    standingMcp = textBytes
                    add(.mcp, textBytes)
                } else if text.contains("<user_rules") || text.contains("<user_info") || text.contains("<rules>") {
                    rulesBytes = textBytes
                    add(.rules, textBytes)
                } else {
                    otherReminderBytes += textBytes
                    add(.other, textBytes)
                }
                return true
            }

            if isQuery {
                closeTurn()
                let query = PromptText.userQuery(in: text) ?? text
                let index = turns.count
                turns.append(TurnMeasure(
                    index: index + 1,
                    preview: PromptText.preview(query),
                    userBytes: textBytes,
                    replyBytes: 0
                ))
                currentTurn = index
                turnUser = textBytes
                turnReply = 0
                add(.user, textBytes)
                sawQuery = true
                return full
            }

            if type == "user" {
                if reason != nil {
                    add(.other, textBytes)
                } else {
                    add(.user, textBytes)
                    turnReply += textBytes
                }
                return true
            }
            add(.other, max(textBytes, line.utf8.count))
            return true
        }

        closeTurn()

        mergeEvents(root.appendingPathComponent("events.jsonl"), into: &mcp)

        if systemText.isEmpty {
            notes.append("The session has no system_prompt.txt.")
        }
        if skills.isEmpty {
            notes.append("No skill catalog found at the start of the chat history.")
        }
        if sawCompaction {
            notes.append("The session was compacted. The transcript on disk is larger than the remaining context.")
        }
        if truncated {
            notes.append(full
                ? "The transcript is longer than \(ByteFormat.bytes(reportCap)); the rest is not counted."
                : "The quick measure reads only the first \(ByteFormat.bytes(digestCap)) of the transcript.")
        }
        notes.append("Tokens are a byte/4 estimate, not the model's tokenizer.")
        notes.append("MCP tool schemas are not part of the prompt. Grok loads them through search_tool. The MCP figure here is the server description block.")

        let standing = compact([
            Slice(kind: .system, bytes: systemBytes > 0 ? systemBytes : (transcript[.system] ?? 0)),
            Slice(kind: .skills, bytes: standingSkills),
            Slice(kind: .mcp, bytes: standingMcp),
            Slice(kind: .rules, bytes: rulesBytes),
            Slice(kind: .toolDefs, bytes: toolDefBytes),
            Slice(kind: .other, bytes: otherReminderBytes),
        ])

        let composition = SliceKind.allCases.compactMap { kind -> Slice? in
            guard let bytes = transcript[kind], bytes > 0 else { return nil }
            return Slice(kind: kind, bytes: bytes)
        }

        let rankedTools = tools
            .filter { $0.definitionBytes > 0 || $0.calls > 0 || $0.resultBytes > 0 }
            .sorted { ($0.resultBytes + $0.definitionBytes, $0.calls) > ($1.resultBytes + $1.definitionBytes, $1.calls) }

        let heavyRanked = heavy.enumerated().map { HeavyResult(rank: $0.offset + 1, tool: $0.element.0, bytes: $0.element.1) }

        return SessionReport(
            ref: ref,
            standing: standing,
            transcript: composition,
            sections: sections,
            skills: skills.sorted { $0.catalogBytes > $1.catalogBytes },
            mcp: mcp.sorted { $0.catalogBytes > $1.catalogBytes },
            tools: rankedTools,
            turns: turns,
            heavy: heavyRanked,
            steering: [],
            contextPercent: nil,
            contextWindow: nil,
            notes: notes,
            truncated: truncated && full
        )
    }
}

private func compact(_ slices: [Slice]) -> [Slice] {
    slices.filter { $0.bytes > 0 }
}

private func messageText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    if let parts = content as? [[String: Any]] {
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    if let parts = content as? [Any] {
        return parts.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let object = item as? [String: Any] { return object["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }
    return ""
}

private func encryptedBytes(_ object: [String: Any]) -> Int {
    if let text = object["encrypted_content"] as? String { return text.utf8.count }
    if let text = object["summary"] as? String { return text.utf8.count }
    return 0
}

private func toolDefinitions(_ url: URL) -> [ToolMeasure] {
    guard Files.size(url) > 0, Files.size(url) < 8_000_000, let data = try? Data(contentsOf: url) else { return [] }
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
    var tools: [ToolMeasure] = []
    for item in list {
        guard let object = item as? [String: Any] else { continue }
        let function = object["function"] as? [String: Any]
        let name = function?["name"] as? String ?? "tool"
        let encoded = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        tools.append(ToolMeasure(name: name, definitionBytes: encoded.count))
    }
    return tools
}

private func noteTool(_ tools: inout [ToolMeasure], name: String, call: Bool, resultBytes: Int) {
    if let index = tools.firstIndex(where: { $0.name == name }) {
        let current = tools[index]
        tools[index] = ToolMeasure(
            name: name,
            definitionBytes: current.definitionBytes,
            calls: current.calls + (call ? 1 : 0),
            resultBytes: current.resultBytes + resultBytes
        )
    } else {
        tools.append(ToolMeasure(name: name, calls: call ? 1 : 0, resultBytes: resultBytes))
    }
}

private func preserveReads(from existing: [SkillMeasure], into skills: inout [SkillMeasure], replacement: [SkillMeasure]) {
    var reads: [String: Int] = [:]
    for skill in existing { reads[skill.name, default: 0] += skill.readCount }
    skills = replacement.map { skill in
        var copy = skill
        copy.readCount = reads[skill.name] ?? 0
        return copy
    }
}

private func noteSkillReads(_ skills: inout [SkillMeasure], arguments: String) {
    let arguments = PromptText.normalizeSlashes(arguments)
    guard !arguments.isEmpty else { return }
    var hit = Set<String>()
    for index in skills.indices {
        let skill = skills[index]
        let pathHit = skill.path.map { arguments.contains($0) } ?? false
        let nameHit = arguments.contains("/skills/\(skill.name)/SKILL.md")
            || arguments.contains("/skills/\(skill.name)\\SKILL.md")
        if pathHit || nameHit {
            skills[index].readCount += 1
            hit.insert(skill.name)
        }
    }
    for path in PromptText.skillPaths(in: arguments) {
        guard let name = PromptText.skillName(from: path), !hit.contains(name) else { continue }
        if let index = skills.firstIndex(where: { $0.name == name }) {
            skills[index].readCount += 1
        } else {
            skills.append(SkillMeasure(
                name: name,
                catalogBytes: 0,
                summary: "Read from a tool, not in the catalog.",
                path: path,
                origin: "project",
                diskBytes: SkillFiles.diskBytes(path),
                readCount: 1
            ))
        }
        hit.insert(name)
    }
}

private func attachDisk(_ skills: [SkillMeasure]) -> [SkillMeasure] {
    skills.map { skill in
        var copy = skill
        copy.diskBytes = SkillFiles.diskBytes(skill.path)
        return copy
    }
}

private func considerHeavy(_ heavy: inout [(String, Int)], tool: String, bytes: Int) {
    guard bytes > 0 else { return }
    if heavy.count < 8 || bytes > heavy[heavy.count - 1].1 {
        heavy.append((tool, bytes))
        heavy.sort { $0.1 > $1.1 }
        if heavy.count > 8 { heavy.removeLast(heavy.count - 8) }
    }
}

private func mergeEvents(_ url: URL, into mcp: inout [McpMeasure]) {
    guard Files.size(url) > 0 else { return }
    var live: [String: (status: String, tools: [String], count: Int?)] = [:]
    _ = Files.forEachLine(url: url, maxBytes: 400_000) { line in
        guard line.contains("mcp_server_"), let object = JSONFile.lineObject(line) else { return true }
        let type = object["type"] as? String ?? ""
        let name = object["server_name"] as? String ?? ""
        guard !name.isEmpty else { return true }
        if type == "mcp_server_connected" {
            let tools = object["tools"] as? [String] ?? []
            let count = object["tool_count"] as? Int ?? tools.count
            live[name] = ("connected", tools, count)
        } else if type == "mcp_server_failed" {
            let error = object["error_type"] as? String ?? "failed"
            let status = error == "auth_required" ? "auth" : "failed"
            live[name] = (status, [], live[name]?.count)
        }
        return true
    }
    for (name, info) in live {
        if let index = mcp.firstIndex(where: { $0.name == name }) {
            let current = mcp[index]
            mcp[index] = McpMeasure(
                name: name,
                catalogBytes: current.catalogBytes,
                toolCount: info.count ?? current.toolCount,
                status: info.status,
                tools: info.tools,
                blurb: current.blurb
            )
        } else {
            mcp.append(McpMeasure(
                name: name,
                catalogBytes: 0,
                toolCount: info.count,
                status: info.status,
                tools: info.tools,
                blurb: ""
            ))
        }
    }
}
