import Darwin
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
    let executable = currentExecutablePath()
    guard let updater = UpdaterLocator.find(executablePath: executable, releaseVersion: releaseVersion) else {
        let searched = UpdaterLocator.searchedPath(executablePath: executable, releaseVersion: releaseVersion)
        fail("promptscope update: promptscope-update not found next to this binary (searched \(searched)). Install with task cli:install or a release build.")
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

/// Path the kernel executed. `CommandLine.arguments[0]` is only `promptscope`
/// when the shell searched `PATH`, and that bare name is resolved against the
/// working directory. Falls back to the bundle path, then argv[0].
func currentExecutablePath() -> String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    let first = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
        guard let base = pointer.baseAddress else { return -1 }
        return _NSGetExecutablePath(base, &size)
    }
    if first == 0 {
        return pathFromCString(buffer)
    }
    if size > 0 {
        var retry = [CChar](repeating: 0, count: Int(size))
        let second = retry.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return _NSGetExecutablePath(base, &size)
        }
        if second == 0 {
            return pathFromCString(retry)
        }
    }
    if let path = Bundle.main.executablePath {
        return path
    }
    return CommandLine.arguments.first ?? "promptscope"
}

func pathFromCString(_ bytes: [CChar]) -> String {
    let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: utf8, as: UTF8.self)
}
