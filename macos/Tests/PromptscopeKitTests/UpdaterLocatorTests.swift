import Foundation
import XCTest
import PromptscopeKit

/// Sibling lookup for `promptscope update`. Files live under a temp directory.
/// These tests do not touch the network or the real home.
final class UpdaterLocatorTests: XCTestCase {
    func testFindsHelperThroughRelativeSymlink() throws {
        let version = "0.1.8"
        let layout = try makeLayout(version: version, helperVersion: version)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: layout.link.path)
        XCTAssertFalse((destination as NSString).isAbsolutePath)

        let found = try XCTUnwrap(
            UpdaterLocator.find(executablePath: layout.link.path, releaseVersion: version)
        )
        XCTAssertEqual(canonical(found), canonical(layout.helper.path))

        let direct = try XCTUnwrap(
            UpdaterLocator.find(executablePath: layout.binary.path, releaseVersion: version)
        )
        XCTAssertEqual(canonical(direct), canonical(layout.helper.path))
    }

    func testMissingHelperReturnsNil() throws {
        let version = "0.1.8"
        let layout = try makeLayout(version: version, helperVersion: nil)
        XCTAssertNil(UpdaterLocator.find(executablePath: layout.link.path, releaseVersion: version))
        XCTAssertEqual(
            canonical(UpdaterLocator.searchedPath(executablePath: layout.link.path, releaseVersion: version)),
            canonical(layout.helperDirectory.appendingPathComponent("promptscope-update-\(version)").path)
        )
    }

    func testDifferentVersionHelperReturnsNil() throws {
        let layout = try makeLayout(version: "0.1.8", helperVersion: "0.1.7")
        XCTAssertNil(UpdaterLocator.find(executablePath: layout.link.path, releaseVersion: "0.1.8"))
        XCTAssertNotNil(
            UpdaterLocator.find(executablePath: layout.link.path, releaseVersion: "0.1.7")
        )
    }

    private struct Layout {
        var binary: URL
        var helper: URL
        var helperDirectory: URL
        var link: URL
    }

    /// `root/.local/bin/promptscope` -> `../share/promptscope/bin/promptscope-<version>`,
    /// matching `~/.local/bin` beside `~/.local/share/promptscope/bin`.
    private func makeLayout(version: String, helperVersion: String?) throws -> Layout {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("promptscope-updater-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".local/share/promptscope/bin", isDirectory: true)
        let linkDir = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let binary = bin.appendingPathComponent("promptscope-\(version)")
        try Data("cli".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let helperName = "promptscope-update-\(helperVersion ?? version)"
        let helper = bin.appendingPathComponent(helperName)
        if helperVersion != nil {
            try Data("updater".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        }

        let link = linkDir.appendingPathComponent("promptscope")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../share/promptscope/bin/promptscope-\(version)"
        )
        return Layout(binary: binary, helper: helper, helperDirectory: bin, link: link)
    }

    /// Resolves symlinks in the parent. The last component may not exist yet.
    private func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).path
    }
}
