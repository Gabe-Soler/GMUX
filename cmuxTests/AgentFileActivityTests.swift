import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Agent file activity")
struct AgentFileActivityTests {
    @Test("Claude edit tools mark their file_path; relative paths resolve against cwd")
    func claudeEditTools() {
        #expect(AgentToolFileTouchExtractor.editedPaths(
            toolName: "Edit", toolInputJSON: #"{"file_path":"/repo/src/a.swift","old_string":"x"}"#, cwd: "/repo"
        ) == ["/repo/src/a.swift"])
        #expect(AgentToolFileTouchExtractor.editedPaths(
            toolName: "Write", toolInputJSON: #"{"file_path":"src/b.swift","content":"..."}"#, cwd: "/repo"
        ) == ["/repo/src/b.swift"])
        #expect(AgentToolFileTouchExtractor.editedPaths(
            toolName: "NotebookEdit", toolInputJSON: #"{"notebook_path":"/repo/n.ipynb"}"#, cwd: nil
        ) == ["/repo/n.ipynb"])
    }

    @Test("Codex apply_patch marks every file header in the patch")
    func codexApplyPatch() {
        let patch = "*** Begin Patch\n*** Update File: src/a.swift\n@@\n-x\n+y\n*** Add File: docs/new.md\n+hi\n*** Delete File: old.txt\n*** End Patch"
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["input": patch]), encoding: .utf8)!
        #expect(AgentToolFileTouchExtractor.editedPaths(toolName: "apply_patch", toolInputJSON: json, cwd: "/repo") == [
            "/repo/src/a.swift", "/repo/docs/new.md", "/repo/old.txt",
        ])
    }

    @Test("Reads, searches and shell commands never mark files")
    func nonEditingToolsAreIgnored() {
        for tool in ["Read", "Grep", "Glob", "Bash", "WebFetch"] {
            #expect(AgentToolFileTouchExtractor.editedPaths(
                toolName: tool, toolInputJSON: #"{"file_path":"/repo/a.swift","command":"ls"}"#, cwd: "/repo"
            ).isEmpty)
        }
        #expect(AgentToolFileTouchExtractor.editedPaths(toolName: "Edit", toolInputJSON: "not json", cwd: "/repo").isEmpty)
    }

    @Test("Marks roll up to folders and expire after their lifetime")
    func rollupAndExpiry() {
        var activity = AgentFileActivity()
        let workspace = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        activity.record(paths: ["/repo/src/app/a.swift"], agent: "Claude", workspaceId: workspace, at: start)

        let file = activity.touch(for: "/repo/src/app/a.swift", isDirectory: false, workspaceId: workspace, now: start)
        #expect(file?.agent == "Claude")
        #expect(activity.touch(for: "/repo/src", isDirectory: true, workspaceId: workspace, now: start) != nil)
        #expect(activity.touch(for: "/repo/docs", isDirectory: true, workspaceId: workspace, now: start) == nil)
        #expect(activity.touch(for: "/repo/src/app/a.swift", isDirectory: false, workspaceId: UUID(), now: start) == nil)

        let later = start.addingTimeInterval(AgentFileActivity.lifetime + 1)
        #expect(activity.touch(for: "/repo/src/app/a.swift", isDirectory: false, workspaceId: workspace, now: later) == nil)
        #expect(activity.touch(for: "/repo/src", isDirectory: true, workspaceId: workspace, now: later) == nil)
    }

    @Test("Each workspace keeps only its newest files")
    func boundedPerWorkspace() {
        var activity = AgentFileActivity()
        let workspace = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0...AgentFileActivity.maximumFilesPerWorkspace {
            activity.record(
                paths: ["/repo/f\(index)"], agent: "Codex", workspaceId: workspace,
                at: start.addingTimeInterval(TimeInterval(index))
            )
        }
        // Still inside every mark's lifetime, so only the cap can drop f0.
        let now = start.addingTimeInterval(600)
        let recent = activity.recentFiles(workspaceId: workspace, now: now)
        #expect(recent.count == AgentFileActivity.maximumFilesPerWorkspace)
        #expect(recent.first?.path == "/repo/f\(AgentFileActivity.maximumFilesPerWorkspace)")
        #expect(activity.touch(for: "/repo/f0", isDirectory: false, workspaceId: workspace, now: now) == nil)
    }
}
