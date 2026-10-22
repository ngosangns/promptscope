import CoreFoundation
import Foundation
import XCTest
import PromptscopeKit

/// Draft 2020-12 checks the contract tests need: type (including nullable type
/// arrays), enum, required, properties, additionalProperties, items, and `$ref`.
struct SchemaValidator {
    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    static func validate(_ instance: Any, schema schemaText: String) throws {
        let root = try object(schemaText)
        try validate(instance, schema: root, root: root, path: "$", depth: 0)
    }

    static func validate(_ instance: Any, schema: [String: Any], root: [String: Any]) throws {
        try validate(instance, schema: schema, root: root, path: "$", depth: 0)
    }

    private static func validate(
        _ instance: Any,
        schema: [String: Any],
        root: [String: Any],
        path: String,
        depth: Int
    ) throws {
        if depth > 32 {
            throw Failure(message: "\(path): schema nested too deep")
        }
        if let ref = schema["$ref"] as? String {
            let resolved = try resolve(ref, root: root, path: path)
            try validate(instance, schema: resolved, root: root, path: path, depth: depth + 1)
            let keywords: Set<String> = ["type", "enum", "properties", "required", "items", "additionalProperties"]
            if schema.keys.contains(where: { keywords.contains($0) }) {
                var local = schema
                local.removeValue(forKey: "$ref")
                try validate(instance, schema: local, root: root, path: path, depth: depth + 1)
            }
            return
        }
        if let types = typeNames(schema) {
            let matched = types.contains { matches($0, instance) }
            if !matched {
                throw Failure(message: "\(path): expected \(types.joined(separator: " or ")), got \(kind(of: instance))")
            }
        }
        if schema["enum"] != nil {
            guard let options = schema["enum"] as? [Any] else {
                throw Failure(message: "\(path): enum is not an array")
            }
            if !options.contains(where: { jsonEqual($0, instance) }) {
                throw Failure(message: "\(path): value not in enum")
            }
        }
        if let object = instance as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            if flag(schema, "additionalProperties") == false {
                let known = Set(properties.keys)
                for key in object.keys.sorted() where !known.contains(key) {
                    throw Failure(message: "\(path).\(key): unexpected property")
                }
            }
            for key in object.keys.sorted() {
                guard let child = properties[key] as? [String: Any] else { continue }
                try validate(object[key] as Any, schema: child, root: root, path: "\(path).\(key)", depth: depth + 1)
            }
            if let required = strings(schema["required"]) {
                for key in required where object[key] == nil {
                    throw Failure(message: "\(path).\(key): missing required property")
                }
            }
        }
        if let items = schema["items"] as? [String: Any], let array = instance as? [Any] {
            for (index, item) in array.enumerated() {
                try validate(item, schema: items, root: root, path: "\(path)[\(index)]", depth: depth + 1)
            }
        }
    }

    private static func resolve(_ ref: String, root: [String: Any], path: String) throws -> [String: Any] {
        guard ref.hasPrefix("#/") else {
            throw Failure(message: "\(path): unsupported ref \(ref)")
        }
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let object = node as? [String: Any], let next = object[String(part)] else {
                throw Failure(message: "\(path): unresolved \(ref)")
            }
            node = next
        }
        guard let schema = node as? [String: Any] else {
            throw Failure(message: "\(path): \(ref) is not an object")
        }
        return schema
    }

    private static func typeNames(_ schema: [String: Any]) -> [String]? {
        if let one = schema["type"] as? String { return [one] }
        return strings(schema["type"])
    }

    private static func strings(_ value: Any?) -> [String]? {
        if let list = value as? [String] { return list }
        guard let list = value as? [Any] else { return nil }
        var out: [String] = []
        for item in list {
            guard let text = item as? String else { return nil }
            out.append(text)
        }
        return out
    }

    private static func flag(_ schema: [String: Any], _ key: String) -> Bool? {
        guard let value = schema[key] else { return nil }
        if let bool = value as? Bool { return bool }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func matches(_ type: String, _ value: Any) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "boolean": return isBool(value)
        case "integer": return isInteger(value)
        case "number": return number(value) != nil
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func number(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber, !isBool(value) else { return nil }
        return number
    }

    private static func isInteger(_ value: Any) -> Bool {
        guard let number = number(value) else { return false }
        let magnitude = number.doubleValue
        return magnitude.isFinite && magnitude == magnitude.rounded()
    }

    private static func jsonEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull, rhs is NSNull { return true }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if isBool(lhs) || isBool(rhs) {
            guard isBool(lhs), isBool(rhs) else { return false }
            return (lhs as! NSNumber).boolValue == (rhs as! NSNumber).boolValue
        }
        if let left = number(lhs), let right = number(rhs) {
            return left.doubleValue == right.doubleValue
        }
        return false
    }

    private static func kind(of value: Any) -> String {
        if value is NSNull { return "null" }
        if isBool(value) { return "boolean" }
        if isInteger(value) { return "integer" }
        if number(value) != nil { return "number" }
        if value is String { return "string" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "other"
    }

    static func object(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw Failure(message: "JSON value is not an object")
        }
        return object
    }
}

final class ContractTests: XCTestCase {
    func testEmbeddedSchemasMatchFiles() throws {
        let directory = repoRoot().appendingPathComponent("schemas/v1")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let onDisk = try String(contentsOf: file, encoding: .utf8)
            let embedded = EmbeddedSchemas.text(named: name)
            XCTAssertEqual(
                embedded,
                onDisk,
                "\(name): EmbeddedSchemas does not match schemas/v1/\(name).json"
            )
            let parsed = try JSONSerialization.jsonObject(with: Data(onDisk.utf8))
            let object = try XCTUnwrap(parsed as? [String: Any])
            XCTAssertEqual(object["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        }
    }

    func testEmbeddedSkillMatchesRepo() throws {
        let directory = repoRoot().appendingPathComponent("skills/promptscope")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let name = file.lastPathComponent
            let onDisk = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(EmbeddedSkill.files[name], onDisk, name)
            if name == "SKILL.md" {
                XCTAssertLessThan(onDisk.split(separator: "\n", omittingEmptySubsequences: false).count, 150)
                XCTAssertTrue(onDisk.contains("name: promptscope"))
                XCTAssertTrue(onDisk.contains("description:"))
            }
        }
        XCTAssertEqual(Set(EmbeddedSkill.files.keys), Set(files.map(\.lastPathComponent)))
    }

    func testValidatorTypesEnumRequiredAndItems() throws {
        try SchemaValidator.validate(1, schema: #"{"type":"integer"}"#)
        try SchemaValidator.validate(1, schema: #"{"type":"number"}"#)
        try SchemaValidator.validate(1.5, schema: #"{"type":"number"}"#)
        try SchemaValidator.validate(NSNull(), schema: #"{"type":["integer","null"]}"#)
        XCTAssertThrowsError(try SchemaValidator.validate(true, schema: #"{"type":"integer"}"#))
        XCTAssertThrowsError(try SchemaValidator.validate(1.5, schema: #"{"type":"integer"}"#))
        XCTAssertThrowsError(try SchemaValidator.validate("1", schema: #"{"type":"integer"}"#))

        let objectSchema = """
        {"type":"object","additionalProperties":false,"required":["kind","bytes"],"properties":{"kind":{"enum":["user"]},"bytes":{"type":"integer"}}}
        """
        try SchemaValidator.validate(try SchemaValidator.object(#"{"kind":"user","bytes":2}"#), schema: objectSchema)
        XCTAssertThrowsError(try SchemaValidator.validate(try SchemaValidator.object(#"{"kind":"nope","bytes":2}"#), schema: objectSchema))
        XCTAssertThrowsError(try SchemaValidator.validate(try SchemaValidator.object(#"{"bytes":2}"#), schema: objectSchema))
        XCTAssertThrowsError(try SchemaValidator.validate(try SchemaValidator.object(#"{"kind":"user","bytes":2,"extra":true}"#), schema: objectSchema))

        let listSchema = #"{"type":"array","items":{"type":"string"}}"#
        let list = try JSONSerialization.jsonObject(with: Data(#"["a","b"]"#.utf8))
        try SchemaValidator.validate(list, schema: listSchema)
        let badList = try JSONSerialization.jsonObject(with: Data(#"["a",1]"#.utf8))
        XCTAssertThrowsError(try SchemaValidator.validate(badList, schema: listSchema))
    }

    func testVersionAndSchemaOutputs() throws {
        let version = "0.0.0-dev"
        let text = PromptscopeDispatch.dispatch(["version"], releaseVersion: version)
        let flagged = PromptscopeDispatch.dispatch(["--version"], releaseVersion: version)
        let short = PromptscopeDispatch.dispatch(["-V"], releaseVersion: version)
        XCTAssertEqual(text, .exit(code: 0, stdout: "promptscope \(version)\n", stderr: ""))
        XCTAssertEqual(flagged, text)
        XCTAssertEqual(short, text)
        // The legacy flag prints the text line and does not take --json.
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["--version", "--json"], releaseVersion: version),
            text
        )

        let json = PromptscopeDispatch.dispatch(["version", "--json"], releaseVersion: version)
        let golden = try String(contentsOf: fixture("contract/version.json"), encoding: .utf8)
        XCTAssertEqual(json, .exit(code: 0, stdout: golden, stderr: ""))
        let versionObject = try SchemaValidator.object(golden)
        try SchemaValidator.validate(versionObject, schema: EmbeddedSchemas.version)
        XCTAssertTrue(versionObject["commit"] is NSNull)

        let listing = """
        sessions list  R  lists sessions on this machine
        sessions show  R  shows one session and its summary
        scan  R  counts sessions per source
        report  R  measures one session
        update  M  downloads and installs the latest release
        skill install  M  writes the promptscope skill
        skill check  R  compares the installed skill with this binary
        version  R  prints the version and schema version
        schema  R  prints command schemas

        """
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["schema"], releaseVersion: version),
            .exit(code: 0, stdout: listing, stderr: "")
        )
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["schema", "report"], releaseVersion: version),
            .exit(code: 0, stdout: "report  R  measures one session\n", stderr: "")
        )

        guard case .exit(let code, let catalogText, let catalogErr) = PromptscopeDispatch.dispatch(["schema", "--json"], releaseVersion: version) else {
            return XCTFail("schema --json did not exit")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(catalogErr, "")
        let catalog = try SchemaValidator.object(catalogText)
        try SchemaValidator.validate(catalog, schema: EmbeddedSchemas.schema)
        let commands = try XCTUnwrap(catalog["commands"] as? [String: Any])
        let schemaFile = [
            "sessions list": "sessions-list",
            "sessions show": "sessions-show",
            "scan": "scan",
            "report": "report",
            "update": "update",
            "skill install": "skill-install",
            "skill check": "skill-check",
            "version": "version",
            "schema": "schema",
        ]
        XCTAssertEqual(Set(commands.keys), Set(schemaFile.keys))
        for (name, fileName) in schemaFile {
            let entry = try SchemaValidator.object(try jsonText(commands[name] as Any))
            let commandSchema = try commandEntrySchema()
            try SchemaValidator.validate(entry, schema: commandSchema, root: try SchemaValidator.object(EmbeddedSchemas.schema))
            let output = try XCTUnwrap(entry["output"] as? [String: Any])
            let file = try SchemaValidator.object(try XCTUnwrap(EmbeddedSchemas.text(named: fileName)))
            XCTAssertEqual(try canonical(output), try canonical(file))
        }
        let install = try XCTUnwrap(commands["skill install"] as? [String: Any])
        XCTAssertEqual(install["mutates"] as? Bool, true)
        XCTAssertEqual(install["destructive"] as? Bool, false)
        let errorSchema = try XCTUnwrap(catalog["error"] as? [String: Any])
        XCTAssertEqual(try canonical(errorSchema), try canonical(try SchemaValidator.object(EmbeddedSchemas.error)))

        let update = try XCTUnwrap(commands["update"] as? [String: Any])
        XCTAssertEqual(update["mutates"] as? Bool, true)
        XCTAssertEqual(update["destructive"] as? Bool, false)
        XCTAssertEqual(update["flags"] as? [String], ["--check", "--json", "--force"])

        guard case .exit(let reportCode, let reportEntryText, _) = PromptscopeDispatch.dispatch(["schema", "report", "--json"], releaseVersion: version) else {
            return XCTFail("schema report --json did not exit")
        }
        XCTAssertEqual(reportCode, 0)
        let reportEntry = try SchemaValidator.object(reportEntryText)
        XCTAssertEqual(Set(reportEntry.keys), ["summary", "mutates", "destructive", "flags", "output"])
        try SchemaValidator.validate(reportEntry, schema: try commandEntrySchema(), root: try SchemaValidator.object(EmbeddedSchemas.schema))

        // Flag order does not matter.
        guard case .exit(let versionCode, let versionEntryText, _) = PromptscopeDispatch.dispatch(["schema", "--json", "version"], releaseVersion: version) else {
            return XCTFail("schema --json version did not exit")
        }
        XCTAssertEqual(versionCode, 0)
        let versionEntry = try SchemaValidator.object(versionEntryText)
        let versionOutput = try XCTUnwrap(versionEntry["output"] as? [String: Any])
        try SchemaValidator.validate(versionObject, schema: versionOutput, root: versionOutput)
    }

    func testVersionAndSchemaErrors() throws {
        let version = "0.0.0-dev"
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["version", "--nope"], releaseVersion: version),
            .exit(
                code: 2,
                stdout: "",
                stderr: "promptscope: unknown flag: --nope\nhint: run: promptscope version --help\n"
            )
        )
        let jsonError = PromptscopeDispatch.dispatch(["version", "--nope", "--json"], releaseVersion: version)
        guard case .exit(let code, let stdout, let stderr) = jsonError else {
            return XCTFail("expected an exit")
        }
        XCTAssertEqual(code, 2)
        XCTAssertEqual(stderr, "")
        let body = try SchemaValidator.object(stdout)
        try SchemaValidator.validate(body, schema: EmbeddedSchemas.error)
        let error = try XCTUnwrap(body["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["exit"] as? Int, 2)
        XCTAssertEqual(error["message"] as? String, "unknown flag: --nope")
        XCTAssertEqual(error["hint"] as? String, "run: promptscope version --help")

        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["schema", "nope"], releaseVersion: version),
            .exit(code: 2, stdout: "", stderr: "promptscope: unknown command: nope\nhint: run: promptscope schema\n")
        )
        let unknown = PromptscopeDispatch.dispatch(["schema", "nope", "--json"], releaseVersion: version)
        XCTAssertEqual(
            unknown,
            .exit(
                code: 2,
                stdout: "{\"error\":{\"code\":\"usage\",\"exit\":2,\"message\":\"unknown command: nope\",\"hint\":\"run: promptscope schema\"}}\n",
                stderr: ""
            )
        )
        if case .exit(_, let unknownOut, _) = unknown {
            try SchemaValidator.validate(try SchemaValidator.object(unknownOut), schema: EmbeddedSchemas.error)
        }

        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["version", "--json", "--json"], releaseVersion: version).code,
            2
        )
        let omittedHint = #"{"error":{"code":"usage","exit":2,"message":"bad"}}"#
        try SchemaValidator.validate(try SchemaValidator.object(omittedHint), schema: EmbeddedSchemas.error)
        XCTAssertThrowsError(
            try SchemaValidator.validate(
                try SchemaValidator.object(#"{"error":{"code":"usage","exit":2,"message":"bad","hint":null}}"#),
                schema: EmbeddedSchemas.error
            )
        )
    }

    func testHelpExitsZero() {
        let version = "0.0.0-dev"
        for args in [
            ["--help"], ["-h"], ["help"],
            ["version", "--help"], ["version", "-h"],
            ["schema", "--help"], ["schema", "-h"],
            ["report", "--help"], ["report", "-h"], ["report", "grok", "--help"],
            ["scan", "--help"], ["scan", "-h"],
            ["sessions", "--help"], ["sessions", "list", "--help"], ["sessions", "show", "-h"],
            ["skill", "--help"], ["skill", "install", "--help"], ["skill", "check", "-h"],
            ["update", "--help"], ["update", "-h"],
        ] {
            guard case .exit(let code, let stdout, let stderr) = PromptscopeDispatch.dispatch(args, releaseVersion: version) else {
                return XCTFail("\(args) did not exit")
            }
            XCTAssertEqual(code, 0, "\(args)")
            XCTAssertEqual(stderr, "", "\(args)")
            XCTAssertFalse(stdout.isEmpty, "\(args)")
        }
        guard case .exit(_, let root, _) = PromptscopeDispatch.dispatch(["--help"], releaseVersion: version) else {
            return XCTFail("missing root help")
        }
        XCTAssertTrue(root.contains("promptscope version [--json]"))
        XCTAssertTrue(root.contains("promptscope schema [--json] [<command>]"))
        XCTAssertTrue(root.contains("promptscope sessions list"))
        guard case .exit(_, let report, _) = PromptscopeDispatch.dispatch(["report", "--help"], releaseVersion: version) else {
            return XCTFail("missing report help")
        }
        XCTAssertTrue(report.contains("promptscope report grok|kiro-ide|kiro-cli|omp|pi|devin|dsh <path>"))
        XCTAssertTrue(report.contains("--no-text"))
    }

    func testUsageExitAndUpdateDispatch() {
        XCTAssertEqual(
            PromptscopeDispatch.dispatch([], releaseVersion: "0.0.0-dev"),
            .exit(
                code: 2,
                stdout: "",
                stderr: "promptscope: missing command\nhint: run: promptscope --help\n"
            )
        )
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["nope"], releaseVersion: "0.0.0-dev"),
            .exit(
                code: 2,
                stdout: "",
                stderr: "promptscope: unknown command: nope\nhint: run: promptscope --help\n"
            )
        )
        XCTAssertEqual(
            PromptscopeDispatch.dispatch(["update", "--check", "--json"], releaseVersion: "0.0.0-dev"),
            .update(args: ["--check", "--json"])
        )
        guard case .exit(let code, let stdout, let stderr) = PromptscopeDispatch.dispatch(["schema", "sessions", "list"], releaseVersion: "0.0.0-dev") else {
            return XCTFail("schema sessions list did not exit")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(stderr, "")
        XCTAssertTrue(stdout.contains("sessions list"))
    }

    func testReportPayloadMatchesSchema() throws {
        let grok = try grokReport()
        try assertValidReport(grok.report)
        let grokJSON = try cliObject(ReportJSON.payload(grok.report))
        let entries = try XCTUnwrap(grokJSON["entries"] as? [Any])
        XCTAssertFalse(entries.isEmpty)
        let first = try XCTUnwrap(entries[0] as? [String: Any])
        XCTAssertTrue(first["at"] is NSNull, "a chat_history trajectory has a null clock, not a missing key")
        XCTAssertTrue(grokJSON["contextPercent"] is NSNull)
        XCTAssertTrue(grokJSON["promptTokens"] is NSNull)

        let skills = try XCTUnwrap(grokJSON["skills"] as? [[String: Any]])
        XCTAssertFalse(skills.isEmpty)
        XCTAssertNotNil(skills[0]["path"] as? String)
        XCTAssertNotNil(skills[0]["diskBytes"] as? NSNumber)
        let servers = try XCTUnwrap(grokJSON["mcp"] as? [[String: Any]])
        XCTAssertTrue(servers.contains { $0["toolCount"] is NSNumber })
        XCTAssertTrue(servers.contains { $0["toolCount"] == nil })

        try assertValidReport(try dshReport())

        let filled = filledReport()
        try assertValidReport(filled)
        let filledJSON = try cliObject(ReportJSON.payload(filled))
        XCTAssertEqual(filledJSON["contextPercent"] as? Double, 12.5)
        XCTAssertEqual(filledJSON["contextWindow"] as? Int, 128_000)
        let filledSkills = try XCTUnwrap(filledJSON["skills"] as? [[String: Any]])
        let bare = try XCTUnwrap(filledSkills.first { $0["name"] as? String == "bare" })
        XCTAssertNil(bare["path"])
        XCTAssertNil(bare["diskBytes"])

        var broken = grokJSON
        broken["extra"] = true
        XCTAssertThrowsError(try SchemaValidator.validate(broken, schema: EmbeddedSchemas.report))
        broken.removeValue(forKey: "extra")
        broken.removeValue(forKey: "standing")
        XCTAssertThrowsError(try SchemaValidator.validate(broken, schema: EmbeddedSchemas.report))
    }

    func testUpdateSchemaAcceptsTheUpdaterObject() throws {
        let ready = """
        {"current":"0.1.5","latest":"0.1.6","updateAvailable":true,"asset":"promptscope-v0.1.6-darwin-arm64","installPath":"/Users/me/.local/bin/promptscope"}
        """
        try SchemaValidator.validate(try SchemaValidator.object(ready), schema: EmbeddedSchemas.update)
        let failed = """
        {"current":"0.0.0-dev","latest":null,"updateAvailable":false,"asset":null,"installPath":"/Users/me/.local/bin/promptscope","error":"GitHub request failed"}
        """
        try SchemaValidator.validate(try SchemaValidator.object(failed), schema: EmbeddedSchemas.update)
        XCTAssertThrowsError(
            try SchemaValidator.validate(
                try SchemaValidator.object(#"{"current":"0.1.5","latest":null,"updateAvailable":false,"asset":null,"installPath":"/x","error":{"code":"failed"}}"#),
                schema: EmbeddedSchemas.update
            )
        )
    }

    private func assertValidReport(_ report: SessionReport) throws {
        let object = try cliObject(ReportJSON.payload(report))
        try SchemaValidator.validate(object, schema: EmbeddedSchemas.report)
        guard case .exit(_, let catalogText, _) = PromptscopeDispatch.dispatch(["schema", "--json"], releaseVersion: "0.0.0-dev") else {
            return XCTFail("schema --json did not exit")
        }
        let catalog = try SchemaValidator.object(catalogText)
        let commands = try XCTUnwrap(catalog["commands"] as? [String: Any])
        let reportCommand = try XCTUnwrap(commands["report"] as? [String: Any])
        let output = try XCTUnwrap(reportCommand["output"] as? [String: Any])
        try SchemaValidator.validate(object, schema: output, root: output)
    }

    private func grokReport() throws -> (report: SessionReport, root: URL) {
        let root = try makeTemp()
        let skillDir = root.appendingPathComponent("skills/alpha-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        try "full skill body".write(to: skillFile, atomically: true, encoding: .utf8)
        let session = root.appendingPathComponent("grok/sess", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let system = """
        You are a test agent.

        <dangerous_actions>
        Do not delete.
        </dangerous_actions>
        """
        try system.write(to: session.appendingPathComponent("system_prompt.txt"), atomically: true, encoding: .utf8)
        try writeJSON([
            ["type": "function", "function": ["name": "read_file", "description": "Read a file", "parameters": ["type": "object"]]],
        ], session.appendingPathComponent("tool_definitions.json"))
        try writeJSONLines([
            ["type": "mcp_server_connected", "server_name": "context7", "tool_count": 2, "tools": ["query-docs"]],
        ], session.appendingPathComponent("events.jsonl"))
        let skillPath = skillFile.path
        let arguments = try JSONSerialization.data(withJSONObject: ["target_file": skillPath])
        let argumentText = String(decoding: arguments, as: UTF8.self)
        try writeJSONLines([
            ["type": "system", "content": system],
            ["type": "user", "content": "<user_info>\nOS Version: macos\n</user_info>"],
            ["type": "user", "content": """
            <system-reminder>
            The following skills are available for use:

            - alpha-skill: Reads the repo.
              Absolute path: \(skillPath)
            </system-reminder>
            """, "synthetic_reason": "system_reminder"],
            ["type": "user", "content": """
            <system-reminder>
            MCP servers connected:
            - context7 (2 tools): Docs for libraries.

            MCP servers that failed to connect:
            - cloudflare-api (auth required)
            </system-reminder>
            """, "synthetic_reason": "system_reminder"],
            ["type": "user", "content": "<user_query>analyze session</user_query>"],
            ["type": "assistant", "content": "reading", "tool_calls": [["id": "c1", "name": "read_file", "arguments": argumentText]]],
            ["type": "tool_result", "tool_call_id": "c1", "content": "full skill body"],
        ], session.appendingPathComponent("chat_history.jsonl"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let ref = SessionRef(
            id: "grok:sess", source: .grok, sessionID: "sess", title: "Analysis", cwd: "/Users/me/app",
            model: nil, agent: nil, createdAt: nil, updatedAt: nil, locator: session.path,
            transcriptBytes: 1, isSubagent: false, isTemporary: false, contextPercent: nil, fingerprint: "x"
        )
        return (SessionAnalyzer.report(for: ref), root)
    }

    private func dshReport() throws -> SessionReport {
        let root = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.v4.jsonl")
        func row(_ type: String, _ time: Int, _ data: [String: Any]) -> [String: Any] {
            ["type": type, "seq": time, "time": 1_792_000_000_000 + time, "data": data]
        }
        try writeJSONLines([
            ["type": "session", "version": 4, "id": "s", "cwd": "/x", "createdAt": 1_792_000_000_000],
            row("turn/start", 0, ["turn": 1]),
            row("user/message", 1, ["content": [["type": "text", "text": "go"]], "source": ["kind": "user"]]),
            row("step/start", 10, ["turn": 1, "step": 1]),
            row("assistant/message", 3_000, ["turn": 1, "step": 1,
                "message": ["role": "assistant", "content": [["type": "reasoning", "text": "hmm"], ["type": "text", "text": "done"]]],
                "usage": ["inputTokens": 100, "cacheReadTokens": 900]]),
            row("tool/call", 3_001, ["turn": 1, "step": 1, "callId": "c", "name": "bash", "arguments": "{\"command\":\"ls\"}"]),
            row("tool/result", 3_501, ["turn": 1, "step": 1,
                "message": ["toolCallId": "c", "isError": true, "content": [["type": "text", "text": "x"]]]]),
            row("job/registered", 3_600, ["jobId": "j", "label": "sleep 9", "startedAt": 1_792_000_003_600]),
            row("job/settled", 5_600, ["jobId": "j", "status": "killed", "finishedAt": 1_792_000_005_600]),
            row("turn/end", 8_000, ["turn": 1, "reason": ["kind": "aborted"]]),
        ], file)
        return SessionAnalyzer.report(for: SessionRef(
            id: "dsh:s", source: .dsh, sessionID: "s", title: "s", cwd: "/x",
            model: nil, agent: nil, createdAt: nil, updatedAt: nil, locator: file.path,
            transcriptBytes: 1, isSubagent: false, isTemporary: false, contextPercent: nil, fingerprint: "x"
        ))
    }

    private func filledReport() -> SessionReport {
        let ref = SessionRef(
            id: "pi:s", source: .pi, sessionID: "s", title: "s", cwd: "/tmp/app",
            model: nil, agent: nil, createdAt: nil, updatedAt: nil, locator: "/tmp/app/s.jsonl",
            transcriptBytes: 1, isSubagent: false, isTemporary: false, contextPercent: nil, fingerprint: "x"
        )
        return SessionReport(
            ref: ref,
            standing: [Slice(kind: .system, bytes: 10)],
            transcript: [Slice(kind: .user, bytes: 4)],
            sections: [SectionMeasure(name: "preamble", bytes: 3, preview: "hi")],
            skills: [
                SkillMeasure(name: "bare", catalogBytes: 2, summary: "no file", path: nil, origin: "unknown"),
                SkillMeasure(name: "alpha", catalogBytes: 4, summary: "reads", path: "/tmp/SKILL.md", origin: "user", diskBytes: 9, readCount: 1),
            ],
            mcp: [
                McpMeasure(name: "plain", catalogBytes: 3, toolCount: nil, status: "unknown", tools: [], blurb: ""),
                McpMeasure(name: "context7", catalogBytes: 8, toolCount: 2, status: "connected", tools: ["query-docs"], blurb: "docs"),
            ],
            tools: [ToolMeasure(name: "read_file", definitionBytes: 5, calls: 1, resultBytes: 6)],
            turns: [TurnMeasure(index: 1, preview: "hi", userBytes: 2, replyBytes: 3)],
            trajectory: [
                TrajectoryEntry(index: 0, at: nil, turn: 1, kind: "notice", label: "x", bytes: 0),
                TrajectoryEntry(index: 1, at: 1_700_000_000_000, turn: 1, kind: "tool", label: "read_file", bytes: 6, durationMs: 15, failed: true, tokens: 40),
            ],
            heavy: [HeavyResult(rank: 1, tool: "read_file", bytes: 6)],
            steering: [NamedBytes(name: "rules.md", bytes: 7, detail: "workspace")],
            contextPercent: 12.5,
            contextWindow: 128_000,
            promptTokens: 40,
            notes: ["note"],
            truncated: false
        )
    }

    private func cliObject(_ payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let value = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(value as? [String: Any])
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func commandEntrySchema() throws -> [String: Any] {
        let root = try SchemaValidator.object(EmbeddedSchemas.schema)
        let defs = try XCTUnwrap(root["$defs"] as? [String: Any])
        return try XCTUnwrap(defs["command"] as? [String: Any])
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

private extension PromptscopeDispatch.Action {
    var code: Int32? {
        guard case .exit(let code, _, _) = self else { return nil }
        return code
    }
}
