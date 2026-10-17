import XCTest
import PromptscopeKit

final class AnalyzerTests: XCTestCase {
    func testSectionsIgnoreInlineTags() {
        let text = """
        You are a test agent. See the <user_query> tag.

        <dangerous_actions>
        Do not delete.
        </dangerous_actions>

        <work_policy>
        Finish the task.
        </work_policy>
        """
        let sections = PromptText.sections(in: text)
        let names = sections.map(\.name)
        XCTAssertEqual(names, ["mở đầu", "dangerous_actions", "work_policy"])
        let danger = sections.first { $0.name == "dangerous_actions" }!
        XCTAssertTrue(danger.preview.contains("Do not delete"))
        XCTAssertGreaterThan(danger.bytes, "Do not delete.".utf8.count)
        XCTAssertEqual(sections.reduce(0) { $0 + $1.bytes }, text.utf8.count)
    }

    func testSkillAndMcpCatalogs() {
        let skills = PromptText.skills(in: """
        The following skills are available for use:

        - alpha-skill: Reads the repo.
          Use when: looking around.
          Absolute path: /Users/me/.grok/skills/alpha-skill/SKILL.md
        - beta: Second skill.
          Absolute path: /Users/me/project/skills/beta/SKILL.md
        """)
        XCTAssertEqual(skills.map(\.name), ["alpha-skill", "beta"])
        XCTAssertEqual(skills[0].origin, "user")
        XCTAssertEqual(skills[1].origin, "project")
        XCTAssertGreaterThan(skills[0].catalogBytes, 0)

        let servers = PromptText.mcpServers(in: """
        MCP servers connected:
        - context7 (2 tools): Docs for libraries.
        - cursor (3 tools): Editor tools.

        MCP servers that failed to connect:
        - browseros-neo ("handshake failed")
        - cloudflare-api (auth required)
        """)
        XCTAssertEqual(servers.map(\.name), ["context7", "cursor", "browseros-neo", "cloudflare-api"])
        XCTAssertEqual(servers[0].status, "connected")
        XCTAssertEqual(servers[0].toolCount, 2)
        XCTAssertEqual(servers[2].status, "failed")
        XCTAssertEqual(servers[3].status, "auth")
        XCTAssertGreaterThan(servers[0].catalogBytes, 0)
    }

    func testGrokSessionBudget() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDir = root.appendingPathComponent("skills/alpha-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try "full skill body".write(to: skillFile, atomically: true, encoding: .utf8)
        let skillPath = skillFile.path

        let session = root.appendingPathComponent("grok/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let system = """
        You are a test agent. See the <user_query> tag.

        <dangerous_actions>
        Do not delete.
        </dangerous_actions>
        """
        try system.write(to: session.appendingPathComponent("system_prompt.txt"), atomically: true, encoding: .utf8)
        let tools: [[String: Any]] = [[
            "type": "function",
            "function": ["name": "read_file", "description": "Read a file", "parameters": ["type": "object"]],
        ]]
        try writeJSON(tools, session.appendingPathComponent("tool_definitions.json"))
        try writeJSONLines([
            ["type": "mcp_server_connected", "server_name": "context7", "tool_count": 2, "tools": ["resolve-library-id", "query-docs"]],
            ["type": "mcp_server_failed", "server_name": "cloudflare-api", "error_type": "auth_required"],
        ], session.appendingPathComponent("events.jsonl"))

        let rules = "<user_info>\nOS Version: macos\n</user_info>\n<user_rules>\nBe brief.\n</user_rules>"
        let skillReminder = """
        <system-reminder>
        The following skills are available for use:

        - alpha-skill: Reads the repo.
          Absolute path: \(skillPath)
        </system-reminder>
        """
        let mcpReminder = """
        <system-reminder>
        MCP servers connected:
        - context7 (2 tools): Docs for libraries.

        MCP servers that failed to connect:
        - cloudflare-api (auth required)
        </system-reminder>
        """
        let arguments = try JSONSerialization.data(withJSONObject: ["target_file": skillPath])
        let argumentText = String(decoding: arguments, as: UTF8.self)
        try writeJSONLines([
            ["type": "system", "content": system],
            ["type": "user", "content": rules],
            ["type": "user", "content": skillReminder, "synthetic_reason": "system_reminder"],
            ["type": "user", "content": mcpReminder, "synthetic_reason": "system_reminder"],
            ["type": "user", "content": "<user_query>phân tích session</user_query>"],
            ["type": "assistant", "content": "đang đọc", "tool_calls": [[
                "id": "c1", "name": "read_file", "arguments": argumentText,
            ]]],
            ["type": "tool_result", "tool_call_id": "c1", "content": "full skill body"],
        ], session.appendingPathComponent("chat_history.jsonl"))
        try writeJSON([
            "info": ["id": "sess", "cwd": "/Users/me/app"],
            "generated_title": "Phân tích",
            "current_model_id": "grok-4.7",
            "created_at": "2026-10-17T10:00:00Z",
            "updated_at": "2026-10-17T10:05:00Z",
        ], session.appendingPathComponent("summary.json"))

        let scan = LibraryScanner.scan(grokHome: root.appendingPathComponent("grok-home-missing"), kiroHome: root)
        _ = scan
        let ref = SessionRef(
            id: "grok:sess",
            source: .grok,
            sessionID: "sess",
            title: "Phân tích",
            cwd: "/Users/me/app",
            model: "grok-4.7",
            agent: nil,
            createdAt: nil,
            updatedAt: nil,
            locator: session.path,
            transcriptBytes: 1,
            isSubagent: false,
            isTemporary: false,
            contextPercent: nil,
            fingerprint: "x"
        )
        let report = SessionAnalyzer.report(for: ref)
        XCTAssertEqual(report.sections.map(\.name), ["mở đầu", "dangerous_actions"])
        XCTAssertEqual(report.skills.map(\.name), ["alpha-skill"])
        XCTAssertEqual(report.skills[0].readCount, 1)
        XCTAssertEqual(report.skills[0].diskBytes, "full skill body".utf8.count)
        XCTAssertEqual(report.mcp.first { $0.name == "context7" }?.status, "connected")
        XCTAssertEqual(report.mcp.first { $0.name == "context7" }?.tools, ["resolve-library-id", "query-docs"])
        XCTAssertEqual(report.mcp.first { $0.name == "cloudflare-api" }?.status, "auth")
        XCTAssertEqual(report.turns.map(\.preview), ["phân tích session"])
        XCTAssertEqual(report.tools.first { $0.name == "read_file" }?.calls, 1)
        XCTAssertGreaterThan(report.tools.first { $0.name == "read_file" }?.resultBytes ?? 0, 0)
        let kinds = Set(report.standing.map(\.kind))
        XCTAssertTrue(kinds.contains(.system))
        XCTAssertTrue(kinds.contains(.skills))
        XCTAssertTrue(kinds.contains(.mcp))
        XCTAssertTrue(kinds.contains(.rules))
        XCTAssertTrue(kinds.contains(.toolDefs))
        XCTAssertEqual(report.standing.first { $0.kind == .system }?.bytes, system.utf8.count)
    }

    func testKiroAndScanner() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let grokHome = root.appendingPathComponent("grok")
        let tmpGroup = grokHome.appendingPathComponent("sessions/tmpgroup/subagent-1", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpGroup, withIntermediateDirectories: true)
        try writeJSON([
            "info": ["id": "sub-1", "cwd": "/tmp/eval"],
            "generated_title": "sub",
            "updated_at": "2026-10-17T10:00:00Z",
        ], tmpGroup.appendingPathComponent("summary.json"))

        let workGroup = grokHome.appendingPathComponent("sessions/work/real", isDirectory: true)
        try FileManager.default.createDirectory(at: workGroup, withIntermediateDirectories: true)
        try writeJSON([
            "info": ["id": "real-1", "cwd": "/Users/me/app"],
            "generated_title": "Real work",
            "current_model_id": "grok-4.7",
            "updated_at": "2026-10-17T11:00:00Z",
        ], workGroup.appendingPathComponent("summary.json"))

        let kiroHome = root.appendingPathComponent("kiro")
        let ide = kiroHome.appendingPathComponent("sessions/ws/sess_abc", isDirectory: true)
        try FileManager.default.createDirectory(at: ide, withIntermediateDirectories: true)
        let agents = ide.appendingPathComponent("AGENTS.md")
        try "steer".write(to: agents, atomically: true, encoding: .utf8)
        let skill = root.appendingPathComponent("repo/skills/daily-report/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "daily".write(to: skill, atomically: true, encoding: .utf8)
        try writeJSON([
            "id": "sess_abc",
            "title": "Daily",
            "agentMode": "vibe",
            "modelId": "claude-sonnet-5.5",
            "workspacePaths": ["/Users/me/app"],
            "createdAt": "2026-10-07T20:15:14.328Z",
            "lastModifiedAt": "2026-10-08T01:56:58.182Z",
        ], ide.appendingPathComponent("session.json"))
        let agentURL = "file://\(agents.path)"
        try writeJSONLines([
            ["id": "s", "payload": ["type": "steering_inclusion", "documents": [agentURL]]],
            ["id": "u", "payload": ["type": "user", "content": "có skill daily report không?"]],
            ["id": "c", "payload": [
                "type": "tool_call",
                "toolCallId": "c1",
                "toolName": "read_file",
                "args": ["path": skill.path],
            ]],
            ["id": "r", "payload": ["type": "tool_result", "toolCallId": "c1", "content": "daily"]],
            ["id": "m", "payload": ["type": "session_metadata", "key": "contextUsage", "value": ["usagePercentage": 12.5]]],
        ], ide.appendingPathComponent("messages.jsonl"))

        let cli = kiroHome.appendingPathComponent("sessions/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        try writeJSON([
            "session_id": "cli-1",
            "cwd": "/Users/me/app",
            "created_at": "2026-10-05T18:16:28Z",
            "updated_at": "2026-10-05T18:20:00Z",
            "title": "Remove MCP backend",
            "session_created_reason": "user",
            "session_state": [
                "agent_name": "kiro_default",
                "conversation_metadata": ["last_context_usage": ["percentage": 26.5, "model_id": "auto"]],
                "rts_model_state": ["model_info": ["model_id": "auto", "context_window_tokens": 200000]],
            ],
        ], cli.appendingPathComponent("cli-1.json"))
        try writeJSONLines([
            ["version": "v1", "kind": "Prompt", "data": ["content": [["kind": "text", "data": "Remove the MCP backend"]]]],
            ["version": "v1", "kind": "AssistantMessage", "data": ["content": [
                ["kind": "text", "data": "I'll look."],
                ["kind": "toolUse", "data": ["toolUseId": "t1", "name": "shell", "input": ["command": "git status"]]],
            ]]],
            ["version": "v1", "kind": "ToolResults", "data": ["results": [
                "t1": ["tool": ["kind": "shell"], "result": ["Success": ["stdout": "clean"]]],
            ]]],
        ], cli.appendingPathComponent("cli-1.jsonl"))
        try Data().write(to: cli.appendingPathComponent("empty.json"))
        try Data().write(to: cli.appendingPathComponent("empty.jsonl"))
        try writeJSON([
            "session_id": "cli-sub",
            "cwd": "/Users/me/app",
            "title": "child",
            "session_created_reason": "subagent",
            "updated_at": "2026-10-05T18:20:00Z",
        ], cli.appendingPathComponent("cli-sub.json"))
        try writeJSONLines([
            ["version": "v1", "kind": "Prompt", "data": ["content": [["kind": "text", "data": "sub task"]]]],
        ], cli.appendingPathComponent("cli-sub.jsonl"))

        let scan = LibraryScanner.scan(grokHome: grokHome, kiroHome: kiroHome)
        XCTAssertEqual(scan.skippedEmptyCLI, 1)
        let byID = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID["sub-1"]?.isSubagent, true)
        XCTAssertEqual(byID["sub-1"]?.isTemporary, true)
        XCTAssertEqual(byID["real-1"]?.isNoise, false)
        XCTAssertEqual(byID["real-1"]?.model, "grok-4.7")
        XCTAssertEqual(byID["sess_abc"]?.source, .kiroIDE)
        XCTAssertEqual(byID["cli-1"]?.contextPercent ?? 0, 26.5, accuracy: 0.01)
        XCTAssertEqual(byID["cli-sub"]?.isSubagent, true)

        let ideReport = SessionAnalyzer.report(for: byID["sess_abc"]!)
        XCTAssertEqual(ideReport.steering.first?.bytes, "steer".utf8.count)
        XCTAssertEqual(ideReport.skills.first?.name, "daily-report")
        XCTAssertEqual(ideReport.skills.first?.readCount, 1)
        XCTAssertEqual(ideReport.contextPercent ?? 0, 12.5, accuracy: 0.01)
        XCTAssertEqual(ideReport.turns.first?.preview, "có skill daily report không?")
        XCTAssertEqual(ideReport.tools.first { $0.name == "read_file" }?.resultBytes, "daily".utf8.count)

        let cliReport = SessionAnalyzer.report(for: byID["cli-1"]!)
        XCTAssertEqual(cliReport.contextWindow, 200000)
        XCTAssertEqual(cliReport.tools.first { $0.name == "shell" }?.calls, 1)
        XCTAssertGreaterThan(cliReport.tools.first { $0.name == "shell" }?.resultBytes ?? 0, 0)
        XCTAssertEqual(cliReport.turns.first?.preview, "Remove the MCP backend")
        XCTAssertTrue(cliReport.notes.contains { $0.contains("200000") })
    }

    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("promptscope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSON(_ object: Any, _ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)
    }

    private func writeJSONLines(_ rows: [Any], _ url: URL) throws {
        let lines = try rows.map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row)
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
