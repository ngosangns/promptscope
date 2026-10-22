import Foundation

/// Homes the scanner reads. Tests pass a fixture. The CLI uses `live`.
public struct LibraryRoots: Sendable, Equatable {
    public var grok: URL
    public var kiro: URL
    public var omp: URL
    public var pi: URL
    public var devin: URL
    public var dsh: URL

    public init(grok: URL, kiro: URL, omp: URL, pi: URL, devin: URL, dsh: URL) {
        self.grok = grok
        self.kiro = kiro
        self.omp = omp
        self.pi = pi
        self.devin = devin
        self.dsh = dsh
    }

    public static var live: LibraryRoots {
        LibraryRoots(
            grok: LibraryScanner.defaultGrokHome,
            kiro: LibraryScanner.defaultKiroHome,
            omp: LibraryScanner.defaultOmpHome,
            pi: LibraryScanner.defaultPiHome,
            devin: LibraryScanner.defaultDevinHome,
            dsh: LibraryScanner.defaultDshHome
        )
    }

    public func scan() -> LibraryScan {
        LibraryScanner.scan(
            grokHome: grok,
            kiroHome: kiro,
            ompHome: omp,
            piHome: pi,
            devinHome: devin,
            dshHome: dsh
        )
    }
}

/// Where commands read and write. `now` is the clock for `--since 7d`.
public struct PromptscopeEnvironment: Sendable, Equatable {
    public var roots: LibraryRoots
    public var skillDirectory: URL
    public var now: Date

    public init(roots: LibraryRoots, skillDirectory: URL, now: Date = Date()) {
        self.roots = roots
        self.skillDirectory = skillDirectory
        self.now = now
    }

    public static var live: PromptscopeEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PromptscopeEnvironment(
            roots: .live,
            skillDirectory: home.appendingPathComponent(".agents/skills/promptscope")
        )
    }
}
