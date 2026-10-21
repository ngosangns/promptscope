import Foundation

public enum AgentSource: String, Codable, Sendable, CaseIterable, Identifiable {
    case grok
    case kiroIDE = "kiro-ide"
    case kiroCLI = "kiro-cli"
    case omp
    case pi
    case devin
    case dsh

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .grok: "Grok"
        case .kiroIDE: "Kiro"
        case .kiroCLI: "Kiro CLI"
        case .omp: "OMP"
        case .pi: "Pi"
        case .devin: "Devin"
        case .dsh: "DSH"
        }
    }
}

public enum SliceKind: String, Codable, Sendable, CaseIterable {
    case system
    case skills
    case mcp
    case rules
    case toolDefs
    case user
    case assistant
    case toolResult
    case reasoning
    case steering
    case other

    public var label: String {
        switch self {
        case .system: "System prompt"
        case .skills: "Skill"
        case .mcp: "MCP"
        case .rules: "Rules & user info"
        case .toolDefs: "Tool definitions"
        case .user: "User"
        case .assistant: "Assistant"
        case .toolResult: "Tool results"
        case .reasoning: "Saved reasoning"
        case .steering: "Steering"
        case .other: "Other"
        }
    }
}

public struct Slice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { kind.rawValue }
    public var kind: SliceKind
    public var bytes: Int

    public init(kind: SliceKind, bytes: Int) {
        self.kind = kind
        self.bytes = bytes
    }
}

public struct NamedBytes: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytes: Int
    public var detail: String

    public init(name: String, bytes: Int, detail: String = "") {
        self.name = name
        self.bytes = bytes
        self.detail = detail
    }
}

public struct SessionRef: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var source: AgentSource
    public var sessionID: String
    public var title: String
    public var cwd: String
    public var model: String?
    public var agent: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Session directory, or the CLI sidecar JSON file.
    public var locator: String
    public var transcriptBytes: Int
    public var isSubagent: Bool
    public var isTemporary: Bool
    public var contextPercent: Double?
    public var fingerprint: String

    public init(
        id: String,
        source: AgentSource,
        sessionID: String,
        title: String,
        cwd: String,
        model: String?,
        agent: String?,
        createdAt: Date?,
        updatedAt: Date?,
        locator: String,
        transcriptBytes: Int,
        isSubagent: Bool,
        isTemporary: Bool,
        contextPercent: Double?,
        fingerprint: String
    ) {
        self.id = id
        self.source = source
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.model = model
        self.agent = agent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.locator = locator
        self.transcriptBytes = transcriptBytes
        self.isSubagent = isSubagent
        self.isTemporary = isTemporary
        self.contextPercent = contextPercent
        self.fingerprint = fingerprint
    }

    public var isNoise: Bool { isSubagent || isTemporary }

    public var folderURL: URL {
        let url = URL(fileURLWithPath: locator)
        if url.pathExtension == "json" || url.pathExtension == "jsonl" {
            return url.deletingLastPathComponent()
        }
        return url
    }
}

public struct SkillMeasure: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var catalogBytes: Int
    public var summary: String
    public var path: String?
    public var origin: String
    public var diskBytes: Int?
    public var readCount: Int

    public init(
        name: String,
        catalogBytes: Int,
        summary: String,
        path: String?,
        origin: String,
        diskBytes: Int? = nil,
        readCount: Int = 0
    ) {
        self.name = name
        self.catalogBytes = catalogBytes
        self.summary = summary
        self.path = path
        self.origin = origin
        self.diskBytes = diskBytes
        self.readCount = readCount
    }
}

public struct McpMeasure: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var catalogBytes: Int
    public var toolCount: Int?
    public var status: String
    public var tools: [String]
    public var blurb: String

    public init(
        name: String,
        catalogBytes: Int,
        toolCount: Int?,
        status: String,
        tools: [String],
        blurb: String
    ) {
        self.name = name
        self.catalogBytes = catalogBytes
        self.toolCount = toolCount
        self.status = status
        self.tools = tools
        self.blurb = blurb
    }
}

public struct ToolMeasure: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var definitionBytes: Int
    public var calls: Int
    public var resultBytes: Int

    public init(name: String, definitionBytes: Int = 0, calls: Int = 0, resultBytes: Int = 0) {
        self.name = name
        self.definitionBytes = definitionBytes
        self.calls = calls
        self.resultBytes = resultBytes
    }
}

public struct SectionMeasure: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytes: Int
    public var preview: String

    public init(name: String, bytes: Int, preview: String) {
        self.name = name
        self.bytes = bytes
        self.preview = preview
    }
}

/// One event on the session timeline. `kind` is one of `user`, `reasoning`,
/// `assistant`, `tool`, `compaction`, `subagent`, `approval`, `retry`, `error`,
/// `notice`. Every analyzer fills what its log records and leaves the rest nil.
public struct TrajectoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// Wall clock in milliseconds when the log has one.
    public var at: Int?
    public var turn: Int
    public var kind: String
    public var label: String
    public var bytes: Int
    /// Duration in milliseconds, when the log records one.
    public var durationMs: Int?
    /// A tool call, request, or turn that ended in an error.
    public var failed: Bool
    /// Prompt tokens the provider recorded for the request this event belongs to.
    public var tokens: Int?

    public init(
        index: Int, at: Int?, turn: Int, kind: String, label: String, bytes: Int,
        durationMs: Int? = nil, failed: Bool = false, tokens: Int? = nil
    ) {
        self.index = index
        self.at = at
        self.turn = turn
        self.kind = kind
        self.label = label
        self.bytes = bytes
        self.durationMs = durationMs
        self.failed = failed
        self.tokens = tokens
    }
}

extension Array where Element == TrajectoryEntry {
    /// Appends an event and returns its index, so a later result can close it.
    @discardableResult
    mutating func add(
        at: Int?, turn: Int, kind: String, label: String, bytes: Int = 0,
        durationMs: Int? = nil, failed: Bool = false, tokens: Int? = nil
    ) -> Int {
        append(TrajectoryEntry(
            index: count, at: at, turn: turn, kind: kind, label: label, bytes: bytes,
            durationMs: durationMs, failed: failed, tokens: tokens
        ))
        return count - 1
    }

    /// Closes a tool, approval, or subagent entry: adds the output size, derives the
    /// duration from the two clocks, and marks a failure.
    mutating func close(_ index: Int?, at: Int?, bytes: Int = 0, failed: Bool = false) {
        guard let index, index < count else { return }
        self[index].bytes += bytes
        // A zero span means the log stamped both ends at one instant. That is no measurement.
        if let start = self[index].at, let at, at > start {
            self[index].durationMs = Swift.max(self[index].durationMs ?? 0, at - start)
        }
        if failed { self[index].failed = true }
    }
}

public struct TurnMeasure: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var preview: String
    public var userBytes: Int
    public var replyBytes: Int

    public init(index: Int, preview: String, userBytes: Int, replyBytes: Int) {
        self.index = index
        self.preview = preview
        self.userBytes = userBytes
        self.replyBytes = replyBytes
    }
}

public struct HeavyResult: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(rank)-\(tool)-\(bytes)" }
    public var rank: Int
    public var tool: String
    public var bytes: Int

    public init(rank: Int, tool: String, bytes: Int) {
        self.rank = rank
        self.tool = tool
        self.bytes = bytes
    }
}

public struct SessionDigest: Codable, Sendable, Hashable {
    public var id: String
    public var fingerprint: String
    public var standing: [Slice]
    public var transcriptBytes: Int
    public var skills: [NamedBytes]
    public var mcp: [NamedBytes]
    public var contextPercent: Double?
    public var contextWindow: Int?
    /// Provider-recorded prompt tokens from the last model turn, when the log has them.
    public var promptTokens: Int?

    public init(
        id: String,
        fingerprint: String,
        standing: [Slice],
        transcriptBytes: Int,
        skills: [NamedBytes],
        mcp: [NamedBytes],
        contextPercent: Double?,
        contextWindow: Int?,
        promptTokens: Int? = nil
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.standing = standing
        self.transcriptBytes = transcriptBytes
        self.skills = skills
        self.mcp = mcp
        self.contextPercent = contextPercent
        self.contextWindow = contextWindow
        self.promptTokens = promptTokens
    }

    public var standingBytes: Int { standing.reduce(0) { $0 + $1.bytes } }
}

public struct SessionReport: Sendable {
    public var ref: SessionRef
    public var standing: [Slice]
    public var transcript: [Slice]
    public var sections: [SectionMeasure]
    public var skills: [SkillMeasure]
    public var mcp: [McpMeasure]
    public var tools: [ToolMeasure]
    public var turns: [TurnMeasure]
    public var trajectory: [TrajectoryEntry]
    public var heavy: [HeavyResult]
    public var steering: [NamedBytes]
    public var contextPercent: Double?
    public var contextWindow: Int?
    public var promptTokens: Int?
    public var notes: [String]
    public var truncated: Bool

    public init(
        ref: SessionRef,
        standing: [Slice],
        transcript: [Slice],
        sections: [SectionMeasure],
        skills: [SkillMeasure],
        mcp: [McpMeasure],
        tools: [ToolMeasure],
        turns: [TurnMeasure],
        trajectory: [TrajectoryEntry] = [],
        heavy: [HeavyResult],
        steering: [NamedBytes],
        contextPercent: Double?,
        contextWindow: Int?,
        promptTokens: Int? = nil,
        notes: [String],
        truncated: Bool
    ) {
        self.ref = ref
        self.standing = standing
        self.transcript = transcript
        self.sections = sections
        self.skills = skills
        self.mcp = mcp
        self.tools = tools
        self.turns = turns
        self.trajectory = trajectory
        self.heavy = heavy
        self.steering = steering
        self.contextPercent = contextPercent
        self.contextWindow = contextWindow
        self.promptTokens = promptTokens
        self.notes = notes
        self.truncated = truncated
    }

    public var standingBytes: Int { standing.reduce(0) { $0 + $1.bytes } }
    public var transcriptCompositionBytes: Int { transcript.reduce(0) { $0 + $1.bytes } }

    public func digest() -> SessionDigest {
        SessionDigest(
            id: ref.id,
            fingerprint: ref.fingerprint,
            standing: standing.filter { $0.bytes > 0 },
            transcriptBytes: ref.transcriptBytes,
            skills: skills.map {
                NamedBytes(name: $0.name, bytes: $0.catalogBytes, detail: $0.origin)
            },
            mcp: mcp.map {
                NamedBytes(
                    name: $0.name,
                    bytes: $0.catalogBytes,
                    detail: $0.status
                )
            },
            contextPercent: contextPercent ?? ref.contextPercent,
            contextWindow: contextWindow,
            promptTokens: promptTokens
        )
    }
}

public struct LibraryScan: Sendable {
    public var sessions: [SessionRef]
    public var skippedEmptyCLI: Int
    public var notes: [String]

    public init(sessions: [SessionRef], skippedEmptyCLI: Int, notes: [String]) {
        self.sessions = sessions
        self.skippedEmptyCLI = skippedEmptyCLI
        self.notes = notes
    }
}

public enum ByteFormat {
    public static func bytes(_ n: Int) -> String {
        let value = Double(n)
        if n < 1024 { return "\(n) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", value / 1024) }
        return String(format: "%.1f MB", value / 1024 / 1024)
    }

    /// Rough stand-in. Providers do not store a tokenizer count in these files.
    public static func tokens(_ bytes: Int) -> String {
        let tokens = bytes / 4
        if tokens < 1000 { return "~\(tokens)" }
        if tokens < 1_000_000 { return String(format: "~%.1fk", Double(tokens) / 1000) }
        return String(format: "~%.2fM", Double(tokens) / 1_000_000)
    }

    public static func exactTokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }

    public static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return String(format: "%.0f%%", 100 * Double(part) / Double(whole))
    }
}

public enum ReportText {
    public static func plain(_ report: SessionReport) -> String {
        var lines: [String] = []
        let ref = report.ref
        lines.append(ref.title)
        lines.append("\(ref.source.label)  \(ref.sessionID)")
        if !ref.cwd.isEmpty { lines.append(ref.cwd) }
        var meta: [String] = []
        if let model = ref.model { meta.append(model) }
        if let agent = ref.agent { meta.append(agent) }
        if !meta.isEmpty { lines.append(meta.joined(separator: "  ")) }
        lines.append("")
        lines.append("Standing prompt  \(ByteFormat.tokens(report.standingBytes)) estimated tokens (byte/4)")
        for slice in report.standing where slice.bytes > 0 {
            lines.append("  \(slice.kind.label)  \(ByteFormat.tokens(slice.bytes))  \(ByteFormat.percent(slice.bytes, report.standingBytes))")
        }
        if !report.sections.isEmpty {
            lines.append("")
            lines.append("System prompt")
            for section in report.sections {
                lines.append("  \(section.name)  \(ByteFormat.tokens(section.bytes))")
            }
        }
        if !report.skills.isEmpty {
            lines.append("")
            lines.append("Skill trong prompt")
            for skill in report.skills {
                let disk = skill.diskBytes.map { "disk \(ByteFormat.tokens($0))" } ?? "file not found"
                lines.append("  \(skill.name)  catalog \(ByteFormat.tokens(skill.catalogBytes))  \(disk)  reads \(skill.readCount)  \(skill.origin)")
            }
        }
        if !report.mcp.isEmpty {
            lines.append("")
            lines.append("MCP trong prompt")
            for server in report.mcp {
                let tools = server.toolCount.map { "\($0) tools" } ?? "tools ?"
                lines.append("  \(server.name)  \(ByteFormat.tokens(server.catalogBytes))  \(server.status)  \(tools)")
            }
        }
        if !report.tools.isEmpty {
            lines.append("")
            lines.append("Tool")
            for tool in report.tools.prefix(20) {
                lines.append("  \(tool.name)  def \(ByteFormat.tokens(tool.definitionBytes))  calls \(tool.calls)  results \(ByteFormat.tokens(tool.resultBytes))")
            }
        }
        if !report.trajectory.isEmpty {
            // The window draws the events. The text keeps one line so the report stays short.
            let failed = report.trajectory.filter(\.failed).count
            let timed = report.trajectory.contains { $0.at != nil }
            lines.append("")
            lines.append("Trajectory  \(report.trajectory.count) events  \(failed) failed  \(timed ? "timed" : "no clock")  (report … --json lists them)")
        }
        if !report.steering.isEmpty {
            lines.append("")
            lines.append("Steering")
            for doc in report.steering {
                lines.append("  \(ByteFormat.tokens(doc.bytes))  \(doc.name)")
            }
        }
        if let pct = report.contextPercent {
            let window = report.contextWindow.map { " / \($0) token" } ?? ""
            lines.append("")
            lines.append(String(format: "Recorded context: %.1f%%%@", pct, window))
        }
        if let tokens = report.promptTokens {
            lines.append("Recorded input tokens: \(tokens)")
        }
        if !report.notes.isEmpty {
            lines.append("")
            for note in report.notes { lines.append(note) }
        }
        return lines.joined(separator: "\n")
    }
}
