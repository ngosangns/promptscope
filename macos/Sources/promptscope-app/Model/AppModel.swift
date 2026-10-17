import AppKit
import Foundation
import Observation
import PromptscopeKit

struct SkillTax: Identifiable {
    var id: String { name }
    var name: String
    var sessions: Int
    var bytes: Int
    var detail: String
}

@MainActor
@Observable
final class AppModel {
    var sessions: [SessionRef] = []
    var digests: [String: SessionDigest] = [:]
    var report: SessionReport?
    var selectedID: String?
    var query = ""
    var source: AgentSource?
    var workspace: String?
    var hideNoise = true
    var measureProgress: Double?
    var measureLabel = ""
    var isScanning = false
    var skippedEmptyCLI = 0
    var scanNotes: [String] = []
    private var generation = 0

    func start() {
        if sessions.isEmpty { reload() }
    }

    var filtered: [SessionRef] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter { ref in
            if hideNoise && ref.isNoise { return false }
            if let source, ref.source != source { return false }
            if let workspace, ref.cwd != workspace { return false }
            guard !needle.isEmpty else { return true }
            let blob = "\(ref.title) \(ref.cwd) \(ref.sessionID) \(ref.model ?? "") \(ref.agent ?? "")".lowercased()
            return blob.contains(needle)
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    var workspaces: [(cwd: String, label: String)] {
        let pool = sessions.filter { ref in
            if hideNoise && ref.isNoise { return false }
            if let source, ref.source != source { return false }
            return true
        }
        let counts = Dictionary(grouping: pool, by: \.cwd).mapValues(\.count)
        return counts.keys.sorted { Paths.short($0).localizedCaseInsensitiveCompare(Paths.short($1)) == .orderedAscending }
            .map { cwd in
                let name = cwd.isEmpty ? "(trống)" : Paths.short(cwd)
                return (cwd, "\(name)  \(counts[cwd] ?? 0)")
            }
    }

    /// Counts for the source list. Search and workspace do not change these.
    var sourceCounts: [AgentSource: Int] {
        var counts: [AgentSource: Int] = [:]
        for ref in sessions where !(hideNoise && ref.isNoise) {
            counts[ref.source, default: 0] += 1
        }
        return counts
    }

    var measured: [SessionDigest] {
        filtered.compactMap { digests[$0.id] }
    }

    var skillTax: [SkillTax] {
        var acc: [String: SkillTax] = [:]
        for digest in measured {
            for skill in digest.skills where skill.bytes > 0 {
                var row = acc[skill.name] ?? SkillTax(name: skill.name, sessions: 0, bytes: 0, detail: skill.detail)
                row.sessions += 1
                row.bytes += skill.bytes
                acc[skill.name] = row
            }
        }
        return acc.values.sorted { $0.bytes > $1.bytes }
    }

    var mcpTax: [SkillTax] {
        var acc: [String: SkillTax] = [:]
        for digest in measured {
            for server in digest.mcp {
                var row = acc[server.name] ?? SkillTax(name: server.name, sessions: 0, bytes: 0, detail: server.detail)
                row.sessions += 1
                row.bytes += server.bytes
                if !server.detail.isEmpty { row.detail = server.detail }
                acc[server.name] = row
            }
        }
        return acc.values.sorted { $0.bytes > $1.bytes }
    }

    func reload() {
        generation += 1
        let token = generation
        report = nil
        isScanning = true
        measureLabel = "Đang quét session…"
        measureProgress = nil
        Task {
            let scan = await Task.detached {
                LibraryScanner.scan(
                    grokHome: LibraryScanner.defaultGrokHome,
                    kiroHome: LibraryScanner.defaultKiroHome,
                    ompHome: LibraryScanner.defaultOmpHome,
                    piHome: LibraryScanner.defaultPiHome,
                    devinHome: LibraryScanner.defaultDevinHome
                )
            }.value
            guard token == generation else { return }
            isScanning = false
            sessions = scan.sessions
            skippedEmptyCLI = scan.skippedEmptyCLI
            scanNotes = scan.notes
            if let selectedID, sessions.contains(where: { $0.id == selectedID }) == false {
                self.selectedID = nil
            }
            await measure(token: token)
        }
    }

    func loadSelected() {
        guard let selectedID, let ref = sessions.first(where: { $0.id == selectedID }) else {
            report = nil
            return
        }
        let token = generation
        Task {
            let loaded = await Task.detached { SessionAnalyzer.report(for: ref) }.value
            guard token == generation, self.selectedID == ref.id else { return }
            report = loaded
            digests[ref.id] = loaded.digest()
        }
    }

    func revealSelected() {
        guard let selectedID, let ref = sessions.first(where: { $0.id == selectedID }) else { return }
        let url = URL(fileURLWithPath: ref.locator)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ReportText.plain(report), forType: .string)
    }

    private func measure(token: Int) async {
        let cache = loadCache()
        var pending: [SessionRef] = []
        var known: [String: SessionDigest] = [:]
        for session in sessions {
            if let hit = cache[session.id], hit.fingerprint == session.fingerprint {
                known[session.id] = hit
            } else {
                pending.append(session)
            }
        }
        digests = known
        guard !pending.isEmpty else {
            measureProgress = nil
            measureLabel = ""
            return
        }
        let total = pending.count
        var done = 0
        var cursor = 0
        while cursor < pending.count {
            guard token == generation else { return }
            let end = min(cursor + 4, pending.count)
            let batch = Array(pending[cursor..<end])
            let results: [SessionDigest] = await withTaskGroup(of: SessionDigest.self) { group in
                for ref in batch {
                    group.addTask { SessionAnalyzer.digest(for: ref) }
                }
                var out: [SessionDigest] = []
                for await item in group { out.append(item) }
                return out
            }
            guard token == generation else { return }
            for item in results { digests[item.id] = item }
            done += batch.count
            cursor = end
            measureProgress = Double(done) / Double(total)
            measureLabel = "Đo prompt \(done)/\(total)"
            if done % 48 == 0 { saveCache() }
        }
        measureProgress = nil
        measureLabel = ""
        saveCache()
    }

    private var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Promptscope", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("digests.json")
    }

    private func loadCache() -> [String: SessionDigest] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        struct Envelope: Codable { var version: Int; var items: [SessionDigest] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { return [:] }
        return Dictionary(uniqueKeysWithValues: envelope.items.map { ($0.id, $0) })
    }

    private func saveCache() {
        struct Envelope: Codable { var version: Int; var items: [SessionDigest] }
        let envelope = Envelope(version: 1, items: Array(digests.values))
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
