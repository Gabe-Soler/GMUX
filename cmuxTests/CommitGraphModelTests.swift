import CmuxGit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A throwaway repository for graph and commit-diff tests.
private final class GraphTestRepository {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmux-graph-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-b", "main")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", message)
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GraphTestRepository", code: Int(process.terminationStatus))
        }
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return true
}

@MainActor
@Suite("Commit graph")
struct CommitGraphModelTests {
    @Test("Loads the branch and history of the folder's repository, and the files of a commit")
    func loadsBranchHistoryAndFiles() async throws {
        let repo = try GraphTestRepository()
        try repo.write("a.txt", "one\n")
        try repo.commit("first")
        try repo.write("src/b.txt", "two\n")
        try repo.commit("second")

        let model = CommitGraphModel()
        model.isGraphVisible = true
        model.setRoot(path: repo.root.appendingPathComponent("src").path, isLocal: true)

        #expect(await waitUntil { model.rows.count == 2 && model.branchStatus != nil })
        #expect(model.availability == .ready)
        #expect(model.branchStatus?.branch == "main")
        #expect(model.rows.map(\.commit.subject) == ["second", "first"])

        model.toggleExpanded(model.rows[0].commit)
        #expect(await waitUntil { !model.expandedFiles.isEmpty })
        #expect(model.expandedFiles == [GitCommitFileChange(status: .added, path: "src/b.txt")])

        model.toggleExpanded(model.rows[0].commit)
        #expect(model.expandedSHA == nil)
    }

    @Test("A new commit made outside the app shows up on its own")
    func refreshesOnNewCommit() async throws {
        let repo = try GraphTestRepository()
        try repo.write("a.txt", "one\n")
        try repo.commit("first")

        let model = CommitGraphModel()
        model.isGraphVisible = true
        model.setRoot(path: repo.root.path, isLocal: true)
        #expect(await waitUntil { model.rows.count == 1 })

        try repo.write("a.txt", "one\ntwo\n")
        try repo.commit("second")
        #expect(await waitUntil { model.rows.first?.commit.subject == "second" })
    }

    @Test("Folders outside a repository and remote folders say so")
    func availabilityStates() async throws {
        let model = CommitGraphModel()
        model.setRoot(path: "/some/remote/path", isLocal: false)
        #expect(model.availability == .remote)

        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("gmux-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        model.setRoot(path: plain.path, isLocal: true)
        #expect(await waitUntil { model.availability == .notARepository })
    }

    @Test("A commit file diff shows the commit's removals and additions against its parent")
    func commitFileDiff() async throws {
        let repo = try GraphTestRepository()
        try repo.write("a.txt", "keep\nold\n")
        try repo.commit("first")
        try repo.write("a.txt", "keep\nnew\n")
        try repo.commit("second")

        let service = GitHistoryService()
        let commits = service.log(repositoryRoot: repo.root)
        let second = try #require(commits.first)
        let diff = AgentLiveDiffModel(
            filePath: repo.root.appendingPathComponent("a.txt").path,
            source: .commit(
                repositoryRoot: repo.root, sha: second.sha, parentSHA: second.parents.first,
                path: "a.txt", oldPath: nil
            )
        )
        #expect(await waitUntil { !diff.rows.isEmpty })
        #expect(diff.rows.map(\.text) == ["keep", "old", "new"])
        #expect(diff.rows.map(\.kind) == [.unchanged, .removed, .added])
        #expect(diff.commitSHA == second.sha)
        #expect(diff.hiddenIds.isEmpty)
    }

    @Test("A deleted file's diff is all removals; a root commit's is all additions")
    func deletedAndRootFileDiffs() async throws {
        let repo = try GraphTestRepository()
        try repo.write("gone.txt", "x\ny\n")
        try repo.commit("first")
        try repo.git("rm", "-q", "gone.txt")
        try repo.commit("delete")

        let commits = GitHistoryService().log(repositoryRoot: repo.root)
        let deletion = commits[0]
        let root = commits[1]
        let deleted = AgentLiveDiffModel(
            filePath: repo.root.appendingPathComponent("gone.txt").path,
            source: .commit(repositoryRoot: repo.root, sha: deletion.sha, parentSHA: deletion.parents.first, path: "gone.txt", oldPath: nil)
        )
        let added = AgentLiveDiffModel(
            filePath: repo.root.appendingPathComponent("gone.txt").path,
            source: .commit(repositoryRoot: repo.root, sha: root.sha, parentSHA: nil, path: "gone.txt", oldPath: nil)
        )
        #expect(await waitUntil { !deleted.rows.isEmpty && !added.rows.isEmpty })
        #expect(deleted.rows.allSatisfy { $0.kind == .removed })
        #expect(added.rows.allSatisfy { $0.kind == .added })
    }
}
