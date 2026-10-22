import Foundation

/// Total orders for arrays built from dictionaries. A sort on one field keeps
/// `Dictionary` iteration order for ties, and that order changes between processes.
enum StableOrder {
    static func toolsByCalls(_ tools: some Sequence<ToolMeasure>) -> [ToolMeasure] {
        tools.sorted { lhs, rhs in
            if lhs.calls != rhs.calls { return lhs.calls > rhs.calls }
            if lhs.resultBytes != rhs.resultBytes { return lhs.resultBytes > rhs.resultBytes }
            return lhs.name < rhs.name
        }
    }

    static func toolsByWeight(_ tools: some Sequence<ToolMeasure>) -> [ToolMeasure] {
        tools.sorted { lhs, rhs in
            let left = lhs.resultBytes + lhs.definitionBytes
            let right = rhs.resultBytes + rhs.definitionBytes
            if left != right { return left > right }
            if lhs.calls != rhs.calls { return lhs.calls > rhs.calls }
            return lhs.name < rhs.name
        }
    }

    static func toolsByResults(_ tools: some Sequence<ToolMeasure>) -> [ToolMeasure] {
        tools.sorted { lhs, rhs in
            if lhs.resultBytes != rhs.resultBytes { return lhs.resultBytes > rhs.resultBytes }
            if lhs.calls != rhs.calls { return lhs.calls > rhs.calls }
            return lhs.name < rhs.name
        }
    }

    static func skillsByCatalog(_ skills: some Sequence<SkillMeasure>) -> [SkillMeasure] {
        skills.sorted { lhs, rhs in
            if lhs.catalogBytes != rhs.catalogBytes { return lhs.catalogBytes > rhs.catalogBytes }
            return lhs.name < rhs.name
        }
    }

    static func skillsByReads(_ skills: some Sequence<SkillMeasure>) -> [SkillMeasure] {
        skills.sorted { lhs, rhs in
            if lhs.readCount != rhs.readCount { return lhs.readCount > rhs.readCount }
            if lhs.catalogBytes != rhs.catalogBytes { return lhs.catalogBytes > rhs.catalogBytes }
            return lhs.name < rhs.name
        }
    }

    static func mcpByCatalog(_ rows: some Sequence<McpMeasure>) -> [McpMeasure] {
        rows.sorted { lhs, rhs in
            if lhs.catalogBytes != rhs.catalogBytes { return lhs.catalogBytes > rhs.catalogBytes }
            return lhs.name < rhs.name
        }
    }

    static func heavy(_ rows: [(String, Int)], limit: Int = 8) -> [HeavyResult] {
        let sorted = rows.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        return sorted.prefix(limit).enumerated().map { index, item in
            HeavyResult(rank: index + 1, tool: item.0, bytes: item.1)
        }
    }
}
