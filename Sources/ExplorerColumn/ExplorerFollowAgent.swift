import Bonsplit
import Foundation

/// Follow-agent mode: each file an agent edits opens in a "follow pane" beside
/// the agent's terminal, replacing the previous one, and is revealed in the
/// Explorer. Keyboard focus never moves, so typing to the agent is never
/// interrupted. The open file refreshes from disk as each edit lands.
@MainActor
enum ExplorerFollowAgent {
    struct Pending {
        let path: String
        let agentPanelId: UUID?
        weak var workspace: Workspace?
    }

    /// Bursts of edits collapse into one jump at most this often.
    static let minimumInterval: Duration = .milliseconds(600)
    /// A file an agent is about to create may not exist yet (PreToolUse fires first).
    static let creationWait: Duration = .milliseconds(250)
    static let creationAttempts = 8

    static func enqueue(path: String, workspace: Workspace, agentPanelId: UUID?, state: ExplorerColumnState) {
        guard state.followAgent, state.isVisible else { return }
        state.followPending = Pending(path: path, agentPanelId: agentPanelId, workspace: workspace)
        guard state.followTask == nil else { return }
        state.followTask = Task { @MainActor [weak state] in
            while let state, let pending = state.followPending {
                state.followPending = nil
                await show(pending, state: state)
                try? await Task.sleep(for: minimumInterval)
            }
            state?.followTask = nil
        }
    }

    private static func show(_ pending: Pending, state: ExplorerColumnState) async {
        guard let workspace = pending.workspace else { return }
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
              state.followAgent else { return }

        open(pending.path, in: workspace, agentPanelId: pending.agentPanelId, state: state)
        if let store = state.attachedStore, store.workspaceRootIdentity == workspace.id {
            _ = await store.reveal(path: pending.path)
        }
    }

    private static func open(_ path: String, in workspace: Workspace, agentPanelId: UUID?, state: ExplorerColumnState) {
        let opener = ExplorerFileOpenCoordinator(state: state)
        let controller = workspace.bonsplitController
        if let pane = state.followPaneByWorkspace[workspace.id], controller.allPaneIds.contains(pane) {
            opener.open(path: path, workspace: workspace, pane: pane, pin: false, focus: false)
            return
        }
        let sourcePanelId = agentPanelId.flatMap { workspace.panels[$0] != nil ? $0 : nil } ?? workspace.focusedPanelId
        guard let sourcePanelId else { return }
        // Reuse a pane already to the right of the agent (as Cmd-click does), else split one off.
        if let rightPane = workspace.preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            state.followPaneByWorkspace[workspace.id] = rightPane
            opener.open(path: path, workspace: workspace, pane: rightPane, pin: false, focus: false)
            return
        }
        guard let sourcePane = workspace.paneId(forPanelId: sourcePanelId),
              let panel = workspace.splitPaneWithFilePreview(
                  targetPane: sourcePane,
                  orientation: .horizontal,
                  insertFirst: false,
                  filePath: path,
                  focus: false
              ) else { return }
        state.followPaneByWorkspace[workspace.id] = workspace.paneId(forPanelId: panel.id)
        state.previewPanelIdByWorkspace[workspace.id] = panel.id
    }
}
