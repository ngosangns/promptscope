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

        let missing = root.appendingPathComponent("missing")
        let scan = LibraryScanner.scan(
            grokHome: root.appendingPathComponent("grok-home-missing"),
            kiroHome: root,
            ompHome: missing,
            piHome: missing,
            devinHome: missing,
            dshHome: missing
        )
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

        let missing = root.appendingPathComponent("missing-agents")
        let scan = LibraryScanner.scan(
            grokHome: grokHome,
            kiroHome: kiroHome,
            ompHome: missing,
            piHome: missing,
            devinHome: missing,
            dshHome: missing
        )
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

    func testPiOmpAndDevin() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = root.appendingPathComponent(".pi/agent/skills/alpha-skill/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "skill body".write(to: skill, atomically: true, encoding: .utf8)

        let piDir = root.appendingPathComponent("pi/agent/sessions/--proj--", isDirectory: true)
        try FileManager.default.createDirectory(at: piDir, withIntermediateDirectories: true)
        let piFile = piDir.appendingPathComponent("sess.jsonl")
        try writeJSONLines([
            ["type": "session", "id": "pi-1", "timestamp": "2026-10-04T07:19:44Z", "cwd": "/Users/me/app"],
            ["type": "model_change", "modelId": "swe-2"],
            ["type": "message", "message": [
                "role": "system",
                "content": "",
                "sections": [
                    "preamble": "You are pi.",
                    "tools": "<tools>\n- read: Read\n</tools>",
                    "rules": "<rules>\nBe brief.\n</rules>",
                    "skills": """
                    <skills>
                    <skill>
                    <name>alpha-skill</name>
                    <description>Reads things.</description>
                    <location>\(skill.path)</location>
                    </skill>
                    </skills>
                    """,
                    "mcp_servers": "<mcp_servers>\n- mcp__browseros_neo (codemode): Browser for agents.\n</mcp_servers>",
                    "cwd": "<cwd>\n/Users/me/app\n</cwd>",
                ],
                "toolsAdded": [["name": "read", "description": "Read a file"]],
            ]],
            ["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "đọc skill"]]]],
            ["type": "message", "message": [
                "role": "assistant",
                "content": [[
                    "type": "toolCall",
                    "name": "read",
                    "arguments": ["path": skill.path],
                ]],
                "usage": ["input": 100, "cacheRead": 50, "output": 10, "totalTokens": 160],
            ]],
        ], piFile)

        let ompDir = root.appendingPathComponent("omp/agent/sessions/-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: ompDir, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "title", "title": "Sửa daemon", "updatedAt": "2026-10-08T08:40:00Z"],
            ["type": "session", "id": "omp-1", "timestamp": "2026-10-08T08:36:39Z", "cwd": "/Users/me/app"],
            ["type": "model_change", "model": "kiro/claude"],
            ["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "sửa daemon"]]]],
            ["type": "message", "message": [
                "role": "assistant",
                "content": [["type": "toolCall", "name": "read", "arguments": ["path": skill.path]]],
                "usage": [
                    "input": 20000, "cacheRead": 0, "output": 10, "totalTokens": 20010,
                    "contextPercent": 10.0,
                ],
                "contextSnapshot": ["promptTokens": 20000, "nonMessageTokens": 1500],
            ]],
        ], ompDir.appendingPathComponent("main.jsonl"))
        let childDir = ompDir.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "session", "id": "omp-child", "timestamp": "2026-10-08T08:41:00Z", "cwd": "/Users/me/app"],
            ["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "sub task"]]]],
        ], childDir.appendingPathComponent("child.jsonl"))

        let devinDir = root.appendingPathComponent("devin/cli/transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: devinDir, withIntermediateDirectories: true)
        try writeJSON([
            "schema_version": "ATIF-v1.7",
            "session_id": "calm-session",
            "agent": [
                "name": "devin",
                "model_name": "SWE-2 High",
                "tool_definitions": [[
                    "type": "function",
                    "function": ["name": "skill", "description": "Invoke a skill"],
                ]],
            ],
            "steps": [
                [
                    "step_id": 1, "source": "system", "timestamp": "2026-10-15T16:24:38Z",
                    "message": "You are Devin, an interactive command line agent.",
                    "extra": ["telemetry": ["source": "sysprompt", "operation": "normal"]],
                ],
                [
                    "step_id": 2, "source": "system", "timestamp": "2026-10-15T16:24:39Z",
                    "message": """
                    ## Available MCP Servers
                    {"servers":[{"name":"context7","description":"Docs for libraries."}]}
                    """,
                ],
                [
                    "step_id": 3, "source": "system", "timestamp": "2026-10-15T16:24:40Z",
                    "message": """
                    <available_skills>
                    - **alpha-skill**: Reads the repo.
                    - **daily-report**: Writes the report.
                    </available_skills>
                    """,
                ],
                [
                    "step_id": 4, "source": "user", "timestamp": "2026-10-15T16:25:00Z",
                    "message": "dùng skill alpha",
                ],
                [
                    "step_id": 5, "source": "agent", "timestamp": "2026-10-15T16:25:10Z",
                    "message": "Đang mở skill.",
                    "metrics": ["prompt_tokens": 4321, "completion_tokens": 20],
                    "tool_calls": [[
                        "tool_call_id": "c1",
                        "function_name": "skill",
                        "arguments": ["name": "alpha-skill"],
                    ]],
                    "observation": ["results": [["source_call_id": "c1", "content": "skill body"]]],
                ],
            ],
        ], devinDir.appendingPathComponent("calm-session.json"))

        let dshDir = root.appendingPathComponent(
            "dsh/sessions/--Users-me-app--/session-dsh-1", isDirectory: true
        )
        try FileManager.default.createDirectory(at: dshDir, withIntermediateDirectories: true)
        try writeJSONLines([
            [
                "type": "session", "version": 4, "id": "session-dsh-1",
                "createdAt": 1_792_474_601_407.0, "cwd": "/Users/me/app",
                "delegationDepth": 0, "agentPreset": "standard",
            ],
            ["type": "turn/start", "time": 1_792_477_539_414.0, "data": ["turn": 1]],
            ["type": "system/message", "data": ["message": [
                "role": "system", "content": [["type": "text", "text": "You are an AI agent powered by DeepSeek Harness."]],
            ]]],
            ["type": "user/message", "time": 1_792_477_539_468.0, "data": [
                "content": [["type": "text", "text": "đo session này"]],
                "source": ["kind": "user"], "role": "user",
            ]],
            ["type": "user/message", "data": [
                "content": [["type": "text", "text": "Follow AGENTS.md."]],
                "source": ["kind": "agent-instructions", "form": "instructions"], "role": "user",
            ]],
            ["type": "user/message", "data": [
                "content": [["type": "text", "text": """
                <available_skills>
                - `alpha-skill`: Reads the repo.
                - `daily-report`: Writes the report.
                </available_skills>
                """]],
                "source": ["kind": "skill-catalog", "form": "catalog"], "role": "user",
            ]],
            ["type": "user/message", "data": [
                "content": [["type": "text", "text": "Current working directory: /Users/me/app"]],
                "source": ["kind": "runtime-context", "form": "snapshot"], "role": "user",
            ]],
            ["type": "request/header", "data": ["header": [
                "config": ["provider": "grok", "model": "grok-4.7"],
                "tools": [
                    ["name": "bash", "description": "Run a command"],
                    ["name": "mcp__context7__resolve", "description": "Resolve a library"],
                    ["name": "mcp__context7__query", "description": "Query docs"],
                ],
            ], "reason": "initial"]],
            ["type": "request/context", "data": [
                "provider": "grok", "model": "grok-4.7", "contextWindow": 500_000,
            ]],
            ["type": "tool/call", "time": 1_792_477_540_000.0, "data": [
                "callId": "c1", "name": "bash", "arguments": "{\"command\":\"ls\"}",
            ]],
            ["type": "tool/result", "time": 1_792_477_541_000.0, "data": ["message": [
                "toolCallId": "c1", "content": [["type": "text", "text": "Cargo.toml"]], "isError": false,
            ]]],
            ["type": "assistant/message", "time": 1_792_477_542_037.0, "data": [
                "message": ["content": [
                    ["type": "reasoning", "text": "đang đo"],
                    ["type": "text", "text": "xong"],
                ]],
                "usage": ["inputTokens": 21_206, "outputTokens": 68],
            ]],
            ["type": "compaction/prune", "data": ["shadowedTokenCount": 120]],
            ["type": "turn/end", "data": ["turn": 1]],
        ], dshDir.appendingPathComponent("session.v4.jsonl"))
        let dshChild = root.appendingPathComponent(
            "dsh/sessions/--Users-me-app--/session-dsh-child", isDirectory: true
        )
        try FileManager.default.createDirectory(at: dshChild, withIntermediateDirectories: true)
        try writeJSONLines([
            [
                "type": "session", "version": 4, "id": "session-dsh-child",
                "createdAt": 1_792_474_701_407.0, "cwd": "/tmp/job",
                "delegationDepth": 1, "agentPreset": "standard",
            ],
            ["type": "turn/start", "data": ["turn": 1]],
            ["type": "user/message", "data": [
                "content": [["type": "text", "text": "việc con"]],
                "source": ["kind": "user"], "role": "user",
            ]],
        ], dshChild.appendingPathComponent("session.v4.jsonl"))
        let dshOld = root.appendingPathComponent(
            "dsh/sessions/--Users-me-app--/session-dsh-old", isDirectory: true
        )
        try FileManager.default.createDirectory(at: dshOld, withIntermediateDirectories: true)
        try writeJSONLines([
            ["type": "session", "version": 3, "id": "session-dsh-old", "cwd": "/Users/me/app"],
            ["type": "turn/start", "data": ["turn": 1]],
        ], dshOld.appendingPathComponent("session.v3.jsonl"))

        let missing = root.appendingPathComponent("missing")
        let scan = LibraryScanner.scan(
            grokHome: missing, kiroHome: missing,
            ompHome: root.appendingPathComponent("omp"),
            piHome: root.appendingPathComponent("pi"),
            devinHome: root.appendingPathComponent("devin"),
            dshHome: root.appendingPathComponent("dsh")
        )
        let byID = Dictionary(uniqueKeysWithValues: scan.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID["pi-1"]?.source, .pi)
        XCTAssertEqual(byID["pi-1"]?.cwd, "/Users/me/app")
        XCTAssertEqual(byID["pi-1"]?.title, "đọc skill")
        XCTAssertEqual(byID["omp-1"]?.title, "Sửa daemon")
        XCTAssertEqual(byID["omp-1"]?.model, "kiro/claude")
        XCTAssertEqual(byID["omp-child"]?.isSubagent, true)
        XCTAssertEqual(byID["calm-session"]?.source, .devin)
        XCTAssertEqual(byID["calm-session"]?.model, "SWE-2 High")
        XCTAssertEqual(byID["calm-session"]?.title, "dùng skill alpha")

        let piReport = SessionAnalyzer.report(for: byID["pi-1"]!)
        XCTAssertEqual(piReport.skills.first?.name, "alpha-skill")
        XCTAssertEqual(piReport.skills.first?.origin, "user")
        XCTAssertEqual(piReport.skills.first?.readCount, 1)
        XCTAssertEqual(piReport.skills.first?.diskBytes, "skill body".utf8.count)
        XCTAssertEqual(piReport.mcp.first?.name, "browseros_neo")
        XCTAssertEqual(piReport.mcp.first?.status, "codemode")
        XCTAssertGreaterThan(piReport.standing.first { $0.kind == .system }?.bytes ?? 0, 0)
        XCTAssertGreaterThan(piReport.standing.first { $0.kind == .skills }?.bytes ?? 0, 0)
        XCTAssertEqual(piReport.promptTokens, 150)
        XCTAssertEqual(piReport.tools.first { $0.name == "read" }?.calls, 1)
        XCTAssertEqual(piReport.turns.first?.preview, "đọc skill")
        let piDigest = SessionAnalyzer.digest(for: byID["pi-1"]!)
        XCTAssertEqual(piDigest.promptTokens, 150)
        XCTAssertGreaterThan(piDigest.standingBytes, 0)

        let ompReport = SessionAnalyzer.report(for: byID["omp-1"]!)
        XCTAssertEqual(ompReport.standingBytes, 0)
        XCTAssertEqual(ompReport.skills.first?.name, "alpha-skill")
        XCTAssertEqual(ompReport.skills.first?.readCount, 1)
        XCTAssertEqual(ompReport.promptTokens, 20000)
        XCTAssertEqual(ompReport.contextPercent ?? 0, 10, accuracy: 0.01)
        XCTAssertEqual(ompReport.contextWindow, 200000)
        XCTAssertEqual(ompReport.sections.isEmpty, true)
        XCTAssertTrue(ompReport.notes.contains { $0.contains("không lưu") })

        let devinReport = SessionAnalyzer.report(for: byID["calm-session"]!)
        XCTAssertEqual(devinReport.skills.map(\.name), ["alpha-skill", "daily-report"])
        XCTAssertEqual(devinReport.skills.first?.readCount, 1)
        XCTAssertEqual(devinReport.mcp.first?.name, "context7")
        XCTAssertGreaterThan(devinReport.mcp.first?.catalogBytes ?? 0, 0)
        XCTAssertEqual(devinReport.promptTokens, 4321)
        XCTAssertGreaterThan(devinReport.standing.first { $0.kind == .system }?.bytes ?? 0, 0)
        XCTAssertGreaterThan(devinReport.standing.first { $0.kind == .toolDefs }?.bytes ?? 0, 0)
        XCTAssertEqual(devinReport.tools.first { $0.name == "skill" }?.calls, 1)
        XCTAssertEqual(devinReport.tools.first { $0.name == "skill" }?.resultBytes, "skill body".utf8.count)
        XCTAssertEqual(devinReport.turns.first?.preview, "dùng skill alpha")

        XCTAssertEqual(byID["session-dsh-1"]?.source, .dsh)
        XCTAssertEqual(byID["session-dsh-1"]?.cwd, "/Users/me/app")
        XCTAssertEqual(byID["session-dsh-1"]?.model, "grok-4.7")
        XCTAssertEqual(byID["session-dsh-1"]?.title, "đo session này")
        XCTAssertEqual(byID["session-dsh-1"]?.isSubagent, false)
        XCTAssertEqual(byID["session-dsh-child"]?.isSubagent, true)
        XCTAssertEqual(byID["session-dsh-child"]?.isTemporary, true)
        XCTAssertNil(byID["session-dsh-old"])

        let dshReport = SessionAnalyzer.report(for: byID["session-dsh-1"]!)
        XCTAssertEqual(dshReport.skills.map(\.name), ["alpha-skill", "daily-report"])
        XCTAssertEqual(dshReport.skills.first?.readCount, 0)
        XCTAssertNil(dshReport.skills.first?.diskBytes)
        XCTAssertEqual(dshReport.mcp.first?.name, "context7")
        XCTAssertEqual(dshReport.mcp.first?.tools, ["query", "resolve"])
        XCTAssertEqual(dshReport.promptTokens, 21_206)
        XCTAssertEqual(dshReport.contextWindow, 500_000)
        XCTAssertGreaterThan(dshReport.standing.first { $0.kind == .system }?.bytes ?? 0, 0)
        XCTAssertGreaterThan(dshReport.standing.first { $0.kind == .rules }?.bytes ?? 0, 0)
        XCTAssertGreaterThan(dshReport.standing.first { $0.kind == .skills }?.bytes ?? 0, 0)
        XCTAssertGreaterThan(dshReport.standing.first { $0.kind == .toolDefs }?.bytes ?? 0, 0)
        XCTAssertEqual(dshReport.tools.first { $0.name == "bash" }?.calls, 1)
        XCTAssertEqual(dshReport.tools.first { $0.name == "bash" }?.resultBytes, "Cargo.toml".utf8.count)
        XCTAssertEqual(dshReport.turns.first?.preview, "đo session này")
        XCTAssertEqual(dshReport.trajectory.map(\.kind), ["user", "tool", "assistant"])
        XCTAssertEqual(dshReport.trajectory.first { $0.kind == "tool" }?.label, "bash")
        XCTAssertNotNil(dshReport.trajectory.first?.at)
        XCTAssertEqual(dshReport.trajectory.first { $0.kind == "tool" }?.durationMs, 1000)
        XCTAssertEqual(dshReport.transcript.first { $0.kind == .reasoning }?.bytes, "đang đo".utf8.count)
        XCTAssertTrue(dshReport.notes.contains { $0.contains("120") })
        let dshDigest = SessionAnalyzer.digest(for: byID["session-dsh-1"]!)
        XCTAssertEqual(dshDigest.promptTokens, 21_206)
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
