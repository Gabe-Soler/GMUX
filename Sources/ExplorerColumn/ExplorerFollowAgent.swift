import Bonsplit
import Foundation

/// Follow-agent mode: every file an agent edits opens as a live diff (red
/// removals, green additions, animated line by line) in panes beside the
/// agent's terminal. Up to ``maximumStackedPanes`` files are visible at once,
/// stacked; further files open as tabs. Keyboard focus never moves, so typing
/// to the agent is never interrupted.
@MainActor
enum ExplorerFollowAgent {
    struct Pending {
        let path: String
        let agent: String
        let agentPanelId: UUID?
        weak var workspace: Workspace?
    }

    static let maximumStackedPanes = 3
    /// A file an agent is about to create may not exist yet (PreToolUse fires first).
    static let creationWait: Duration = .milliseconds(250)
    static let creationAttempts = 8

    static func enqueue(
        path: String,
        agent: String,
        workspace: Workspace,
        agentPanelId: UUID?,
        state: ExplorerColumnState
    ) {
        guard state.followAgent, state.isVisible else { return }
        // A file already showing live updates itself from disk; nothing to open.
        if liveDiffPanel(for: path, in: workspace) != nil { return }
        guard !state.followPending.contains(where: { $0.path == path }) else { return }
        state.followPending.append(Pending(path: path, agent: agent, agentPanelId: agentPanelId, workspace: workspace))
        guard state.followTask == nil else { return }
        state.followTask = Task { @MainActor [weak state] in
            while let state, !state.followPending.isEmpty {
                let pending = state.followPending.removeFirst()
                await show(pending, state: state)
            }
            state?.followTask = nil
        }
    }

    private static func show(_ pending: Pending, state: ExplorerColumnState) async {
        guard let workspace = pending.workspace else { return }
        // Wait briefly for a file the agent is creating; the diff also handles
        // a missing file, but a new pane for a path never written is noise.
        var attempts = 0
        while !FileManager.default.fileExists(atPath: pending.path), attempts < creationAttempts {
            attempts += 1
            try? await Task.sleep(for: creationWait)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pending.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              // Only the workspace the person is looking at; never switch views.
              workspace.owningTabManager?.selectedTabId == workspace.id,
              state.followAgent,
              liveDiffPanel(for: pending.path, in: workspace) == nil else { return }

        guard let panel = openPanel(for: pending, in: workspace, state: state) else { return }
        panel.agentLiveDiff = AgentLiveDiffModel(filePath: pending.path, agent: pending.agent)
        if let store = state.attachedStore, store.workspaceRootIdentity == workspace.id {
            _ = await store.reveal(path: pending.path)
        }
    }

    /// Opens a pane (or tab) for the file without taking focus.
    private static func openPanel(for pending: Pending, in workspace: Workspace, state: ExplorerColumnState) -> FilePreviewPanel? {
        let controller = workspace.bonsplitController
        var panes = (state.followPanesByWorkspace[workspace.id] ?? []).filter { controller.allPaneIds.contains($0) }
        defer { state.followPanesByWorkspace[workspace.id] = panes }

        if panes.count < maximumStackedPanes {
            let splitResult: FilePreviewPanel?
            if let lastPane = panes.last {
                // Stack the next file under the previous one.
                splitResult = workspace.splitPaneWithFilePreview(
                    targetPane: lastPane, orientation: .vertical, insertFirst: false,
                    filePath: pending.path, focus: false
                )
            } else {
                let sourcePanelId = pending.agentPanelId.flatMap { workspace.panels[$0] != nil ? $0 : nil }
                    ?? workspace.focusedPanelId
                splitResult = sourcePanelId
                    .flatMap { workspace.paneId(forPanelId: $0) }
                    .flatMap { sourcePane in
                        workspace.splitPaneWithFilePreview(
                            targetPane: sourcePane, orientation: .horizontal, insertFirst: false,
                            filePath: pending.path, focus: false
                        )
                    }
            }
            if let panel = splitResult, let pane = workspace.paneId(forPanelId: panel.id) {
                panes.append(pane)
                return panel
            }
        }
        // Full (or no room to split): add a tab to the follow pane edited longest ago.
        guard let pane = panes.first else { return nil }
        panes.append(panes.removeFirst())
        return workspace.openFilePreviewSurfaces(
            inPane: pane, filePaths: [pending.path], focus: false, reuseExisting: false
        ).first
    }

    private static func liveDiffPanel(for path: String, in workspace: Workspace) -> FilePreviewPanel? {
        workspace.panels.values.lazy
            .compactMap { $0 as? FilePreviewPanel }
            .first { $0.agentLiveDiff != nil && $0.filePath == path }
    }
}
