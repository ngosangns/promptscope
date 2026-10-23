import Foundation

/// Finds `promptscope-update-<version>` beside the installed CLI.
///
/// The shell runs `promptscope` from `PATH`, so the path handed in may be the
/// symlink `~/.local/bin/promptscope` rather than the versioned file. That
/// symlink's target is relative (`../share/promptscope/bin/promptscope-X.Y.Z`).
public enum UpdaterLocator {
    /// Sibling updater path when that file passes `isExecutable`.
    public static func find(
        executablePath: String,
        releaseVersion: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let sibling = searchedPath(executablePath: executablePath, releaseVersion: releaseVersion)
        if isExecutable(sibling) {
            return sibling
        }
        return nil
    }

    /// Absolute `promptscope-update-<releaseVersion>` path next to the resolved executable.
    public static func searchedPath(executablePath: String, releaseVersion: String) -> String {
        let resolved = resolveExecutable(executablePath)
        return URL(fileURLWithPath: resolved)
            .deletingLastPathComponent()
            .appendingPathComponent("promptscope-update-\(releaseVersion)")
            .path
    }

    /// Real file named by `executablePath`. A relative symlink target is joined to
    /// the directory that contains the link, then `resolvingSymlinksInPath` cleans
    /// the result.
    static func resolveExecutable(_ path: String) -> String {
        let absolute = absolutePath(path)
        let walked = walkSymlinks(absolute)
        return URL(fileURLWithPath: walked).resolvingSymlinksInPath().path
    }

    private static func absolutePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: cwd).path
    }

    /// Follows a symlink chain. `resolvingSymlinksInPath` does this when the
    /// target exists; joining a relative target here covers a link it leaves as-is.
    private static func walkSymlinks(_ path: String) -> String {
        var current = path
        var seen = Set<String>()
        let fm = FileManager.default
        for _ in 0..<32 {
            let standardized = URL(fileURLWithPath: current).standardizedFileURL.path
            if !seen.insert(standardized).inserted {
                return standardized
            }
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: current) else {
                return standardized
            }
            if (destination as NSString).isAbsolutePath {
                current = destination
            } else {
                current = URL(fileURLWithPath: current)
                    .deletingLastPathComponent()
                    .appendingPathComponent(destination)
                    .standardizedFileURL
                    .path
            }
        }
        return URL(fileURLWithPath: current).standardizedFileURL.path
    }
}
