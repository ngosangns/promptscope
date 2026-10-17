import Foundation

enum Files {
    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Read up to `maxBytes`. Yield returns false to stop. The result is true when the file continues past the cap.
    static func forEachLine(
        url: URL,
        maxBytes: Int,
        _ yield: (String) -> Bool
    ) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var buffer = Data()
        var consumed = 0
        var truncated = false
        var stop = false
        while consumed < maxBytes && !stop {
            let want = min(64 * 1024, maxBytes - consumed)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            consumed += chunk.count
            if consumed >= maxBytes { truncated = true }
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                let lineData = buffer[start..<newline]
                start = buffer.index(after: newline)
                if !yield(String(decoding: lineData, as: UTF8.self)) {
                    stop = true
                    break
                }
            }
            if start > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<start)
            }
            if truncated { break }
        }
        if !truncated, !stop, !buffer.isEmpty {
            _ = yield(String(decoding: buffer, as: UTF8.self))
        }
        return truncated && !stop
    }

    /// The last `maxBytes` of a file, for reading a trailing usage record without the whole transcript.
    static func tail(url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let back = UInt64(max(maxBytes, 0))
            if end > back {
                try handle.seek(toOffset: end - back)
            } else {
                try handle.seek(toOffset: 0)
            }
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    static func readText(url: URL, maxBytes: Int) -> (String, Bool) {
        var parts: [String] = []
        let truncated = forEachLine(url: url, maxBytes: maxBytes) { line in
            parts.append(line)
            return true
        }
        return (parts.joined(separator: "\n"), truncated)
    }
}

enum JSONFile {
    static func object(url: URL, maxBytes: Int = 8_000_000) -> [String: Any]? {
        guard Files.size(url) <= maxBytes, let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func lineObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Dates {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

public enum PromptText {
    public static func utf8Count(_ text: String) -> Int { text.utf8.count }

    public static func preview(_ text: String, limit: Int = 90) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    public static func userQuery(in text: String) -> String? {
        guard let open = text.range(of: "<user_query>") else { return nil }
        let rest = text[open.upperBound...]
        if let close = rest.range(of: "</user_query>") {
            return String(rest[..<close.lowerBound])
        }
        return String(rest.prefix(500))
    }

    /// Top-level tags that occupy a whole line. Inline mentions such as
    /// `the <user_query> tag` stay inside the surrounding section.
    public static func sections(in text: String) -> [SectionMeasure] {
        struct Line {
            var text: String
            var start: String.Index
            var end: String.Index
        }
        var lines: [Line] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let newline = text[cursor...].firstIndex(of: "\n") {
                lines.append(Line(
                    text: String(text[cursor..<newline]),
                    start: cursor,
                    end: text.index(after: newline)
                ))
                cursor = text.index(after: newline)
            } else {
                lines.append(Line(text: String(text[cursor...]), start: cursor, end: text.endIndex))
                break
            }
        }

        var measures: [SectionMeasure] = []
        var covered: [Range<String.Index>] = []
        var depth = 0
        var name = ""
        var sectionStart: String.Index?

        for line in lines {
            guard let tag = structuralTag(line.text) else { continue }
            if tag.open {
                if depth == 0 {
                    name = tag.name
                    sectionStart = line.start
                }
                depth += 1
            } else if depth > 0 {
                depth -= 1
                if depth == 0, let start = sectionStart {
                    let slice = text[start..<line.end]
                    measures.append(SectionMeasure(
                        name: name,
                        bytes: slice.utf8.count,
                        preview: PromptText.preview(sectionBody(String(slice), name: name), limit: 160)
                    ))
                    covered.append(start..<line.end)
                    sectionStart = nil
                }
            }
        }
        if depth > 0, let start = sectionStart {
            let slice = text[start...]
            measures.append(SectionMeasure(
                name: name,
                bytes: slice.utf8.count,
                preview: PromptText.preview(sectionBody(String(slice), name: name), limit: 160)
            ))
            covered.append(start..<text.endIndex)
        }

        var preamble = ""
        var walk = text.startIndex
        for range in covered where walk <= range.lowerBound {
            preamble += text[walk..<range.lowerBound]
            walk = range.upperBound
        }
        if walk < text.endIndex { preamble += text[walk...] }
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            measures.insert(
                SectionMeasure(name: "mở đầu", bytes: preamble.utf8.count, preview: PromptText.preview(preamble, limit: 160)),
                at: 0
            )
        }
        return measures
    }

    public static func skills(in text: String) -> [SkillMeasure] {
        guard text.contains("skills are available") else { return [] }
        var skills: [SkillMeasure] = []
        var bucket: [String] = []

        func flush() {
            guard let header = bucket.first, let parsed = skillHeader(header) else {
                bucket.removeAll(keepingCapacity: true)
                return
            }
            let block = bucket.joined(separator: "\n")
            var path: String?
            var summary = parsed.desc
            for line in bucket.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let rest = trimmed.dropPrefix("Absolute path:") {
                    path = rest.trimmingCharacters(in: .whitespaces)
                } else if let rest = trimmed.dropPrefix("Use when:") {
                    let when = rest.trimmingCharacters(in: .whitespaces)
                    if !when.isEmpty, summary.count < 180 {
                        summary = summary.isEmpty ? when : "\(summary) \(when)"
                    }
                }
            }
            skills.append(SkillMeasure(
                name: parsed.name,
                catalogBytes: block.utf8.count,
                summary: PromptText.preview(summary, limit: 180),
                path: path,
                origin: skillOrigin(path)
            ))
            bucket.removeAll(keepingCapacity: true)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if skillHeader(line) != nil {
                flush()
                bucket = [line]
            } else if !bucket.isEmpty, line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") {
                bucket.append(line)
            } else if !bucket.isEmpty {
                flush()
            }
        }
        flush()
        return skills
    }

    public static func mcpServers(in text: String) -> [McpMeasure] {
        guard text.contains("MCP servers") else { return [] }
        var servers: [McpMeasure] = []
        var mode: String?
        var bucket: [String] = []

        func flush() {
            guard let header = bucket.first, let parsed = mcpHeader(header) else {
                bucket.removeAll(keepingCapacity: true)
                return
            }
            let block = bucket.joined(separator: "\n")
            var blurb = parsed.blurb
            for line in bucket.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { blurb += (blurb.isEmpty ? "" : " ") + trimmed }
            }
            var status = mode ?? "unknown"
            let paren = parsed.paren.lowercased()
            if paren.contains("auth") { status = "auth" }
            let toolCount = parsed.toolCount
            servers.append(McpMeasure(
                name: parsed.name,
                catalogBytes: block.utf8.count,
                toolCount: toolCount,
                status: status,
                tools: [],
                blurb: PromptText.preview(blurb, limit: 180)
            ))
            bucket.removeAll(keepingCapacity: true)
        }

        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("failed to connect") {
                flush()
                mode = "failed"
                continue
            }
            if trimmed.contains("MCP servers connected") {
                flush()
                mode = "connected"
                continue
            }
            if mcpHeader(line) != nil {
                flush()
                bucket = [line]
            } else if !bucket.isEmpty, line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") {
                bucket.append(line)
            } else if !bucket.isEmpty {
                flush()
            }
        }
        flush()
        return servers
    }

    /// JSON serializers often write `\/`. Skill paths are compared after this fold.
    public static func normalizeSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }

    public static func skillPaths(in text: String) -> [String] {
        let text = normalizeSlashes(text)
        var found: [String] = []
        var search = text.startIndex
        while let range = text.range(of: "SKILL.md", range: search..<text.endIndex) {
            var start = range.lowerBound
            while start > text.startIndex {
                let previous = text.index(before: start)
                let ch = text[previous]
                if ch == " " || ch == "\"" || ch == "'" || ch == "\n" || ch == "\t" || ch == "(" || ch == "," || ch == "\\" {
                    break
                }
                start = previous
            }
            let path = String(text[start..<range.upperBound])
            if path.contains("/") { found.append(path) }
            search = range.upperBound
        }
        return found
    }

    public static func skillName(from path: String) -> String? {
        let normalized = normalizeSlashes(path)
        // Ignore prose and source that merely mention SKILL.md.
        guard normalized.contains("/skills/") else { return nil }
        let parts = normalized.split(separator: "/").map(String.init)
        guard let index = parts.lastIndex(of: "SKILL.md"), index > 0 else { return nil }
        let name = parts[index - 1].trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        guard isSkillName(name) else { return nil }
        return name
    }
}

private struct SkillHeader {
    var name: String
    var desc: String
}

private func skillHeader(_ line: String) -> SkillHeader? {
    guard line.hasPrefix("- ") else { return nil }
    let rest = line.dropFirst(2)
    guard let colon = rest.firstIndex(of: ":") else { return nil }
    let name = rest[..<colon]
    guard isSkillName(name) else { return nil }
    let desc = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    return SkillHeader(name: String(name), desc: desc)
}

private struct McpHeader {
    var name: String
    var toolCount: Int?
    var paren: String
    var blurb: String
}

private func mcpHeader(_ line: String) -> McpHeader? {
    guard line.hasPrefix("- ") else { return nil }
    let rest = line.dropFirst(2)
    guard let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") else { return nil }
    let name = rest[..<open].trimmingCharacters(in: .whitespaces)
    guard isSkillName(name) else { return nil }
    let paren = String(rest[rest.index(after: open)..<close])
    let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
    let blurb = after.hasPrefix(":") ? String(after.dropFirst()).trimmingCharacters(in: .whitespaces) : after
    let toolCount = paren.split(separator: " ").first.flatMap { Int($0) }
    let counted = paren.contains("tool") ? toolCount : nil
    return McpHeader(name: String(name), toolCount: counted, paren: paren, blurb: blurb)
}

private func isSkillName<S: StringProtocol>(_ name: S) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
}

func skillOrigin(_ path: String?) -> String {
    guard let path else { return "không rõ" }
    if path.contains("/bundled/skills/") || path.contains("/.grok/bundled/") { return "bundled" }
    if path.contains("/.grok/skills/") || path.contains("/.kiro/skills/") || path.contains("/.agents/skills/")
        || path.contains("/.pi/agent/skills/") || path.contains("/.omp/agent/skills/")
        || path.contains("/.config/devin/skills/") {
        return "user"
    }
    return "project"
}

private func sectionBody(_ slice: String, name: String) -> String {
    var body = slice
    if let open = body.range(of: "<\(name)") {
        if let end = body[open.upperBound...].firstIndex(of: ">") {
            body.removeSubrange(open.lowerBound...end)
        }
    }
    body = body.replacingOccurrences(of: "</\(name)>", with: "")
    return body
}

private struct StructuralTag {
    var open: Bool
    var name: String
}

private func structuralTag(_ line: String) -> StructuralTag? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.contains("\n") else { return nil }
    var inner = trimmed.dropFirst().dropLast()
    let open = !inner.hasPrefix("/")
    if !open { inner = inner.dropFirst() }
    if inner.hasSuffix("/") { return nil }
    let name = inner.split(separator: " ", maxSplits: 1).first ?? inner
    guard isTagName(name) else { return nil }
    return StructuralTag(open: open, name: String(name))
}

private func isTagName<S: StringProtocol>(_ name: S) -> Bool {
    guard let first = name.first, first.isLetter || first == "_" else { return false }
    return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

enum SkillFiles {
    static func diskBytes(_ path: String?) -> Int? {
        guard var path, !path.isEmpty else { return nil }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            path = url.path
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        let file = isDir.boolValue ? URL(fileURLWithPath: path).appendingPathComponent("SKILL.md").path : path
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        return Files.size(URL(fileURLWithPath: file))
    }
}

public enum Paths {
    static func isTemporary(_ cwd: String) -> Bool {
        cwd.hasPrefix("/tmp")
            || cwd.hasPrefix("/private/tmp")
            || cwd.hasPrefix("/var/folders")
            || cwd.hasPrefix("/private/var/folders")
    }

    public static func short(_ cwd: String) -> String {
        let decoded = cwd.removingPercentEncoding ?? cwd
        let name = URL(fileURLWithPath: decoded).lastPathComponent
        return name.isEmpty ? decoded : name
    }
}
