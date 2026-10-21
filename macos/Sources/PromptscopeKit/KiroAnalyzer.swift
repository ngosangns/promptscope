import Foundation

enum KiroIDEAnalyzer {
    public static func report(_ ref: SessionRef) -> SessionReport {
        let root = URL(fileURLWithPath: ref.locator, isDirectory: true)
        var notes = [
            "Kiro does not record the full system prompt in the session. The standing prompt here is the steering files placed into context.",
            "The skill catalog is not in the log. The skill table lists the SKILL.md files the agent read.",
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
        var callEntries: [String: Int] = [:]
        var approvals: [String: Int] = [:]
        var subagents: [String: Int] = [:]
        var turnEntry: Int?
        var lastEventAt: Int?
        var hookRuns = 0

        func add(_ kind: SliceKind, _ bytes: Int) {
            guard bytes > 0 else { return }
            transcript[kind, default: 0] += bytes
        }

        let messages = root.appendingPathComponent("messages.jsonl")
        let truncated = Files.forEachLine(url: messages, maxBytes: GrokAnalyzer.reportCap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            let payload = object["payload"] as? [String: Any] ?? object
            let type = payload["type"] as? String ?? ""
            let at = kiroMillis(object["timestamp"])
            defer { if !["ContextualHookInvoked", "session_metadata"].contains(type) { lastEventAt = at ?? lastEventAt } }
            switch type {
            case "user":
                let text = payload["content"] as? String ?? ""
                add(.user, text.utf8.count)
                if sawTurn, !turns.isEmpty {
                    let index = turns.count - 1
                    turns[index] = TurnMeasure(index: index + 1, preview: turns[index].preview, userBytes: turnUser, replyBytes: turnReply)
                }
                turns.append(TurnMeasure(index: turns.count + 1, preview: PromptText.preview(text), userBytes: text.utf8.count, replyBytes: 0))
                turnEntry = trajectory.add(
                    at: at, turn: turns.count, kind: "user", label: PromptText.preview(text), bytes: text.utf8.count
                )
                turnUser = text.utf8.count
                turnReply = 0
                sawTurn = true
            case "assistant":
                let text = payload["content"] as? String ?? ""
                add(.assistant, text.utf8.count)
                turnReply += text.utf8.count
                // The log stamps a reply when it lands, so the gap since the last event is the wait for the model.
                let reasoning = payload["operationType"] as? String == "Reasoning"
                trajectory.add(
                    at: at, turn: max(turns.count, 1), kind: reasoning ? "reasoning" : "assistant",
                    label: reasoning ? "reasoning" : PromptText.preview(text, limit: 80), bytes: text.utf8.count,
                    durationMs: lastEventAt.flatMap { start in at.map { $0 - start } }.flatMap { $0 >= 0 ? $0 : nil }
                )
            case "tool_call":
                let name = payload["toolName"] as? String ?? "tool"
                let id = payload["toolCallId"] as? String ?? ""
                if !id.isEmpty { callNames[id] = name }
                let args = jsonText(payload["args"])
                add(.other, args.utf8.count)
                bumpTool(&tools, name: name, call: true, result: 0)
                absorbSkills(args, into: &skills)
                let status = payload["status"] as? String ?? ""
                let index = trajectory.add(
                    at: at, turn: max(turns.count, 1), kind: TrailLabel.isSubagent(name) ? "subagent" : "tool",
                    label: TrailLabel.tool(name, payload["args"], intent: nil), bytes: args.utf8.count,
                    failed: status == "denied" || status == "failed"
                )
                if !id.isEmpty { callEntries[id] = index }
            case "tool_result":
                let text = payload["content"] as? String ?? jsonText(payload["content"])
                let bytes = text.utf8.count
                add(.toolResult, bytes)
                turnReply += bytes
                let id = payload["toolCallId"] as? String ?? ""
                let name = callNames[id] ?? "tool"
                bumpTool(&tools, name: name, call: false, result: bytes)
                considerHeavy(&heavy, tool: name, bytes: bytes)
                trajectory.close(callEntries[id], at: at, bytes: bytes, failed: payload["success"] as? Bool == false)
            case "pending_interaction":
                let id = payload["toolCallId"] as? String ?? ""
                let index = trajectory.add(
                    at: at, turn: max(turns.count, 1), kind: "approval",
                    label: "waiting · " + PromptText.preview(payload["question"] as? String ?? "approval", limit: 60)
                )
                if !id.isEmpty { approvals[id] = index }
            case "interaction_resolved":
                let index = approvals[payload["toolCallId"] as? String ?? ""]
                let chosen = payload["selectedOption"] as? String ?? payload["outcome"] as? String ?? ""
                trajectory.close(index, at: at, failed: chosen == "reject" || chosen == "cancelled" || payload["outcome"] as? String == "cancelled")
                if let index, index < trajectory.count, !chosen.isEmpty { trajectory[index].label += " → \(chosen)" }
            case "sub_agent_start":
                let id = payload["subSessionId"] as? String ?? ""
                let name = payload["subAgentName"] as? String ?? "agent"
                let index = trajectory.add(
                    at: at, turn: max(turns.count, 1), kind: "subagent",
                    label: "\(name) · " + PromptText.preview(payload["explanation"] as? String ?? payload["prompt"] as? String ?? "", limit: 60),
                    bytes: (payload["prompt"] as? String ?? "").utf8.count
                )
                if !id.isEmpty { subagents[id] = index }
            case "sub_agent_complete":
                let index = subagents[payload["subSessionId"] as? String ?? ""]
                trajectory.close(
                    index, at: at, bytes: (payload["response"] as? String ?? "").utf8.count,
                    failed: (payload["status"] as? String ?? "success") != "success"
                )
            case "ContextualHookInvoked":
                hookRuns += 1
            case "turn_end":
                let reason = payload["stopReason"] as? String ?? "end_turn"
                trajectory.close(turnEntry, at: at)
                if reason != "end_turn" {
                    trajectory.add(at: at, turn: max(turns.count, 1), kind: "error", label: "turn \(reason)", failed: true)
                }
            case "steering_inclusion":
                let docs = payload["documents"] as? [String] ?? []
                steering = docs.map { doc in
                    let path = pathOf(doc)
                    return NamedBytes(name: path, bytes: SkillFiles.diskBytes(path) ?? 0, detail: "steering")
                }
                trajectory.add(at: at, turn: max(turns.count, 1), kind: "notice", label: "steering · \(docs.count) files")
            case "session_metadata":
                if payload["key"] as? String == "contextUsage" {
                    let value = payload["value"] as? [String: Any]
                    contextPercent = number(value?["usagePercentage"]) ?? contextPercent
                }
            case "usage_summary":
                let rows = payload["promptTurnSummaries"] as? [[String: Any]] ?? []
                var turnCredits = 0.0
                for row in rows { turnCredits += number(row["usage"]) ?? 0 }
                credits += turnCredits
                let elapsed = number(payload["elapsedTime"]).map { Int($0) }
                let used = Set(rows.flatMap { $0["usedTools"] as? [String] ?? [] }).count
                trajectory.add(
                    at: at, turn: max(turns.count, 1), kind: "notice",
                    label: String(format: "%.2f credits · %d tools · %@", turnCredits, used, payload["status"] as? String ?? "done"),
                    durationMs: elapsed, failed: (payload["status"] as? String ?? "success") != "success"
                )
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
            notes.append("The transcript is longer than the read limit.")
        }
        if hookRuns > 0 {
            notes.append("\(hookRuns) hook runs are counted but not drawn as events.")
        }
        notes.append("Kiro stamps a tool call and its result at the same instant, so tool rows have no duration. Reasoning and reply rows show the wait since the previous event.")
        if credits > 0 {
            notes.append(String(format: "Kiro recorded %.2f credits for the completed turns.", credits))
        }
        if let contextPercent {
            notes.append(String(format: "Last context usage: %.1f%%.", contextPercent))
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
        var notes = ["Kiro CLI does not store the system prompt in the transcript. Context % comes from the sidecar JSON when present."]
        var contextPercent = ref.contextPercent
        var contextWindow: Int?
        if let object = JSONFile.object(url: jsonURL) {
            let meta = cliContext(object)
            contextPercent = meta.percent ?? contextPercent
            contextWindow = meta.window
        }
        if let contextPercent, let contextWindow {
            let used = Int((contextPercent / 100) * Double(contextWindow))
            notes.append("Recorded context is about \(used) / \(contextWindow) tokens (\(String(format: "%.1f", contextPercent))%).")
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

        // The sidecar JSON keeps one record per user turn: which messages belong to it,
        // when it ended, how long it took, and what it cost. The transcript has no clock
        // of its own except the prompt.
        let sidecar = JSONFile.object(url: jsonURL)
        let metas = ((sidecar?["session_state"] as? [String: Any])?["conversation_metadata"] as? [String: Any])?["user_turn_metadatas"] as? [[String: Any]] ?? []
        var messageTurn: [String: Int] = [:]
        for (index, meta) in metas.enumerated() {
            for id in meta["message_ids"] as? [String] ?? [] { messageTurn[id] = index }
        }
        var turnFirst: [Int: Int] = [:]
        var turnLast: [Int: Int] = [:]
        var callEntries: [String: Int] = [:]
        var currentTurnIndex = -1
        var promptStarts: [Int: Int] = [:]

        func note(_ turn: Int, _ index: Int) {
            if turnFirst[turn] == nil { turnFirst[turn] = index }
            turnLast[turn] = index
        }

        let truncated = Files.forEachLine(url: jsonlURL, maxBytes: GrokAnalyzer.reportCap) { line in
            guard let object = JSONFile.lineObject(line) else { return true }
            let kind = object["kind"] as? String ?? ""
            let data = object["data"] as? [String: Any] ?? [:]
            if let id = data["message_id"] as? String, let turn = messageTurn[id] { currentTurnIndex = turn }
            let turnNumber = max(currentTurnIndex + 1, turns.count, 1)
            switch kind {
            case "Prompt":
                let text = partText(data["content"])
                add(.user, text.utf8.count)
                turns.append(TurnMeasure(index: turns.count + 1, preview: PromptText.preview(text), userBytes: text.utf8.count, replyBytes: 0))
                let stamp = Clock.millis((data["meta"] as? [String: Any])?["timestamp"])
                let index = trajectory.add(
                    at: stamp, turn: max(currentTurnIndex + 1, turns.count), kind: "user",
                    label: PromptText.preview(text), bytes: text.utf8.count
                )
                if currentTurnIndex >= 0 { promptStarts[currentTurnIndex] = stamp ?? 0; note(currentTurnIndex, index) }
                turnReply = 0
            case "AssistantMessage":
                guard let parts = data["content"] as? [[String: Any]] else { break }
                for part in parts {
                    let partKind = part["kind"] as? String ?? ""
                    var index: Int?
                    if partKind == "text", let text = part["data"] as? String {
                        add(.assistant, text.utf8.count)
                        turnReply += text.utf8.count
                        if !text.isEmpty {
                            index = trajectory.add(
                                at: nil, turn: turnNumber, kind: "assistant",
                                label: PromptText.preview(text, limit: 80), bytes: text.utf8.count
                            )
                        }
                    } else if partKind == "thinking" {
                        let bytes = stringBytes(part["data"])
                        add(.reasoning, bytes)
                        turnReply += bytes
                        let visible = ((part["data"] as? [String: Any])?["text"] as? String ?? "").utf8.count
                        if visible > 0 {
                            index = trajectory.add(at: nil, turn: turnNumber, kind: "reasoning", label: "reasoning", bytes: visible)
                        }
                    } else if partKind == "toolUse", let payload = part["data"] as? [String: Any] {
                        let name = payload["name"] as? String ?? "tool"
                        let id = payload["toolUseId"] as? String ?? ""
                        if !id.isEmpty { callNames[id] = name }
                        let args = jsonText(payload["input"])
                        add(.other, args.utf8.count)
                        bumpTool(&tools, name: name, call: true, result: 0)
                        absorbSkills(args, into: &skills)
                        let call = trajectory.add(
                            at: nil, turn: turnNumber, kind: TrailLabel.isSubagent(name) ? "subagent" : "tool",
                            label: TrailLabel.tool(name, payload["input"]), bytes: args.utf8.count
                        )
                        if !id.isEmpty { callEntries[id] = call }
                        index = call
                    }
                    if let index, currentTurnIndex >= 0 { note(currentTurnIndex, index) }
                }
            case "ToolResults":
                var failedIDs = Set<String>()
                for item in data["content"] as? [[String: Any]] ?? [] {
                    let result = item["data"] as? [String: Any]
                    if result?["status"] as? String == "error", let id = result?["toolUseId"] as? String { failedIDs.insert(id) }
                }
                let results = data["results"] as? [String: Any] ?? [:]
                for (id, value) in results {
                    let bytes = stringBytes(value)
                    add(.toolResult, bytes)
                    turnReply += bytes
                    let name = callNames[id] ?? "tool"
                    bumpTool(&tools, name: name, call: false, result: bytes)
                    considerHeavy(&heavy, tool: name, bytes: bytes)
                    let resultBytes = stringBytes((value as? [String: Any])?["result"])
                    trajectory.close(callEntries[id], at: nil, bytes: resultBytes, failed: failedIDs.contains(id))
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

        // Spread each turn's events over the time the sidecar recorded for it. The order is
        // real; the position inside the turn is interpolated, and the durations stay empty.
        var interpolated = false
        for (turn, meta) in metas.enumerated() {
            guard let first = turnFirst[turn], let last = turnLast[turn] else { continue }
            let seconds = (meta["turn_duration"] as? [String: Any]).map {
                (number($0["secs"]) ?? 0) + (number($0["nanos"]) ?? 0) / 1_000_000_000
            } ?? 0
            let end = kiroMillis(meta["end_timestamp"])
            let begin = trajectory[first].at ?? end.map { $0 - Int(seconds * 1000) }
            guard let begin else { continue }
            let span = max((end ?? begin) - begin, 0)
            let count = max(last - first, 1)
            for index in first...last where trajectory[index].at == nil {
                trajectory[index].at = begin + span * (index - first) / count
                interpolated = true
            }
            let requests = Int(number(meta["total_request_count"]) ?? 0)
            let credits = (meta["metering_usage"] as? [[String: Any]] ?? []).reduce(0.0) { $0 + (number($1["value"]) ?? 0) }
            let ended = meta["end_reason"] as? String ?? "UserTurnEnd"
            trajectory.add(
                at: end ?? begin + span, turn: turn + 1, kind: "notice",
                label: String(format: "turn done · %d requests · %.2f credits · %@", requests, credits, meta["model"] as? String ?? "?"),
                durationMs: Int(seconds * 1000), failed: ended != "UserTurnEnd",
                tokens: number(meta["final_context_usage_percentage"]).flatMap { percent in
                    contextWindow.map { Int(percent / 100 * Double($0)) }
                }
            )
        }
        trajectory.sort { ($0.at ?? Int.max, $0.index) < ($1.at ?? Int.max, $1.index) }
        for index in trajectory.indices { trajectory[index].index = index }
        if interpolated {
            notes.append("Kiro CLI stamps only the prompt and the end of each turn. Events in between keep their real order and are spread across the recorded turn time.")
        }
        if truncated { notes.append("The transcript is longer than the read limit.") }
        notes.append("The byte/4 token estimate is used only when the sidecar has no context window.")

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
                summary: "Read from a tool.",
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
