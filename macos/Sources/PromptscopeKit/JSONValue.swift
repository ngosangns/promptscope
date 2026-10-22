import Foundation

/// Loose readers for `JSONSerialization` output. Every analyzer reads the same untyped shapes.
enum JSONValue {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    /// A string as-is, any other valid JSON value serialized, anything else empty.
    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    /// Message content: a string, or a list of strings and `{text}` parts, joined by newlines.
    static func contentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [Any] else { return "" }
        return parts.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let object = item as? [String: Any] { return object["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    /// Epoch milliseconds only; smaller numbers are not timestamps.
    static func epochMillis(_ value: Any?) -> Int? {
        guard let number = int(value), number > 1_000_000_000_000 else { return nil }
        return number
    }
}

extension Slice {
    /// Non-empty slices in `SliceKind` order.
    static func pack(_ map: [SliceKind: Int]) -> [Slice] {
        SliceKind.allCases.compactMap { kind in
            guard let bytes = map[kind], bytes > 0 else { return nil }
            return Slice(kind: kind, bytes: bytes)
        }
    }

    static func nonEmpty(_ slices: [Slice]) -> [Slice] {
        slices.filter { $0.bytes > 0 }
    }
}

/// Keep the eight heaviest tool results, largest first.
func considerHeavy(_ heavy: inout [(String, Int)], tool: String, bytes: Int) {
    guard bytes > 0 else { return }
    if heavy.count < 8 || bytes > heavy[heavy.count - 1].1 {
        heavy.append((tool, bytes))
        heavy.sort { $0.1 > $1.1 }
        if heavy.count > 8 { heavy.removeLast(heavy.count - 8) }
    }
}

/// Catalog rows start at each `pattern` match (group 1 is the name) and run to the next match.
func parseCatalogSkills(_ text: String, pattern: String, origin: String) -> [SkillMeasure] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    var order: [String] = []
    var byName: [String: SkillMeasure] = [:]
    for (index, match) in matches.enumerated() {
        let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        let start = match.range.location
        let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
        let block = ns.substring(with: NSRange(location: start, length: max(end - start, 0)))
        let measure = SkillMeasure(
            name: name,
            catalogBytes: block.utf8.count,
            summary: PromptText.preview(block, limit: 180),
            path: nil,
            origin: origin
        )
        if var existing = byName[name] {
            if measure.catalogBytes > existing.catalogBytes {
                existing.catalogBytes = measure.catalogBytes
                existing.summary = measure.summary
            }
            byName[name] = existing
        } else {
            order.append(name)
            byName[name] = measure
        }
    }
    return order.compactMap { byName[$0] }
}
