import Testing
import Foundation
@testable import MarkMark

@Suite("GitService HEAD baseline")
struct GitServiceTests {

    private func sh(_ dir: URL, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }

    @Test("returns the committed version of a tracked file, nil otherwise")
    func headText() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("doc.md")
        try "committed\n".write(to: file, atomically: true, encoding: .utf8)
        try sh(dir, ["init", "-q"])
        try sh(dir, ["add", "doc.md"])
        try sh(dir, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"])
        try "edited\n".write(to: file, atomically: true, encoding: .utf8)

        #expect(await GitService.headText(of: file) == "committed\n")

        let untracked = dir.appendingPathComponent("new.md")
        try "x".write(to: untracked, atomically: true, encoding: .utf8)
        #expect(await GitService.headText(of: untracked) == nil)
    }

    @Test("files outside any repository have no HEAD version")
    func outsideRepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mm-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(await GitService.headText(of: file) == nil)
    }
}
