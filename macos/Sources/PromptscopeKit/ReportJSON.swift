import Foundation

/// The object `promptscope report <source> <path> --json` prints.
/// The window reads these keys. Schema v1 adds fields only.
///
/// Codable models omit a nil optional. The three context numbers and the
/// clocks on `entries` are JSON null when the log has no value.
public enum ReportJSON {
    public static func payload(_ report: SessionReport) -> [String: Any] {
        // Encodes a Codable value as plain JSON objects, so the window reads the same
        // fields the Kit holds and the CLI does not keep a second field list.
        func plain<T: Encodable>(_ value: T) -> Any {
            guard let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
            return object
        }
        return [
            "standing": plain(report.standing),
            "transcript": plain(report.transcript),
            "sections": plain(report.sections),
            "skills": plain(report.skills),
            "mcp": plain(report.mcp),
            "tools": plain(report.tools),
            "turns": plain(report.turns),
            "heavy": plain(report.heavy),
            "steering": plain(report.steering),
            "notes": report.notes,
            "contextPercent": report.contextPercent as Any,
            "contextWindow": report.contextWindow as Any,
            "promptTokens": report.promptTokens as Any,
            "truncated": report.truncated,
            "entries": report.trajectory.map { entry in
                [
                    "at": entry.at as Any,
                    "turn": entry.turn,
                    "kind": entry.kind,
                    "label": entry.label,
                    "bytes": entry.bytes,
                    "durationMs": entry.durationMs as Any,
                    "failed": entry.failed,
                    "tokens": entry.tokens as Any,
                ] as [String: Any]
            },
        ]
    }

    /// Keys `--section` accepts. Order here is the text-mode order.
    public static let sectionKeys = [
        "standing", "transcript", "sections", "skills", "mcp", "tools",
        "turns", "heavy", "steering", "entries", "notes",
    ]

    /// Totals only. `estimatedTokens` is `standingBytes / 4`. Heavy labels are tool names.
    public static func summary(_ report: SessionReport) -> [String: Any] {
        let standing = report.standingBytes
        let heavy = report.heavy.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.tool < rhs.tool
        }.prefix(5).map { item in
            ["label": item.tool, "bytes": item.bytes] as [String: Any]
        }
        return [
            "standingBytes": standing,
            "transcriptBytes": report.transcriptCompositionBytes,
            "estimatedTokens": standing / 4,
            "contextPercent": jsonNumber(report.contextPercent),
            "contextWindow": jsonNumber(report.contextWindow),
            "promptTokens": jsonNumber(report.promptTokens),
            "counts": [
                "sections": report.sections.count,
                "skills": report.skills.count,
                "mcp": report.mcp.count,
                "tools": report.tools.count,
                "turns": report.turns.count,
                "entries": report.trajectory.count,
            ] as [String: Any],
            "heavy": heavy,
            "truncated": report.truncated,
        ]
    }

    /// Same keys as `payload`. Free-text fields that can carry transcript, user, or tool
    /// content become JSON null. Names, kinds, statuses, and numbers stay.
    public static func redacted(_ payload: [String: Any]) -> [String: Any] {
        var copy = payload
        copy["sections"] = nulling(copy["sections"], key: "preview")
        copy["skills"] = nulling(copy["skills"], key: "summary")
        copy["mcp"] = nulling(copy["mcp"], key: "blurb")
        copy["turns"] = nulling(copy["turns"], key: "preview")
        copy["entries"] = nulling(copy["entries"], key: "label")
        return copy
    }

    /// Object with only the requested keys.
    public static func selecting(_ payload: [String: Any], keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in keys {
            out[key] = payload[key] ?? []
        }
        return out
    }

    /// Drops items from the longest arrays until the document fits. Sets `truncated` when it drops any.
    public static func fitted(_ payload: [String: Any], maxBytes: Int) -> [String: Any] {
        var payload = payload
        if encodedCount(payload) <= maxBytes { return payload }
        payload["truncated"] = true
        let order = [
            "entries", "turns", "heavy", "tools", "sections", "skills", "mcp",
            "steering", "notes", "transcript", "standing",
        ]
        while encodedCount(payload) > maxBytes {
            var choice: String?
            var length = 0
            for key in order {
                guard let list = payload[key] as? [Any], list.count > length else { continue }
                choice = key
                length = list.count
            }
            guard let choice, var list = payload[choice] as? [Any], !list.isEmpty else { break }
            list.removeLast()
            payload[choice] = list
        }
        return payload
    }

    private static func encodedCount(_ payload: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return Int.max }
        return data.count
    }

    private static func nulling(_ value: Any?, key: String) -> [Any] {
        guard let list = value as? [Any] else { return [] }
        return list.map { item in
            guard var row = item as? [String: Any] else { return item }
            row[key] = NSNull()
            return row
        }
    }

    private static func jsonNumber(_ value: Int?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private static func jsonNumber(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value
    }
}
