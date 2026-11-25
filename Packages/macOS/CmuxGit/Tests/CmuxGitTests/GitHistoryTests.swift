import Foundation
import Testing
@testable import CmuxGit

@Suite struct GitLogParserTests {
    @Test func parsesCommitsWithDecorationsAndParents() {
        let raw = "aaa\0bbb ccc\0Ada\0ada@example.com\01700000000\0HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1.0\0Merge feature\u{1e}\n"
            + "bbb\0\0Bo\0bo@example.com\01699999999\0\0First, with a comma\u{1e}\n"
        let commits = GitLogParser.commits(from: Data(raw.utf8))
        #expect(commits.count == 2)
        #expect(commits[0].parents == ["bbb", "ccc"])
        #expect(commits[0].refs == [
            GitRefLabel(kind: .head, name: "main"),
            GitRefLabel(kind: .remoteBranch, name: "origin/main"),
            GitRefLabel(kind: .tag, name: "v1.0"),
        ])
        #expect(commits[0].date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(commits[1].parents.isEmpty)
        #expect(commits[1].refs.isEmpty)
        #expect(commits[1].subject == "First, with a comma")
    }

    @Test func detachedHeadIsAHeadLabel() {
        #expect(GitLogParser.refLabels(fromDecoration: "HEAD, refs/heads/topic") == [
            GitRefLabel(kind: .head, name: "HEAD"),
            GitRefLabel(kind: .localBranch, name: "topic"),
        ])
    }

    @Test func parsesNameStatusIncludingRenames() {
        let raw = "M\0src/a.swift\0R087\0old/name.txt\0new/name.txt\0A\0added.md\0D\0gone.c\0"
        #expect(GitLogParser.fileChanges(from: Data(raw.utf8)) == [
            GitCommitFileChange(status: .modified, path: "src/a.swift"),
            GitCommitFileChange(status: .renamed, path: "new/name.txt", oldPath: "old/name.txt"),
            GitCommitFileChange(status: .added, path: "added.md"),
            GitCommitFileChange(status: .deleted, path: "gone.c"),
        ])
    }

    @Test func parsesPorcelainV2BranchHeader() {
        let raw = "# branch.oid 0123abc\0# branch.head feature/x\0# branch.upstream origin/feature/x\0# branch.ab +2 -5\01 .M N... 100644 100644 100644 abc abc file.txt\0"
        let status = GitLogParser.branchStatus(from: Data(raw.utf8))
        #expect(status.branch == "feature/x")
        #expect(status.headSHA == "0123abc")
        #expect(status.upstream == "origin/feature/x")
        #expect(status.ahead == 2)
        #expect(status.behind == 5)
        #expect(status.hasTrackedChanges)
        #expect(!status.isDetached)

        let detached = GitLogParser.branchStatus(from: Data("# branch.oid 0123abc\0# branch.head (detached)\0".utf8))
        #expect(detached.isDetached)
        #expect(!detached.hasTrackedChanges)
    }
}

@Suite struct CommitGraphLayoutTests {
    private func commit(_ sha: String, _ parents: [String] = []) -> GitCommit {
        GitCommit(sha: sha, parents: parents, authorName: "", authorEmail: "", date: .distantPast, subject: sha, refs: [])
    }

    @Test func linearHistoryStaysInOneLane() {
        var layout = CommitGraphLayout()
        let rows = layout.append([commit("c", ["b"]), commit("b", ["a"]), commit("a")])
        #expect(rows.map(\.lane) == [0, 0, 0])
        #expect(Set(rows.map(\.colorIndex)).count == 1)
        // The tip has no line above it; the root has none below.
        #expect(rows[0].top.isEmpty)
        #expect(rows[2].bottom.isEmpty)
        #expect(rows[1].top == [CommitGraphSegment(from: 0, to: 0, colorIndex: rows[0].colorIndex)])
    }

    @Test func branchAndMergeUseASecondLane() {
        // m merges f into b; f branched from a.
        var layout = CommitGraphLayout()
        let rows = layout.append([
            commit("m", ["b", "f"]),
            commit("f", ["a"]),
            commit("b", ["a"]),
            commit("a"),
        ])
        #expect(rows.map(\.lane) == [0, 1, 0, 0])
        // The merge commit opens a lane for its second parent.
        #expect(rows[0].bottom.contains(CommitGraphSegment(from: 0, to: 1, colorIndex: rows[1].colorIndex)))
        #expect(rows[0].colorIndex != rows[1].colorIndex)
        // Both lines wait for `a`, so they join below `b` and run on as one.
        #expect(rows[2].bottom.map(\.to) == [0, 0])
        #expect(rows[2].laneCount == 2)
        #expect(rows[3].top == [CommitGraphSegment(from: 0, to: 0, colorIndex: rows[2].colorIndex)])
    }

    @Test func pagesContinueTheirLanes() {
        var layout = CommitGraphLayout()
        let first = layout.append([commit("m", ["b", "f"]), commit("b", ["a"])])
        let second = layout.append([commit("f", ["a"]), commit("a")])
        #expect(first.map(\.lane) == [0, 0])
        #expect(second.map(\.lane) == [1, 0])
    }

    @Test func octopusMergeOpensALanePerExtraParent() {
        var layout = CommitGraphLayout()
        let rows = layout.append([commit("o", ["a", "b", "c"]), commit("c"), commit("b"), commit("a")])
        #expect(rows[0].bottom.map(\.to).sorted() == [0, 1, 2])
        #expect(rows[0].laneCount == 3)
    }

    @Test func colorsCycleThroughThePalette() {
        var layout = CommitGraphLayout()
        let tips = (0..<(CommitGraphLayout.colorCount + 1)).map { commit("t\($0)") }
        let rows = layout.append(tips)
        #expect(rows.first?.colorIndex == rows.last?.colorIndex)
    }
}

@Suite struct GitHistoryServiceTests {
    @Test func readsHistoryFilesBranchesAndSwitches() throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("a.txt", "one\ntwo\n")
        try repo.git(["add", "a.txt"])
        try repo.commit("first")
        try repo.git(["switch", "-c", "feature"])
        try repo.git(["mv", "a.txt", "b.txt"])
        try repo.write("c.txt", "new\n")
        try repo.git(["add", "c.txt"])
        try repo.commit("rename and add")
        try repo.git(["switch", "main"])
        try repo.git(["tag", "v1"])

        let service = GitHistoryService()
        let root = try #require(service.repositoryRoot(containing: repo.root))

        let commits = service.log(repositoryRoot: root)
        #expect(commits.map(\.subject) == ["first"])
        #expect(commits[0].refs.contains(GitRefLabel(kind: .head, name: "main")))
        #expect(commits[0].refs.contains(GitRefLabel(kind: .tag, name: "v1")))

        let branches = service.branches(repositoryRoot: root)
        #expect(Set(branches.map(\.name)) == ["main", "feature"])

        let feature = try #require(branches.first { $0.name == "feature" })
        try service.switchBranch(repositoryRoot: root, to: feature)
        let status = try #require(service.branchStatus(repositoryRoot: root))
        #expect(status.branch == "feature")
        #expect(!status.hasTrackedChanges)

        let featureLog = service.log(repositoryRoot: root)
        #expect(featureLog.map(\.subject) == ["rename and add", "first"])
        let files = service.changedFiles(repositoryRoot: root, commit: featureLog[0])
        #expect(files.contains(GitCommitFileChange(status: .renamed, path: "b.txt", oldPath: "a.txt")))
        #expect(files.contains(GitCommitFileChange(status: .added, path: "c.txt")))
        #expect(service.changedFiles(repositoryRoot: root, commit: featureLog[1])
            == [GitCommitFileChange(status: .added, path: "a.txt")])

        #expect(service.fileContents(repositoryRoot: root, revision: featureLog[0].sha, path: "b.txt") == "one\ntwo\n")
        #expect(service.fileContents(repositoryRoot: root, revision: featureLog[1].sha, path: "b.txt") == nil)
    }

    @Test func switchBlockedByLocalChangesReportsGitsReason() throws {
        let repo = try WorkspaceChangesGitRepositoryFixture()
        try repo.write("a.txt", "one\n")
        try repo.git(["add", "a.txt"])
        try repo.commit("first")
        try repo.git(["switch", "-c", "other"])
        try repo.write("a.txt", "other\n")
        try repo.git(["add", "a.txt"])
        try repo.commit("other change")
        try repo.git(["switch", "main"])
        try repo.write("a.txt", "uncommitted\n")

        let service = GitHistoryService()
        let other = try #require(service.branches(repositoryRoot: repo.root).first { $0.name == "other" })
        #expect(throws: GitHistoryService.SwitchError.self) {
            try service.switchBranch(repositoryRoot: repo.root, to: other)
        }
        #expect(service.branchStatus(repositoryRoot: repo.root)?.branch == "main")
    }
}
