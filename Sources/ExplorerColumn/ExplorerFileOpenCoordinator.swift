import Bonsplit
import CmuxGit
import Foundation

/// VS Code-style preview tabs for files opened from the Explorer column.
///
/// A single click opens a file in the workspace's one *preview* tab, replacing
/// the previous preview in place. A double click opens it *pinned*. A preview
/// becomes pinned on its own once it has unsaved edits or is moved to another
/// pane, so nothing the person is working on is ever replaced.
@MainActor
struct ExplorerFileOpenCoordinator {
    let state: ExplorerColumnState

    /// Opens a local file. Returns false when nothing could be opened.
    ///
    /// - Parameter focus: Select and focus the tab. Clicks in the column pass
    ///   true so the file shows; agent opens default to false so they never
    ///   hide the terminal the person is typing in.
    @discardableResult
    func open(path: String, workspace: Workspace, pane: PaneID, pin: Bool, focus: Bool) -> Bool {
        let panelIdsBeforeOpen = Set(workspace.panels.keys)
        let existingPanelId = workspace.panels.first { _, panel in Self.filePath(of: panel) == path }?.key
        var targetIndex: Int?
        var replacedPreviewId: UUID?

        if let previewId = state.previewPanelIdByWorkspace[workspace.id] {
            if let preview = workspace.panels[previewId],
               !preview.isDirty,
               workspace.paneId(forPanelId: previewId) == pane {
                if !pin, existingPanelId == nil, let index = Self.tabIndex(of: previewId, in: pane, workspace: workspace) {
                    // Replace the clean preview in place: open the new file just after it,
                    // then close the old one. Closing first would close a pane whose only
                    // tab is the preview (the follow-agent pane).
                    targetIndex = index + 1
                    replacedPreviewId = previewId
                }
            } else {
                // Edited, moved or closed: it is no longer a preview.
                state.previewPanelIdByWorkspace[workspace.id] = nil
            }
        }

        let opened = workspace.openFileSurfaces(
            inPane: pane,
            filePaths: [path],
            focus: focus,
            targetIndex: targetIndex,
            reuseExisting: true,
            duplicateWhenFocused: false
        )
        guard let panel = opened.first else { return false }
        if let replacedPreviewId, replacedPreviewId != panel.id {
            _ = workspace.closePanel(replacedPreviewId, force: true)
            state.previewPanelIdByWorkspace[workspace.id] = nil
        }

        if pin {
            if state.previewPanelIdByWorkspace[workspace.id] == panel.id {
                state.previewPanelIdByWorkspace[workspace.id] = nil
            }
        } else if !panelIdsBeforeOpen.contains(panel.id) {
            state.previewPanelIdByWorkspace[workspace.id] = panel.id
        }
        return true
    }

    /// Opens one file's change in a commit as a red/green diff tab. Like a
    /// preview, the next commit file clicked replaces it in place.
    @discardableResult
    func openCommitDiff(
        repositoryRoot: URL,
        commit: GitCommit,
        change: GitCommitFileChange,
        workspace: Workspace,
        pane: PaneID
    ) -> Bool {
        let path = repositoryRoot.appendingPathComponent(change.path).path
        var targetIndex: Int?
        var replacedPanelId: UUID?
        if let previousId = state.commitDiffPanelIdByWorkspace[workspace.id],
           workspace.panels[previousId] != nil,
           workspace.paneId(forPanelId: previousId) == pane,
           let index = Self.tabIndex(of: previousId, in: pane, workspace: workspace) {
            targetIndex = index + 1
            replacedPanelId = previousId
        }
        // Always a new tab: never take over a tab showing the file itself.
        guard let panel = workspace.openFilePreviewSurfaces(
            inPane: pane,
            filePaths: [path],
            focus: true,
            targetIndex: targetIndex,
            reuseExisting: false,
            duplicateWhenFocused: true
        ).first else { return false }
        panel.agentLiveDiff = AgentLiveDiffModel(
            filePath: path,
            source: .commit(
                repositoryRoot: repositoryRoot,
                sha: commit.sha,
                parentSHA: commit.parents.first,
                path: change.path,
                oldPath: change.oldPath
            )
        )
        if let replacedPanelId, replacedPanelId != panel.id {
            _ = workspace.closePanel(replacedPanelId, force: true)
        }
        state.commitDiffPanelIdByWorkspace[workspace.id] = panel.id
        return true
    }

    private static func filePath(of panel: any Panel) -> String? {
        if let preview = panel as? FilePreviewPanel { return preview.filePath }
        if let markdown = panel as? MarkdownPanel { return markdown.filePath }
        return nil
    }

    private static func tabIndex(of panelId: UUID, in pane: PaneID, workspace: Workspace) -> Int? {
        guard let tabId = workspace.surfaceIdFromPanelId(panelId) else { return nil }
        return workspace.bonsplitController.tabs(inPane: pane).firstIndex { $0.id == tabId }
    }
}
