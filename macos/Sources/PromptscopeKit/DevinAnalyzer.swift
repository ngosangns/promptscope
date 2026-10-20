import Foundation

/// Devin CLI writes an ATIF JSON transcript. System steps are the standing prompt:
/// identity, MCP catalog, skill catalog, rules, and tool schemas on the agent record.
enum DevinAnalyzer {
    static func report(_ ref: SessionRef) -> SessionReport {
        let url = URL(fileURLWithPath: ref.locator)
        guard let object = JSONFile.object(url: url, maxBytes: 12 * 1024 * 1024) else {
            return empty(ref, note: "Không đọc được transcript Devin, hoặc file lớn hơn 12 MB.")
        }
        return analyze(ref, object: object, truncated: Files.size(url) > 12 * 1024 * 1024)
    }

    private static func analyze(_ ref: SessionRef, object: [String: Any], truncated: Bool) -> SessionReport {
        var standing: [SliceKind: Int] = [:]
        var transcript: [SliceKind: Int] = [:]
        var sections: [SectionMeasure] = []
        var skills: [SkillMeasure] = []
        var mcp: [McpMeasure] = []
        var tools: [String: ToolMeasure] = [:]
        var heavy: [(String, Int)] = []
        var turns: [TurnMeasure] = []
        var trajectory: [TrajectoryEntry] = []
        var rulesBytes = 0
        var summaryBytes = 0
        var promptTokens: Int?

        if let agent = object["agent"] as? [String: Any],
           let definitions = agent["tool_definitions"] as? [Any] {
            for item in definitions {
                guard let tool = item as? [String: Any] else { continue }
                let function = tool["function"] as? [String: Any]
                let name = function?["name"] as? String ?? "tool"
                let size = (try? JSONSerialization.data(withJSONObject: tool))?.count ?? 0
                standing[.toolDefs, default: 0] += size
                var row = tools[name] ?? ToolMeasure(name: name)
                row.definitionBytes = size
                tools[name] = row
            }
        }

        let steps = object["steps"] as? [[String: Any]] ?? []
        var turnIndex = 0
        var userBytes = 0
        var replyBytes = 0
        var inTurn = false
        func closeTurn(preview: String) {
            guard inTurn else { return }
            turns.append(TurnMeasure(index: turnIndex, preview: preview, userBytes: userBytes, replyBytes: replyBytes))
            inTurn = false
        }
        var openPreview = ""

        for step in steps {
            let source = step["source"] as? String ?? ""
            let message = step["message"] as? String ?? ""
            switch source {
            case "system":
                let kind = classify(message, step)
                switch kind {
                case .skills:
                    standing[.skills] = message.utf8.count
                    skills = parseSkills(message)
                case .mcp:
                    standing[.mcp] = message.utf8.count
                    mcp = parseMcp(message)
                case .rules:
                    rulesBytes = message.utf8.count
                case .summary:
                    summaryBytes = message.utf8.count
                case .system:
                    standing[.system, default: 0] += message.utf8.count
                }
                let name = sectionName(message, kind)
                sections.append(SectionMeasure(name: name, bytes: message.utf8.count, preview: PromptText.preview(message, limit: 120)))
            case "user":
                if inTurn { closeTurn(preview: openPreview) }
                turnIndex += 1
                openPreview = PromptText.preview(message, limit: 140)
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: devinMillis(step["timestamp"]), turn: turnIndex,
                    kind: "user", label: openPreview, bytes: message.utf8.count
                ))
                userBytes = message.utf8.count
                replyBytes = 0
                inTurn = true
                transcript[.user, default: 0] += message.utf8.count
            case "agent":
                transcript[.assistant, default: 0] += message.utf8.count
                let reasoning = step["reasoning_content"] as? String ?? ""
                transcript[.reasoning, default: 0] += reasoning.utf8.count
                replyBytes += message.utf8.count + reasoning.utf8.count
                if !message.isEmpty {
                    trajectory.append(TrajectoryEntry(
                        index: trajectory.count, at: devinMillis(step["timestamp"]), turn: max(turnIndex, 1),
                        kind: "assistant", label: PromptText.preview(message, limit: 80), bytes: message.utf8.count
                    ))
                }
                if let metrics = step["metrics"] as? [String: Any], let tokens = jsonInt(metrics["prompt_tokens"]) {
                    promptTokens = tokens
                }
                let calls = step["tool_calls"] as? [[String: Any]] ?? []
                var results: [String: Int] = [:]
                if let observation = step["observation"] as? [String: Any],
                   let rows = observation["results"] as? [[String: Any]] {
                    for row in rows {
                        let id = row["source_call_id"] as? String ?? ""
                        let content = row["content"] as? String ?? ""
                        results[id] = content.utf8.count
                    }
                }
                for call in calls {
                    let name = call["function_name"] as? String ?? "tool"
                    let id = call["tool_call_id"] as? String ?? ""
                    let result = results[id] ?? 0
                    var row = tools[name] ?? ToolMeasure(name: name)
                    row.calls += 1
                    row.resultBytes += result
                    tools[name] = row
                    transcript[.toolResult, default: 0] += result
                    replyBytes += result
                    if result > 0 { heavy.append((name, result)) }
                    trajectory.append(TrajectoryEntry(
                        index: trajectory.count, at: devinMillis(step["timestamp"]), turn: max(turnIndex, 1),
                        kind: "tool", label: name, bytes: result
                    ))
                    noteSkill(call, name: name, skills: &skills)
                }
            default:
                transcript[.other, default: 0] += message.utf8.count
            }
        }
        if inTurn { closeTurn(preview: openPreview) }
        if rulesBytes > 0 { standing[.rules] = rulesBytes }
        if summaryBytes > 0 { standing[.other, default: 0] += summaryBytes }

        var notes = [
            "Prompt đứng là các system step (identity, skill, MCP, luật) cộng schema tool. Tóm tắt phiên trước nằm ở mục Khác.",
            "Token đầu vào là prompt_tokens của lượt agent cuối, không phải byte/4.",
        ]
        if truncated { notes.append("File lớn hơn 12 MB, chưa đọc hết.") }
        let ranked = heavy.sorted { $0.1 > $1.1 }.prefix(8).enumerated().map { index, item in
            HeavyResult(rank: index + 1, tool: item.0, bytes: item.1)
        }
        return SessionReport(
            ref: ref,
            standing: pack(standing),
            transcript: pack(transcript),
            sections: sections,
            skills: skills,
            mcp: mcp,
            tools: tools.values.sorted { $0.calls > $1.calls },
            turns: turns,
            trajectory: trajectory,
            heavy: ranked,
            steering: [],
            contextPercent: nil,
            contextWindow: nil,
            promptTokens: promptTokens,
            notes: notes,
            truncated: truncated
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

private enum DevinKind { case system, skills, mcp, rules, summary }

private func classify(_ message: String, _ step: [String: Any]) -> DevinKind {
    let telemetry = (step["extra"] as? [String: Any])?["telemetry"] as? [String: Any]
    let operation = telemetry?["operation"] as? String ?? ""
    if message.contains("<available_skills>") { return .skills }
    if message.contains("Available MCP Servers") { return .mcp }
    if operation == "content" || message.contains("<rules") { return .rules }
    if message.hasPrefix("You are continuing work") { return .summary }
    return .system
}

private func sectionName(_ message: String, _ kind: DevinKind) -> String {
    switch kind {
    case .skills: return "available_skills"
    case .mcp: return "mcp"
    case .rules: return "rules"
    case .summary: return "tóm tắt phiên trước"
    case .system:
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? "system"
        return PromptText.preview(line, limit: 48)
    }
}

private func parseSkills(_ text: String) -> [SkillMeasure] {
    let pattern = #"(?m)^[ \t]*- \*\*([^*]+)\*\*:\s*"#
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
            origin: "không rõ"
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

private func parseMcp(_ text: String) -> [McpMeasure] {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return [] }
    let slice = String(text[open...close])
    guard let data = slice.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let servers = object["servers"] as? [[String: Any]] else { return [] }
    return servers.compactMap { server in
        guard let name = server["name"] as? String, !name.isEmpty else { return nil }
        let blurb = server["description"] as? String ?? ""
        return McpMeasure(
            name: name,
            catalogBytes: max(blurb.utf8.count, name.utf8.count),
            toolCount: nil,
            status: "listed",
            tools: [],
            blurb: PromptText.preview(blurb, limit: 180)
        )
    }
}

private func noteSkill(_ call: [String: Any], name: String, skills: inout [SkillMeasure]) {
    let arguments = call["arguments"] as? [String: Any] ?? [:]
    if name == "skill" {
        let skill = (arguments["name"] as? String) ?? (arguments["skill"] as? String) ?? ""
        if !skill.isEmpty { bump(&skills, skill, path: nil) }
    }
    let text: String
    if JSONSerialization.isValidJSONObject(arguments), let data = try? JSONSerialization.data(withJSONObject: arguments) {
        text = String(decoding: data, as: UTF8.self)
    } else {
        text = ""
    }
    for path in PromptText.skillPaths(in: text) {
        if let skill = PromptText.skillName(from: path) { bump(&skills, skill, path: path) }
    }
}

private func bump(_ skills: inout [SkillMeasure], _ name: String, path: String?) {
    if let index = skills.firstIndex(where: { $0.name == name }) {
        skills[index].readCount += 1
        if skills[index].path == nil { skills[index].path = path }
        return
    }
    skills.append(SkillMeasure(
        name: name, catalogBytes: 0, summary: "", path: path, origin: skillOrigin(path), readCount: 1
    ))
}

private func pack(_ map: [SliceKind: Int]) -> [Slice] {
    SliceKind.allCases.compactMap { kind in
        guard let bytes = map[kind], bytes > 0 else { return nil }
        return Slice(kind: kind, bytes: bytes)
    }
}

private func devinMillis(_ value: Any?) -> Int? {
    guard let text = value as? String, let date = Dates.parse(text) else { return nil }
    return Int(date.timeIntervalSince1970 * 1000)
}

private func jsonInt(_ value: Any?) -> Int? {
    if let number = value as? Int { return number }
    if let number = value as? Double { return Int(number) }
    if let number = value as? NSNumber { return number.intValue }
    return nil
}
