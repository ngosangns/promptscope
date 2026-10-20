import Foundation

public enum SessionAnalyzer {
    public static func report(for ref: SessionRef) -> SessionReport {
        switch ref.source {
        case .grok: GrokAnalyzer.report(ref)
        case .kiroIDE: KiroIDEAnalyzer.report(ref)
        case .kiroCLI: KiroCLIAnalyzer.report(ref)
        case .omp, .pi: PiFamilyAnalyzer.report(ref)
        case .devin: DevinAnalyzer.report(ref)
        case .dsh: DshAnalyzer.report(ref)
        }
    }

    public static func digest(for ref: SessionRef) -> SessionDigest {
        switch ref.source {
        case .grok: GrokAnalyzer.digest(ref)
        case .omp, .pi: PiFamilyAnalyzer.digest(ref)
        case .kiroIDE, .kiroCLI, .devin, .dsh: report(for: ref).digest()
        }
    }
}

public enum LibraryScanner {
    public static func scan(
        grokHome: URL,
        kiroHome: URL,
        ompHome: URL,
        piHome: URL,
        devinHome: URL,
        dshHome: URL
    ) -> LibraryScan {
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
        let ompSessions = ompHome.appendingPathComponent("agent/sessions")
        if FileManager.default.fileExists(atPath: ompSessions.path) {
            sessions.append(contentsOf: scanPiFamily(ompSessions, source: .omp))
        } else {
            notes.append("Không thấy \(ompSessions.path).")
        }
        let piSessions = piHome.appendingPathComponent("agent/sessions")
        if FileManager.default.fileExists(atPath: piSessions.path) {
            sessions.append(contentsOf: scanPiFamily(piSessions, source: .pi))
        } else {
            notes.append("Không thấy \(piSessions.path).")
        }
        let devinTranscripts = devinHome.appendingPathComponent("cli/transcripts")
        if FileManager.default.fileExists(atPath: devinTranscripts.path) {
            sessions.append(contentsOf: scanDevin(devinTranscripts))
        } else {
            notes.append("Không thấy \(devinTranscripts.path).")
        }
        let dshSessions = dshHome.appendingPathComponent("sessions")
        if FileManager.default.fileExists(atPath: dshSessions.path) {
            let dsh = scanDsh(dshSessions)
            sessions.append(contentsOf: dsh.sessions)
            skipped += dsh.skipped
        } else {
            notes.append("Không thấy \(dshSessions.path).")
        }
        return LibraryScan(sessions: sessions, skippedEmptyCLI: skipped, notes: notes)
    }

    public static var defaultGrokHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    public static var defaultKiroHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kiro")
    }

    public static var defaultOmpHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omp")
    }

    public static var defaultPiHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi")
    }

    public static var defaultDevinHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devin")
    }

    public static var defaultDshHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
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

private func scanPiFamily(_ root: URL, source: AgentSource) -> [SessionRef] {
    guard let groups = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var sessions: [SessionRef] = []
    for group in groups where isDirectory(group) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: group,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for child in children where child.pathExtension == "jsonl" && Files.size(child) > 0 {
            sessions.append(piSession(child, source: source, subagent: false))
        }
        for child in children where isDirectory(child) {
            guard let nested = try? FileManager.default.contentsOfDirectory(
                at: child,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in nested where file.pathExtension == "jsonl" && Files.size(file) > 0 {
                sessions.append(piSession(file, source: source, subagent: true))
            }
        }
    }
    return sessions
}

private func piSession(_ url: URL, source: AgentSource, subagent: Bool) -> SessionRef {
    let header = readPiHeader(url)
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    let sessionID = header.id.isEmpty ? url.deletingPathExtension().lastPathComponent : header.id
    let title = header.title.isEmpty ? sessionID : header.title
    let updated = header.updated ?? modified ?? header.created
    return SessionRef(
        id: "\(source.rawValue):\(sessionID)",
        source: source,
        sessionID: sessionID,
        title: title,
        cwd: header.cwd,
        model: header.model,
        agent: nil,
        createdAt: header.created,
        updatedAt: updated,
        locator: url.path,
        transcriptBytes: Files.size(url),
        isSubagent: subagent,
        isTemporary: Paths.isTemporary(header.cwd),
        contextPercent: nil,
        fingerprint: "\(Files.size(url))|\(updated?.timeIntervalSince1970 ?? 0)"
    )
}

private struct PiHeader {
    var id = ""
    var cwd = ""
    var title = ""
    var model: String?
    var created: Date?
    var updated: Date?
}

private func readPiHeader(_ url: URL) -> PiHeader {
    var header = PiHeader()
    var hasTitle = false
    var hasSession = false
    var hasModel = false
    _ = Files.forEachLine(url: url, maxBytes: 256 * 1024) { line in
        guard let object = JSONFile.lineObject(line) else { return true }
        switch object["type"] as? String {
        case "title":
            header.title = nonEmpty(object["title"]) ?? header.title
            header.updated = Dates.parse(object["updatedAt"] as? String) ?? header.updated
            hasTitle = !header.title.isEmpty
        case "session":
            header.id = nonEmpty(object["id"]) ?? header.id
            header.cwd = object["cwd"] as? String ?? header.cwd
            header.created = Dates.parse(object["timestamp"] as? String) ?? header.created
            hasSession = !header.id.isEmpty
        case "model_change":
            header.model = nonEmpty(object["model"]) ?? nonEmpty(object["modelId"]) ?? header.model
            hasModel = header.model != nil
        case "message":
            let message = object["message"] as? [String: Any]
            if message?["role"] as? String == "user", header.title.isEmpty {
                header.title = PromptText.preview(piContent(message?["content"]), limit: 90)
                return false
            }
        default:
            break
        }
        if hasTitle && hasSession && hasModel { return false }
        return true
    }
    return header
}

private func piContent(_ content: Any?) -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [Any] else { return "" }
    return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: " ")
}

private func scanDevin(_ root: URL) -> [SessionRef] {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var sessions: [SessionRef] = []
    for file in files where file.pathExtension == "json" && Files.size(file) > 32 {
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let object = JSONFile.object(url: file, maxBytes: 8_000_000)
        let sessionID = nonEmpty(object?["session_id"]) ?? file.deletingPathExtension().lastPathComponent
        let agent = object?["agent"] as? [String: Any]
        let model = nonEmpty(agent?["model_name"])
        let steps = object?["steps"] as? [[String: Any]] ?? []
        let created = Dates.parse(steps.first?["timestamp"] as? String)
        let updated = Dates.parse(steps.last?["timestamp"] as? String) ?? modified
        var title = ""
        for step in steps where step["source"] as? String == "user" {
            title = PromptText.preview(step["message"] as? String ?? "", limit: 90)
            if !title.isEmpty { break }
        }
        if title.isEmpty { title = sessionID }
        sessions.append(SessionRef(
            id: "devin:\(sessionID)",
            source: .devin,
            sessionID: sessionID,
            title: title,
            cwd: "",
            model: model,
            agent: nonEmpty(agent?["name"]),
            createdAt: created,
            updatedAt: updated ?? created,
            locator: file.path,
            transcriptBytes: Files.size(file),
            isSubagent: false,
            isTemporary: false,
            contextPercent: nil,
            fingerprint: "\(Files.size(file))|\(updated?.timeIntervalSince1970 ?? 0)"
        ))
    }
    return sessions
}

private func scanDsh(_ root: URL) -> (sessions: [SessionRef], skipped: Int) {
    guard let projects = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return ([], 0) }
    var sessions: [SessionRef] = []
    var skipped = 0
    for project in projects where isDirectory(project) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: project,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for child in children where isDirectory(child) {
            guard let log = dshLog(child) else { continue }
            let header = DshLog.header(url: log)
            if header.version != 4 || !header.hasTurn {
                skipped += 1
                continue
            }
            let sessionID = header.id.isEmpty ? child.lastPathComponent : header.id
            let modified = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let title = header.title.isEmpty ? sessionID : header.title
            sessions.append(SessionRef(
                id: "dsh:\(sessionID)",
                source: .dsh,
                sessionID: sessionID,
                title: title,
                cwd: header.cwd,
                model: header.model,
                agent: header.agent,
                createdAt: header.created,
                updatedAt: modified ?? header.created,
                locator: log.path,
                transcriptBytes: Files.size(log),
                isSubagent: header.subagent,
                isTemporary: Paths.isTemporary(header.cwd),
                contextPercent: nil,
                fingerprint: "\(Files.size(log))|\(modified?.timeIntervalSince1970 ?? 0)"
            ))
        }
    }
    return (sessions, skipped)
}

/// Current log is `session.vN.jsonl` or `session.vN.jsonl.zstd`. The highest N wins.
private func dshLog(_ directory: URL) -> URL? {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return nil }
    var best: (version: Int, url: URL)?
    for file in files {
        let name = file.lastPathComponent
        guard name.hasPrefix("session.v"), name.contains(".jsonl") else { continue }
        let version = Int(name.dropFirst("session.v".count).prefix { $0.isNumber }) ?? 0
        if best == nil || version > best!.version { best = (version, file) }
    }
    return best?.url
}

private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
}

private func nonEmpty(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
