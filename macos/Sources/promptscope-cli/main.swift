import Foundation
import PromptscopeKit

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

/// Marketing version. The release script replaces this assignment from the
/// repo-root VERSION file before `swift build`, and checks the result with
/// `--version`. `promptscope update` smoke-tests that same line.
let releaseVersion = "0.0.0-dev"

switch PromptscopeDispatch.dispatch(arguments, releaseVersion: releaseVersion) {
case .exit(let code, let out, let err):
    if !out.isEmpty { fputs(out, stdout) }
    if !err.isEmpty { fputs(err, stderr) }
    exit(code)
case .update(let args):
    runUpdate(args)
}

/// `promptscope update` is the Go updater installed beside this binary. It
/// replaces this file by renaming a new inode, which a running Mach-O cannot do
/// to itself. A `swift run` build has no sibling and says so.
func runUpdate(_ args: [String]) -> Never {
    guard let updater = installedUpdater() else {
        fail("promptscope update: promptscope-update not found next to this binary. Install with task cli:install or a release build.")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: updater)
    process.arguments = ["update"] + args
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fail("promptscope update: could not run \(updater): \(error)")
    }
    process.waitUntilExit()
    exit(process.terminationStatus)
}

func installedUpdater() -> String? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = executable.deletingLastPathComponent().appendingPathComponent("promptscope-update-\(releaseVersion)").path
    if FileManager.default.isExecutableFile(atPath: sibling) {
        return sibling
    }
    return nil
}
