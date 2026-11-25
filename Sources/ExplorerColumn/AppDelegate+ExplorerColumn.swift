import AppKit

/// One mutation path for the GMUX Explorer column, shared by the menu, the
/// command palette and (later) the CLI.
extension AppDelegate {
    func explorerColumnState(preferredWindow: NSWindow? = nil) -> ExplorerColumnState? {
        preferredRegisteredMainWindowContext(preferredWindow: preferredWindow)?.explorerColumnState
    }

    @discardableResult
    func toggleExplorerColumnInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let state = explorerColumnState(preferredWindow: preferredWindow) else { return false }
        state.toggle()
        return true
    }

    /// Routes agent hook events to the Explorer of the window owning their
    /// workspace. JSON parsing of tool input happens off the main actor.
    func installExplorerAgentActivityObserverIfNeeded() {
        guard FeedCoordinator.shared.agentToolEventObserver == nil else { return }
        FeedCoordinator.shared.agentToolEventObserver = { event in
            guard event.hookEventName == .preToolUse || event.hookEventName == .postToolUse,
                  event.toolName != nil,
                  let workspaceRaw = event.workspaceId,
                  let workspaceId = UUID(uuidString: workspaceRaw) else { return }
            let toolName = event.toolName, input = event.toolInputJSON, cwd = event.cwd
            let agentPanelId = event.surfaceId.flatMap(UUID.init(uuidString:))
            let agent = event.source.isEmpty ? "agent" : event.source.capitalized
            Task.detached(priority: .utility) {
                let paths = AgentToolFileTouchExtractor.editedPaths(toolName: toolName, toolInputJSON: input, cwd: cwd)
                guard !paths.isEmpty else { return }
                await MainActor.run {
                    guard let appDelegate = AppDelegate.shared,
                          let tabManager = appDelegate.tabManagerFor(tabId: workspaceId),
                          let state = appDelegate.mainWindowContext(for: tabManager)?.explorerColumnState,
                          let store = state.attachedStore
                    else { return }
                    store.recordAgentEdits(paths: paths, agent: agent, workspaceId: workspaceId)
                    if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
                        for path in paths {
                            ExplorerFollowAgent.enqueue(
                                path: path, agent: agent, workspace: workspace,
                                agentPanelId: agentPanelId, state: state
                            )
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    func setExplorerColumnVisibleInActiveMainWindow(_ visible: Bool, preferredWindow: NSWindow? = nil) -> Bool {
        guard let state = explorerColumnState(preferredWindow: preferredWindow) else { return false }
        state.isVisible = visible
        return true
    }
}
