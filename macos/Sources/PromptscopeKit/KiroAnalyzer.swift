import Foundation

enum KiroIDEAnalyzer {
    public static func report(_ ref: SessionRef) -> SessionReport {
        let root = URL(fileURLWithPath: ref.locator, isDirectory: true)
        var notes = [
            "Kiro không ghi system prompt đầy đủ vào session. Prompt đứng ở đây là các file steering được nhét vào context.",
            "Catalog skill không nằm trong log. Bảng skill là các SKILL.md agent đã đọc.",
        ]
        var transcript: [SliceKind: Int] = [:]
        var tools: [String: ToolMeasure] = [:]
        var callNames: [String: String] = [:]
        var skills: [String: SkillMeasure] = [:]
        var steering: [NamedBytes] = []
        var turns: [TurnMeasure] = []
        var trajectory: [TrajectoryEntry] = []
        var heavy: [(String, Int)] = []
        var contextPercent: Double?
        var credits = 0.0
        var turnUser = 0
        var turnReply = 0
        var sawTurn = false

        func add(_ kind: SliceKind, _ bytes: Int) {
            guard bytes > 0 else { return }
            transcript[kind, default: 0] += bytes
        }

        let messages = root.appendingPathComponent("messages.jsonl")
        let truncated = Files.forEachLine(url: messages, maxBytes: GrokAnalyzer.reportCap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            let payload = object["payload"] as? [String: Any] ?? object
            let type = payload["type"] as? String ?? ""
            switch type {
            case "user":
                let text = payload["content"] as? String ?? ""
                add(.user, text.utf8.count)
                if sawTurn, !turns.isEmpty {
                    let index = turns.count - 1
                    turns[index] = TurnMeasure(index: index + 1, preview: turns[index].preview, userBytes: turnUser, replyBytes: turnReply)
                }
                turns.append(TurnMeasure(index: turns.count + 1, preview: PromptText.preview(text), userBytes: text.utf8.count, replyBytes: 0))
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: kiroMillis(object["timestamp"]), turn: turns.count,
                    kind: "user", label: PromptText.preview(text), bytes: text.utf8.count
                ))
                turnUser = text.utf8.count
                turnReply = 0
                sawTurn = true
            case "assistant":
                let text = payload["content"] as? String ?? ""
                add(.assistant, text.utf8.count)
                turnReply += text.utf8.count
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: kiroMillis(object["timestamp"]), turn: max(turns.count, 1),
                    kind: "assistant", label: PromptText.preview(text, limit: 80), bytes: text.utf8.count
                ))
            case "tool_call":
                let name = payload["toolName"] as? String ?? "tool"
                let id = payload["toolCallId"] as? String ?? ""
                if !id.isEmpty { callNames[id] = name }
                let args = jsonText(payload["args"])
                add(.other, args.utf8.count)
                bumpTool(&tools, name: name, call: true, result: 0)
                absorbSkills(args, into: &skills)
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: kiroMillis(object["timestamp"]), turn: max(turns.count, 1),
                    kind: "tool", label: name, bytes: args.utf8.count
                ))
            case "tool_result":
                let text = payload["content"] as? String ?? jsonText(payload["content"])
                let bytes = text.utf8.count
                add(.toolResult, bytes)
                turnReply += bytes
                let id = payload["toolCallId"] as? String ?? ""
                let name = callNames[id] ?? "tool"
                bumpTool(&tools, name: name, call: false, result: bytes)
                considerHeavy(&heavy, tool: name, bytes: bytes)
                if let index = trajectory.lastIndex(where: { $0.kind == "tool" && $0.label == name && $0.durationMs == nil }),
                   let start = trajectory[index].at, let end = kiroMillis(object["timestamp"]), end >= start {
                    trajectory[index].durationMs = end - start
                }
            case "steering_inclusion":
                let docs = payload["documents"] as? [String] ?? []
                steering = docs.map { doc in
                    let path = pathOf(doc)
                    return NamedBytes(name: path, bytes: SkillFiles.diskBytes(path) ?? 0, detail: "steering")
                }
            case "session_metadata":
                if payload["key"] as? String == "contextUsage" {
                    let value = payload["value"] as? [String: Any]
                    contextPercent = number(value?["usagePercentage"]) ?? contextPercent
                }
            case "usage_summary":
                let rows = payload["promptTurnSummaries"] as? [[String: Any]] ?? []
                for row in rows { credits += number(row["usage"]) ?? 0 }
            default:
                break
            }
            return true
        }
        if sawTurn, !turns.isEmpty {
            let index = turns.count - 1
            turns[index] = TurnMeasure(index: index + 1, preview: turns[index].preview, userBytes: turnUser, replyBytes: turnReply)
        }
        if truncated {
            notes.append("Transcript dài hơn giới hạn đọc.")
        }
        if credits > 0 {
            notes.append(String(format: "Kiro ghi %.2f credits cho các lượt đã chốt.", credits))
        }
        if let contextPercent {
            notes.append(String(format: "Context usage lần cuối: %.1f%%.", contextPercent))
        }

        let steeringBytes = steering.reduce(0) { $0 + $1.bytes }
        let standing = compact([
            Slice(kind: .steering, bytes: steeringBytes),
        ])
        return SessionReport(
            ref: ref,
            standing: standing,
            transcript: composition(transcript),
            sections: [],
            skills: skills.values.sorted { $0.readCount > $1.readCount },
            mcp: [],
            tools: tools.values.sorted { $0.resultBytes > $1.resultBytes },
            turns: turns,
            trajectory: trajectory,
            heavy: heavy.enumerated().map { HeavyResult(rank: $0.offset + 1, tool: $0.element.0, bytes: $0.element.1) },
            steering: steering,
            contextPercent: contextPercent ?? ref.contextPercent,
            contextWindow: nil,
            notes: notes,
            truncated: truncated
        )
    }
}

enum KiroCLIAnalyzer {
    public static func report(_ ref: SessionRef) -> SessionReport {
        let jsonURL = URL(fileURLWithPath: ref.locator)
        let jsonlURL = jsonURL.deletingPathExtension().appendingPathExtension("jsonl")
        var notes = ["Kiro CLI không lưu system prompt trong transcript. Context % lấy từ sidecar JSON nếu có."]
        var contextPercent = ref.contextPercent
        var contextWindow: Int?
        if let object = JSONFile.object(url: jsonURL) {
            let meta = cliContext(object)
            contextPercent = meta.percent ?? contextPercent
            contextWindow = meta.window
        }
        if let contextPercent, let contextWindow {
            let used = Int((contextPercent / 100) * Double(contextWindow))
            notes.append("Context ghi nhận khoảng \(used) / \(contextWindow) token (\(String(format: "%.1f", contextPercent))%).")
        }

        var transcript: [SliceKind: Int] = [:]
        var tools: [String: ToolMeasure] = [:]
        var callNames: [String: String] = [:]
        var skills: [String: SkillMeasure] = [:]
        var turns: [TurnMeasure] = []
        var trajectory: [TrajectoryEntry] = []
        var heavy: [(String, Int)] = []
        var turnReply = 0

        func add(_ kind: SliceKind, _ bytes: Int) {
            guard bytes > 0 else { return }
            transcript[kind, default: 0] += bytes
        }

        let truncated = Files.forEachLine(url: jsonlURL, maxBytes: GrokAnalyzer.reportCap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            let kind = object["kind"] as? String ?? ""
            let data = object["data"] as? [String: Any] ?? [:]
            switch kind {
            case "Prompt":
                let text = partText(data["content"])
                add(.user, text.utf8.count)
                turns.append(TurnMeasure(index: turns.count + 1, preview: PromptText.preview(text), userBytes: text.utf8.count, replyBytes: 0))
                trajectory.append(TrajectoryEntry(
                    index: trajectory.count, at: nil, turn: turns.count, kind: "user", label: PromptText.preview(text), bytes: text.utf8.count
                ))
                turnReply = 0
            case "AssistantMessage":
                guard let parts = data["content"] as? [[String: Any]] else { break }
                for part in parts {
                    let partKind = part["kind"] as? String ?? ""
                    if partKind == "text", let text = part["data"] as? String {
                        add(.assistant, text.utf8.count)
                        turnReply += text.utf8.count
                    } else if partKind == "thinking" {
                        let bytes = stringBytes(part["data"])
                        add(.reasoning, bytes)
                        turnReply += bytes
                    } else if partKind == "toolUse", let payload = part["data"] as? [String: Any] {
                        let name = payload["name"] as? String ?? "tool"
                        let id = payload["toolUseId"] as? String ?? ""
                        if !id.isEmpty { callNames[id] = name }
                        let args = jsonText(payload["input"])
                        add(.other, args.utf8.count)
                        bumpTool(&tools, name: name, call: true, result: 0)
                        absorbSkills(args, into: &skills)
                        trajectory.append(TrajectoryEntry(
                            index: trajectory.count, at: nil, turn: max(turns.count, 1), kind: "tool", label: name, bytes: args.utf8.count
                        ))
                    }
                }
            case "ToolResults":
                let results = data["results"] as? [String: Any] ?? [:]
                for (id, value) in results {
                    let bytes = stringBytes(value)
                    add(.toolResult, bytes)
                    turnReply += bytes
                    let name = callNames[id] ?? "tool"
                    bumpTool(&tools, name: name, call: false, result: bytes)
                    considerHeavy(&heavy, tool: name, bytes: bytes)
                }
                if !turns.isEmpty {
                    let index = turns.count - 1
                    turns[index] = TurnMeasure(index: index + 1, preview: turns[index].preview, userBytes: turns[index].userBytes, replyBytes: turnReply)
                }
            default:
                add(.other, line.utf8.count)
            }
            return true
        }
        if truncated { notes.append("Transcript dài hơn giới hạn đọc.") }
        notes.append("Token ước lượng byte/4 chỉ dùng khi sidecar không có context window.")

        return SessionReport(
            ref: ref,
            standing: [],
            transcript: composition(transcript),
            sections: [],
            skills: skills.values.sorted { $0.readCount > $1.readCount },
            mcp: [],
            tools: tools.values.sorted { $0.resultBytes > $1.resultBytes },
            turns: turns,
            trajectory: trajectory,
            heavy: heavy.enumerated().map { HeavyResult(rank: $0.offset + 1, tool: $0.element.0, bytes: $0.element.1) },
            steering: [],
            contextPercent: contextPercent,
            contextWindow: contextWindow,
            notes: notes,
            truncated: truncated
        )
    }
}

func cliContext(_ object: [String: Any]) -> (percent: Double?, window: Int?, model: String?, agent: String?) {
    let state = object["session_state"] as? [String: Any]
    let conv = state?["conversation_metadata"] as? [String: Any]
    let usage = conv?["last_context_usage"] as? [String: Any]
    let rts = state?["rts_model_state"] as? [String: Any]
    let info = rts?["model_info"] as? [String: Any]
    let percent = number(usage?["percentage"]) ?? number(rts?["context_usage_percentage"])
    let window = (number(info?["context_window_tokens"])).map { Int($0) }
    let model = info?["model_id"] as? String ?? usage?["model_id"] as? String
    let agent = state?["agent_name"] as? String
    return (percent, window, model, agent)
}

private func composition(_ transcript: [SliceKind: Int]) -> [Slice] {
    SliceKind.allCases.compactMap { kind in
        guard let bytes = transcript[kind], bytes > 0 else { return nil }
        return Slice(kind: kind, bytes: bytes)
    }
}

private func bumpTool(_ tools: inout [String: ToolMeasure], name: String, call: Bool, result: Int) {
    let current = tools[name] ?? ToolMeasure(name: name)
    tools[name] = ToolMeasure(
        name: name,
        definitionBytes: current.definitionBytes,
        calls: current.calls + (call ? 1 : 0),
        resultBytes: current.resultBytes + result
    )
}

private func absorbSkills(_ text: String, into skills: inout [String: SkillMeasure]) {
    let text = PromptText.normalizeSlashes(text)
    for path in PromptText.skillPaths(in: text) {
        guard let name = PromptText.skillName(from: path) else { continue }
        if var skill = skills[name] {
            skill.readCount += 1
            skills[name] = skill
        } else {
            skills[name] = SkillMeasure(
                name: name,
                catalogBytes: 0,
                summary: "Đọc từ tool.",
                path: path,
                origin: "project",
                diskBytes: SkillFiles.diskBytes(path),
                readCount: 1
            )
        }
    }
}

private func pathOf(_ value: String) -> String {
    if let url = URL(string: value), url.isFileURL { return url.path }
    return value.replacingOccurrences(of: "file://", with: "")
}

func partText(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [[String: Any]] else { return jsonText(content) }
    return parts.compactMap { part -> String? in
        if part["kind"] as? String == "text" { return part["data"] as? String }
        return nil
    }.joined(separator: "\n")
}

private func jsonText(_ value: Any?) -> String {
    guard let value else { return "" }
    if let text = value as? String { return text }
    if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
        return String(decoding: data, as: UTF8.self)
    }
    return ""
}

private func stringBytes(_ value: Any?) -> Int {
    switch value {
    case let text as String:
        return text.utf8.count
    case let list as [Any]:
        return list.reduce(0) { $0 + stringBytes($1) }
    case let object as [String: Any]:
        return object.values.reduce(0) { $0 + stringBytes($1) }
    default:
        return 0
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

private func compact(_ slices: [Slice]) -> [Slice] {
    slices.filter { $0.bytes > 0 }
}

private func kiroMillis(_ value: Any?) -> Int? {
    guard let text = value as? String, let date = Dates.parse(text) else { return nil }
    return Int(date.timeIntervalSince1970 * 1000)
}

private func number(_ value: Any?) -> Double? {
    switch value {
    case let number as Double: return number
    case let number as Int: return Double(number)
    case let number as NSNumber: return number.doubleValue
    default: return nil
    }
}
