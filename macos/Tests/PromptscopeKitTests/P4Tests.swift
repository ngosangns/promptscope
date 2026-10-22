import Foundation
import XCTest
import PromptscopeKit

/// Contract coverage for sessions, scan --json, report flags, and the skill.
/// Every library path is under a temp directory. These tests do not read the real home.
final class P4Tests: XCTestCase {
    private let secret = "zz-transcript-secret"
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T00:00:00Z")!

    func testScanTextAndJSON() throws {
        let env = try makeLibrary()
        let text = try exitOK(["scan"], env)
        XCTAssertEqual(
            text,
            """
            sessions 9
              Grok 2
              Kiro 1
              Kiro CLI 1
              OMP 1
              Pi 2
              Devin 1
              DSH 1
            empty cli skipped 1

            """
        )
        let json = try exitOK(["scan", "--json"], env)
        let object = try SchemaValidator.object(json)
        try SchemaValidator.validate(object, schema: try schema("scan"))
        XCTAssertEqual(object["sessions"] as? Int, 9)
        XCTAssertEqual(object["skippedEmptyCli"] as? Int, 1)
        let bySource = try XCTUnwrap(object["bySource"] as? [String: Any])
        XCTAssertEqual(bySource["grok"] as? Int, 2)
        XCTAssertEqual(bySource["pi"] as? Int, 2)
        XCTAssertEqual(bySource["dsh"] as? Int, 1)
        try assertGolden("scan.json", json)
    }

    func testSessionIDsMatchTheWindowFormat() throws {
        let env = try makeLibrary()
        let json = try exitOK(["sessions", "list", "--json", "--include-subagents", "--include-temporary"], env)
        let object = try SchemaValidator.object(json)
        try SchemaValidator.validate(object, schema: try schema("sessions-list"))
        let rows = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        let ids = rows.compactMap { $0["id"] as? String }
        // promptscope-gpui scan.rs builds the same strings:
        // grok:{id}, kiro-ide:{id}, kiro-cli:{file stem}, omp:{id}, pi:{id}, devin:{session_id}, dsh:{id}.
        XCTAssertEqual(
            ids,
            [
                "pi:psub",
                "devin:d1",
                "grok:gt",
                "grok:g1",
                "pi:p1",
                "kiro-ide:k1",
                "kiro-cli:c1",
                "omp:o1",
                "dsh:s1",
            ]
        )
        let encoded = json
        XCTAssertFalse(encoded.contains(secret), "sessions list must not include transcript text")
        for row in rows {
            XCTAssertNotNil(row["title"] as? String)
            XCTAssertFalse((row["title"] as? String ?? "").contains(secret))
        }
        try assertGolden("sessions-list.json", canonicalize(json, env))
    }

    func testSessionListFiltersAndText() throws {
        let env = try makeLibrary()
        let plain = try exitOK(["sessions", "list"], env)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.filter { !$0.isEmpty }.count, 7)
        XCTAssertTrue(lines[0].hasPrefix("devin:d1\t"))
        XCTAssertFalse(plain.contains(secret))
        XCTAssertFalse(plain.contains("pi:psub"))
        XCTAssertFalse(plain.contains("grok:gt"))

        let one = try SchemaValidator.object(try exitOK(["sessions", "list", "--limit", "1", "--json"], env))
        let oneRows = try XCTUnwrap(one["sessions"] as? [[String: Any]])
        XCTAssertEqual(oneRows.map { $0["id"] as? String }, ["devin:d1"])

        let pi = try SchemaValidator.object(try exitOK(["sessions", "list", "--source", "pi", "--json"], env))
        XCTAssertEqual((pi["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["pi:p1"])

        let cwd = try SchemaValidator.object(try exitOK(["sessions", "list", "--cwd", "/work/pi", "--json", "--include-subagents"], env))
        XCTAssertEqual(
            (cwd["sessions"] as? [[String: Any]])?.map { $0["id"] as? String },
            ["pi:psub", "pi:p1"]
        )

        let query = try SchemaValidator.object(try exitOK(["sessions", "list", "--query", "gRoK tItLe", "--json"], env))
        XCTAssertEqual((query["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["grok:g1"])
        let missed = try SchemaValidator.object(try exitOK(["sessions", "list", "--query", secret, "--json", "--include-subagents", "--include-temporary"], env))
        XCTAssertEqual((missed["sessions"] as? [[String: Any]])?.count, 0)

        let since = try SchemaValidator.object(try exitOK(["sessions", "list", "--since", "1d", "--json"], env))
        XCTAssertEqual((since["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["devin:d1"])

        let subs = try SchemaValidator.object(try exitOK(["sessions", "list", "--include-subagents", "--json", "--source", "pi"], env))
        XCTAssertEqual((subs["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["pi:psub", "pi:p1"])
        let temps = try SchemaValidator.object(try exitOK(["sessions", "list", "--include-temporary", "--json", "--source", "grok"], env))
        XCTAssertEqual((temps["sessions"] as? [[String: Any]])?.map { $0["id"] as? String }, ["grok:gt", "grok:g1"])
    }

    func testSessionShowAndReportFlags() throws {
        let env = try makeLibrary()
        let shown = try exitOK(["sessions", "show", "grok:g1", "--json"], env)
        let show = try SchemaValidator.object(shown)
        try SchemaValidator.validate(show, schema: try schema("sessions-show"))
        let session = try XCTUnwrap(show["session"] as? [String: Any])
        XCTAssertEqual(session["id"] as? String, "grok:g1")
        XCTAssertEqual(session["title"] as? String, "Grok title")
        let summary = try XCTUnwrap(show["summary"] as? [String: Any])
        XCTAssertEqual(summary["estimatedTokens"] as? Int, (summary["standingBytes"] as? Int ?? -1) / 4)
        XCTAssertFalse(shown.contains(secret))
        try assertGolden("sessions-show.json", canonicalize(shown, env))

        let missing = try exitCode(["sessions", "show", "grok:missing", "--json"], env)
        XCTAssertEqual(missing.code, 3)
        XCTAssertEqual(missing.stderr, "")
        try SchemaValidator.validate(try SchemaValidator.object(missing.stdout), schema: try schema("error"))

        let grokPath = env.roots.grok
            .appendingPathComponent("sessions/group/g1")
            .path
        let window = try exitOK(["report", "grok:g1", grokPath, "--json"], env)
        let report = try SchemaValidator.object(window)
        try SchemaValidator.validate(report, schema: try schema("report"))
        XCTAssertTrue(window.contains(secret))
        XCTAssertEqual(Set(report.keys), [
            "standing", "transcript", "sections", "skills", "mcp", "tools", "turns",
            "heavy", "steering", "notes", "contextPercent", "contextWindow", "promptTokens",
            "truncated", "entries",
        ])
        let lookedUp = try exitOK(["report", "grok:g1", "--json"], env)
        XCTAssertEqual(try canonical(try SchemaValidator.object(lookedUp)), try canonical(report))

        let redacted = try exitOK(["report", "grok:g1", "--no-text", "--json"], env)
        let redactedObject = try SchemaValidator.object(redacted)
        try SchemaValidator.validate(redactedObject, schema: try schema("report-redacted"))
        XCTAssertFalse(redacted.contains(secret))
        let entries = try XCTUnwrap(redactedObject["entries"] as? [[String: Any]])
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.allSatisfy { $0["label"] is NSNull })
        let turns = try XCTUnwrap(redactedObject["turns"] as? [[String: Any]])
        XCTAssertTrue(turns.allSatisfy { $0["preview"] is NSNull })
        let tools = try XCTUnwrap(redactedObject["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["alpha", "zeta"])

        let summaryJSON = try exitOK(["report", "grok:g1", "--summary", "--json"], env)
        let summaryObject = try SchemaValidator.object(summaryJSON)
        try SchemaValidator.validate(summaryObject, schema: try schema("report-summary"))
        XCTAssertFalse(summaryJSON.contains(secret))
        XCTAssertEqual(summaryObject["estimatedTokens"] as? Int, (summaryObject["standingBytes"] as? Int ?? -1) / 4)

        let section = try exitOK(["report", "grok:g1", "--section", "notes,standing", "--section", "notes", "--json"], env)
        let sectionObject = try SchemaValidator.object(section)
        try SchemaValidator.validate(sectionObject, schema: try schema("report-section"))
        XCTAssertEqual(Set(sectionObject.keys), ["notes", "standing"])

        let fullSize = window.utf8.count
        let fitted = try exitOK(["report", "grok:g1", "--json", "--max-bytes", "400"], env)
        let fittedObject = try SchemaValidator.object(fitted)
        try SchemaValidator.validate(fittedObject, schema: try schema("report"))
        XCTAssertEqual(fittedObject["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual(fitted.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count, 400)
        XCTAssertGreaterThan(fullSize, 400)

        let plain = try exitOK(["report", "grok", grokPath], env)
        XCTAssertFalse(plain.hasPrefix("{"))
        XCTAssertTrue(plain.contains("Grok title") || plain.contains("g1"))
    }

    func testPiToolsAreStable() throws {
        let env = try makeLibrary()
        let pi = env.roots.pi.appendingPathComponent("agent/sessions/proj/p1.jsonl")
        let ref = SessionRef(
            id: "pi:p1", source: .pi, sessionID: "p1", title: "Pi title", cwd: "/work/pi",
            model: "pi-model", agent: nil, createdAt: nil, updatedAt: nil, locator: pi.path,
            transcriptBytes: 1, isSubagent: false, isTemporary: false, contextPercent: nil, fingerprint: "x"
        )
        let first = SessionAnalyzer.report(for: ref).tools.map(\.name)
        let second = SessionAnalyzer.report(for: ref).tools.map(\.name)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, ["zebra", "alpha", "mid"])
    }

    func testExitCodes() throws {
        let env = try makeLibrary()
        let usage = try exitCode(["sessions", "list", "--nope", "--json"], env)
        XCTAssertEqual(usage.code, 2)
        XCTAssertEqual(usage.stderr, "")
        try SchemaValidator.validate(try SchemaValidator.object(usage.stdout), schema: try schema("error"))

        let badSince = try exitCode(["sessions", "list", "--since", "later"], env)
        XCTAssertEqual(badSince.code, 2)
        XCTAssertTrue(badSince.stderr.contains("promptscope:"))

        let missingFile = try exitCode(["report", "devin", "/tmp/promptscope-does-not-exist.json", "--json"], env)
        XCTAssertEqual(missingFile.code, 3)
        let missingError = try XCTUnwrap((try SchemaValidator.object(missingFile.stdout)["error"] as? [String: Any]))
        XCTAssertEqual(missingError["code"] as? String, "unavailable")
        XCTAssertEqual(missingError["exit"] as? Int, 3)

        let missingText = try exitCode(["report", "grok", "/tmp/promptscope-does-not-exist"], env)
        XCTAssertEqual(missingText.code, 3)
        XCTAssertEqual(missingText.stdout, "")
        XCTAssertTrue(missingText.stderr.hasPrefix("promptscope: session file not found:"))

        let bad = env.roots.devin.appendingPathComponent("cli/transcripts/bad.json")
        try "this is not json\n".write(to: bad, atomically: true, encoding: .utf8)
        let protocolError = try exitCode(["report", "devin", bad.path, "--json"], env)
        XCTAssertEqual(protocolError.code, 4)
        let protocolBody = try XCTUnwrap((try SchemaValidator.object(protocolError.stdout)["error"] as? [String: Any]))
        XCTAssertEqual(protocolBody["code"] as? String, "protocol")
        XCTAssertEqual(protocolBody["exit"] as? Int, 4)

        let both = try exitCode(["report", "grok:g1", "--summary", "--section", "tools", "--json"], env)
        XCTAssertEqual(both.code, 2)
        let unknownSection = try exitCode(["report", "grok:g1", "--section", "nope"], env)
        XCTAssertEqual(unknownSection.code, 2)
    }

    func testSkillInstallAndCheck() throws {
        let env = try makeLibrary()
        let dest = env.roots.grok.deletingLastPathComponent().appendingPathComponent("skill-dest")
        let dry = try exitOK(["skill", "install", "--dest", dest.path, "--dry-run", "--json"], env)
        let dryObject = try SchemaValidator.object(dry)
        try SchemaValidator.validate(dryObject, schema: try schema("skill-install"))
        XCTAssertEqual(dryObject["dryRun"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        let installed = try exitOK(["skill", "install", "--dest", dest.path, "--json"], env)
        let installedObject = try SchemaValidator.object(installed)
        try SchemaValidator.validate(installedObject, schema: try schema("skill-install"))
        XCTAssertEqual(installedObject["dryRun"] as? Bool, false)
        XCTAssertEqual(installedObject["files"] as? [String], ["SKILL.md"])
        let onDisk = try String(contentsOf: dest.appendingPathComponent("SKILL.md"), encoding: .utf8)
        XCTAssertEqual(onDisk, EmbeddedSkill.files["SKILL.md"])

        let check = try exitOK(["skill", "check", "--dest", dest.path, "--json"], env)
        let checkObject = try SchemaValidator.object(check)
        try SchemaValidator.validate(checkObject, schema: try schema("skill-check"))
        XCTAssertEqual(checkObject["inSync"] as? Bool, true)

        try "drift\n".write(to: dest.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "extra\n".write(to: dest.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        let drift = try exitCode(["skill", "check", "--dest", dest.path, "--json"], env)
        XCTAssertEqual(drift.code, 8)
        let driftObject = try SchemaValidator.object(drift.stdout)
        try SchemaValidator.validate(driftObject, schema: try schema("skill-check"))
        XCTAssertEqual(driftObject["inSync"] as? Bool, false)
        XCTAssertEqual(driftObject["different"] as? [String], ["SKILL.md"])
        XCTAssertEqual(driftObject["extra"] as? [String], ["extra.txt"])

        let absent = dest.appendingPathComponent("missing")
        let missing = try exitCode(["skill", "check", "--dest", absent.path, "--json"], env)
        XCTAssertEqual(missing.code, 3)
        try SchemaValidator.validate(try SchemaValidator.object(missing.stdout), schema: try schema("error"))
    }

    func testCommandsInTheSkillAreInTheSchema() throws {
        let skill = try XCTUnwrap(EmbeddedSkill.files["SKILL.md"])
        let catalog = try exitOK(["schema", "--json"], try makeLibrary())
        let commands = try XCTUnwrap((try SchemaValidator.object(catalog)["commands"] as? [String: Any])?.keys)
        let pattern = try NSRegularExpression(pattern: "promptscope ([a-z]+)(?: ([a-z]+))?")
        let ns = skill as NSString
        let matches = pattern.matches(in: skill, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        for match in matches {
            let first = ns.substring(with: match.range(at: 1))
            let name: String
            if match.range(at: 2).location != NSNotFound {
                name = first + " " + ns.substring(with: match.range(at: 2))
            } else {
                name = first
            }
            seen.insert(name)
        }
        XCTAssertTrue(seen.contains("sessions list"))
        XCTAssertTrue(seen.contains("report"))
        for name in seen {
            XCTAssertTrue(commands.contains(name), name)
        }
    }

    private func exitOK(_ args: [String], _ environment: PromptscopeEnvironment) throws -> String {
        let result = try exitCode(args, environment)
        XCTAssertEqual(result.code, 0, result.stderr + result.stdout)
        XCTAssertEqual(result.stderr, "")
        return result.stdout
    }

    private func exitCode(_ args: [String], _ environment: PromptscopeEnvironment) throws -> (code: Int32, stdout: String, stderr: String) {
        guard case .exit(let code, let stdout, let stderr) = PromptscopeDispatch.dispatch(args, releaseVersion: "0.0.0-dev", environment: environment) else {
            XCTFail("\(args) did not exit")
            return (1, "", "")
        }
        return (code, stdout, stderr)
    }

    private func schema(_ name: String) throws -> String {
        try XCTUnwrap(EmbeddedSchemas.text(named: name))
    }

    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func assertGolden(_ name: String, _ actual: String) throws {
        let url = fixture("contract/\(name)")
        if ProcessInfo.processInfo.environment["PROMPTSCOPE_WRITE_GOLDEN"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(actual, expected, name)
    }

    private func canonicalize(_ text: String, _ environment: PromptscopeEnvironment) -> String {
        let base = environment.roots.grok.deletingLastPathComponent()
        var roots = [base.resolvingSymlinksInPath().path, base.standardizedFileURL.path, base.path]
        // Directory listings resolve `/var` to `/private/var`. URL standardization on this OS does not.
        for root in roots where root.hasPrefix("/var/") {
            roots.append("/private" + root)
        }
        // Longest first: `/private/var/...` contains `/var/...`, and replacing the short form first leaves `/private`.
        let ordered = Array(Set(roots)).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        return ordered.reduce(text) { partial, root in
            partial.replacingOccurrences(of: root, with: "/fixture")
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func makeLibrary() throws -> PromptscopeEnvironment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptscope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("grok")
        let kiro = root.appendingPathComponent("kiro")
        let omp = root.appendingPathComponent("omp")
        let pi = root.appendingPathComponent("pi")
        let devin = root.appendingPathComponent("devin")
        let dsh = root.appendingPathComponent("dsh")

        let grokSession = grok.appendingPathComponent("sessions/group/g1")
        try write(grokSession.appendingPathComponent("summary.json"), """
        {"generated_title":"Grok title","created_at":"2026-10-20T00:00:00Z","updated_at":"2026-10-21T00:00:00Z","current_model_id":"grok-test","agent_name":"builder","info":{"id":"g1","cwd":"/work/grok"}}
        """)
        try write(grokSession.appendingPathComponent("system_prompt.txt"), "You are a test agent.\n")
        try write(grokSession.appendingPathComponent("tool_definitions.json"), """
        [{"type":"function","function":{"name":"zeta","description":"z"}},{"type":"function","function":{"name":"alpha","description":"aa"}}]
        """)
        try write(grokSession.appendingPathComponent("chat_history.jsonl"), """
        {"type":"user","content":"<user_query>\(secret)</user_query>"}
        """)
        let temp = grok.appendingPathComponent("sessions/group/gt")
        try write(temp.appendingPathComponent("summary.json"), """
        {"generated_title":"Temp title","updated_at":"2026-10-22T00:00:00Z","info":{"id":"gt","cwd":"/tmp/scratch"}}
        """)

        let kiroSession = kiro.appendingPathComponent("sessions/ws/sess_k1")
        try write(kiroSession.appendingPathComponent("session.json"), """
        {"id":"k1","title":"Kiro title","workspacePaths":["/work/kiro"],"modelId":"kiro-model","agentMode":"vibe","createdAt":"2026-10-19T00:00:00Z","lastModifiedAt":"2026-10-20T00:00:00Z"}
        """)
        try write(kiroSession.appendingPathComponent("messages.jsonl"), "{\"type\":\"user\"}\n")
        try write(kiro.appendingPathComponent("sessions/cli/c1.json"), """
        {"title":"Kiro cli","cwd":"/work/kiro-cli","created_at":"2026-10-18T00:00:00Z","updated_at":"2026-10-19T00:00:00Z"}
        """)
        try write(kiro.appendingPathComponent("sessions/cli/c1.jsonl"), "{\"kind\":\"Prompt\",\"data\":{\"content\":\"cli prompt\"}}\n")
        try write(kiro.appendingPathComponent("sessions/cli/empty.json"), "{}\n")

        try write(omp.appendingPathComponent("agent/sessions/proj/o1.jsonl"), """
        {"type":"session","id":"o1","cwd":"/work/omp","timestamp":"2026-10-18T00:00:00Z"}
        {"type":"title","title":"Omp title","updatedAt":"2026-10-18T00:00:00Z"}
        {"type":"message","message":{"role":"user","content":"omp hello"}}
        """)
        try write(pi.appendingPathComponent("agent/sessions/proj/p1.jsonl"), """
        {"type":"session","id":"p1","cwd":"/work/pi","timestamp":"2026-10-20T00:00:00Z"}
        {"type":"model_change","model":"pi-model"}
        {"type":"title","title":"Pi title","updatedAt":"2026-10-20T12:00:00Z"}
        {"type":"message","message":{"role":"system","sections":{"preamble":"be brief"},"toolsAdded":[{"name":"zebra"},{"name":"alpha"},{"name":"mid"}]}}
        {"type":"message","timestamp":"2026-10-20T12:00:01Z","message":{"role":"user","content":[{"type":"text","text":"hello pi"}]}}
        {"type":"message","timestamp":"2026-10-20T12:00:02Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"1","name":"zebra","arguments":{}},{"type":"toolCall","id":"2","name":"zebra","arguments":{}},{"type":"toolCall","id":"3","name":"alpha","arguments":{}},{"type":"toolCall","id":"4","name":"mid","arguments":{}}]}}
        """)
        try write(pi.appendingPathComponent("agent/sessions/proj/child/psub.jsonl"), """
        {"type":"session","id":"psub","cwd":"/work/pi/child","timestamp":"2026-10-23T12:00:00Z"}
        {"type":"title","title":"Pi sub","updatedAt":"2026-10-23T12:00:00Z"}
        {"type":"message","message":{"role":"user","content":"sub"}}
        """)

        try write(devin.appendingPathComponent("cli/transcripts/d1.json"), """
        {"session_id":"d1","agent":{"name":"devin","model_name":"devin-model"},"steps":[{"source":"user","timestamp":"2026-10-23T00:00:00Z","message":"devin please"},{"source":"agent","timestamp":"2026-10-23T00:00:00Z","message":"ok"}]}
        """)
        let dshLog = dsh.appendingPathComponent("sessions/proj/s1/session.v4.jsonl")
        try write(dshLog, """
        {"type":"session","version":4,"id":"s1","cwd":"/work/dsh","createdAt":1760630400000}
        {"type":"turn/start","data":{}}
        {"type":"user/message","data":{"content":[{"type":"text","text":"dsh hi"}],"source":{"kind":"user"}}}
        """)
        let stamp = ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")!
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: dshLog.path)

        return PromptscopeEnvironment(
            roots: LibraryRoots(grok: grok, kiro: kiro, omp: omp, pi: pi, devin: devin, dsh: dsh),
            skillDirectory: root.appendingPathComponent("unused-skill"),
            now: now
        )
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
