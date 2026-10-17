import Foundation

public enum SessionAnalyzer {
    public static func report(for ref: SessionRef) -> SessionReport {
        switch ref.source {
        case .grok: GrokAnalyzer.report(ref)
        case .kiroIDE: KiroIDEAnalyzer.report(ref)
        case .kiroCLI: KiroCLIAnalyzer.report(ref)
        }
    }

    public static func digest(for ref: SessionRef) -> SessionDigest {
        switch ref.source {
        case .grok: GrokAnalyzer.digest(ref)
        case .kiroIDE, .kiroCLI: report(for: ref).digest()
        }
    }
}

public enum LibraryScanner {
    public static func scan(grokHome: URL, kiroHome: URL) -> LibraryScan {
        var sessions: [SessionRef] = []
        var notes: [String] = []
        var skipped = 0
        if FileManager.default.fileExists(atPath: grokHome.appendingPathComponent("sessions").path) {
            sessions.append(contentsOf: scanGrok(grokHome.appendingPathComponent("sessions")))
        } else {
            notes.append("Không thấy \(grokHome.path)/sessions.")
        }
        let kiroSessions = kiroHome.appendingPathComponent("sessions")
        if FileManager.default.fileExists(atPath: kiroSessions.path) {
            let kiro = scanKiro(kiroSessions)
            sessions.append(contentsOf: kiro.sessions)
            skipped = kiro.skipped
        } else {
            notes.append("Không thấy \(kiroHome.path)/sessions.")
        }
        return LibraryScan(sessions: sessions, skippedEmptyCLI: skipped, notes: notes)
    }

    public static var defaultGrokHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    public static var defaultKiroHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro")
    }
}

private func scanGrok(_ root: URL) -> [SessionRef] {
    guard let groups = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var sessions: [SessionRef] = []
    for group in groups where isDirectory(group) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: group,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for child in children where isDirectory(child) {
            let summaryURL = child.appendingPathComponent("summary.json")
            guard FileManager.default.fileExists(atPath: summaryURL.path) else { continue }
            let summary = JSONFile.object(url: summaryURL) ?? [:]
            let info = summary["info"] as? [String: Any]
            let sessionID = (info?["id"] as? String) ?? child.lastPathComponent
            let cwd = info?["cwd"] as? String ?? ""
            let title = nonEmpty(summary["generated_title"]) ?? nonEmpty(summary["session_summary"]) ?? "Không tiêu đề"
            let updated = Dates.parse(summary["updated_at"] as? String) ?? Dates.parse(summary["last_active_at"] as? String)
            let created = Dates.parse(summary["created_at"] as? String)
            let chatBytes = Files.size(child.appendingPathComponent("chat_history.jsonl"))
            let systemBytes = Files.size(child.appendingPathComponent("system_prompt.txt"))
            let toolBytes = Files.size(child.appendingPathComponent("tool_definitions.json"))
            let locator = child.path
            sessions.append(SessionRef(
                id: "grok:\(sessionID)",
                source: .grok,
                sessionID: sessionID,
                title: title,
                cwd: cwd,
                model: nonEmpty(summary["current_model_id"]),
                agent: nonEmpty(summary["agent_name"]),
                createdAt: created,
                updatedAt: updated ?? created,
                locator: locator,
                transcriptBytes: chatBytes,
                isSubagent: locator.lowercased().contains("subagent"),
                isTemporary: Paths.isTemporary(cwd),
                contextPercent: nil,
                fingerprint: "\(chatBytes)|\(systemBytes)|\(toolBytes)|\(updated?.timeIntervalSince1970 ?? 0)"
            ))
        }
    }
    return sessions
}

private func scanKiro(_ root: URL) -> (sessions: [SessionRef], skipped: Int) {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return ([], 0) }
    var sessions: [SessionRef] = []
    var skipped = 0
    for entry in entries where isDirectory(entry) {
        if entry.lastPathComponent == "cli" {
            let cli = scanKiroCLI(entry)
            sessions.append(contentsOf: cli.sessions)
            skipped += cli.skipped
            continue
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: entry,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for child in children where child.lastPathComponent.hasPrefix("sess_") && isDirectory(child) {
            let sessionURL = child.appendingPathComponent("session.json")
            guard let object = JSONFile.object(url: sessionURL) else { continue }
            let sessionID = (object["id"] as? String) ?? child.lastPathComponent
            let paths = object["workspacePaths"] as? [String]
            let cwd = paths?.first ?? (object["rootPaths"] as? [String])?.first ?? ""
            let updated = Dates.parse(object["lastModifiedAt"] as? String)
            let created = Dates.parse(object["createdAt"] as? String)
            let transcript = Files.size(child.appendingPathComponent("messages.jsonl"))
            let childOf = nonEmpty(object["rootConversationId"])
            sessions.append(SessionRef(
                id: "kiro-ide:\(sessionID)",
                source: .kiroIDE,
                sessionID: sessionID,
                title: nonEmpty(object["title"]) ?? "Không tiêu đề",
                cwd: cwd,
                model: nonEmpty(object["modelId"]),
                agent: nonEmpty(object["agentMode"]),
                createdAt: created,
                updatedAt: updated ?? created,
                locator: child.path,
                transcriptBytes: transcript,
                isSubagent: childOf != nil,
                isTemporary: Paths.isTemporary(cwd),
                contextPercent: nil,
                fingerprint: "\(transcript)|\(updated?.timeIntervalSince1970 ?? 0)"
            ))
        }
    }
    return (sessions, skipped)
}

private func scanKiroCLI(_ root: URL) -> (sessions: [SessionRef], skipped: Int) {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return ([], 0) }
    var transcriptSize: [String: Int] = [:]
    for file in files where file.pathExtension == "jsonl" {
        transcriptSize[file.deletingPathExtension().lastPathComponent] = Files.size(file)
    }
    var sessions: [SessionRef] = []
    var skipped = 0
    for file in files where file.pathExtension == "json" {
        let id = file.deletingPathExtension().lastPathComponent
        let transcript = transcriptSize[id] ?? 0
        guard transcript > 0 else {
            skipped += 1
            continue
        }
        let object = JSONFile.object(url: file) ?? [:]
        let meta = cliContext(object)
        let cwd = object["cwd"] as? String ?? ""
        let updated = Dates.parse(object["updated_at"] as? String)
        let created = Dates.parse(object["created_at"] as? String)
        let reason = object["session_created_reason"] as? String
        var title = nonEmpty(object["title"]) ?? ""
        if title.isEmpty { title = cliPromptTitle(file.deletingPathExtension().appendingPathExtension("jsonl")) ?? "Không tiêu đề" }
        sessions.append(SessionRef(
            id: "kiro-cli:\(id)",
            source: .kiroCLI,
            sessionID: id,
            title: title,
            cwd: cwd,
            model: meta.model,
            agent: meta.agent,
            createdAt: created,
            updatedAt: updated ?? created,
            locator: file.path,
            transcriptBytes: transcript,
            isSubagent: reason == "subagent",
            isTemporary: Paths.isTemporary(cwd),
            contextPercent: meta.percent,
            fingerprint: "\(transcript)|\(meta.percent ?? 0)|\(updated?.timeIntervalSince1970 ?? 0)"
        ))
    }
    return (sessions, skipped)
}

private func cliPromptTitle(_ url: URL) -> String? {
    var title: String?
    _ = Files.forEachLine(url: url, maxBytes: 64_000) { line in
        guard let object = JSONFile.lineObject(line), object["kind"] as? String == "Prompt" else { return true }
        let data = object["data"] as? [String: Any]
        let text = partText(data?["content"])
        let trimmed = PromptText.preview(text, limit: 120)
        if !trimmed.isEmpty { title = trimmed }
        return false
    }
    return title
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
