import AppKit
import Foundation

/// `files.*` v2 socket methods: agents drive the Explorer column the person sees.
///
/// Every method runs on the main actor and reads only the tree's loaded state,
/// so none of them touches the filesystem on the main thread. None of them
/// changes window, workspace or keyboard focus. They are not on the remote
/// relay allowlist, so `cmux ssh` sessions cannot reach local tree state.
extension TerminalController {
    static let explorerFilesMethods: [String] = [
        "files.state", "files.tree", "files.reveal", "files.open",
        "files.show", "files.hide", "files.toggle", "files.follow",
    ]

    @MainActor
    func v2Files(method: String, params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params),
              let state = AppDelegate.shared?.mainWindowContext(for: tabManager)?.explorerColumnState else {
            return .err(code: "unavailable", message: "Explorer column not available", data: nil)
        }
        switch method {
        case "files.show":
            state.isVisible = true
            return .ok(["visible": true])
        case "files.hide":
            state.isVisible = false
            return .ok(["visible": false])
        case "files.toggle":
            state.toggle()
            return .ok(["visible": state.isVisible])
        case "files.follow":
            if let enabled = v2Bool(params, "enabled") { state.followAgent = enabled }
            return .ok(["follow": state.followAgent])
        default:
            break
        }

        guard let store = state.attachedStore else {
            if method == "files.state" { return .ok(["visible": state.isVisible, "root": NSNull()]) }
            return .err(code: "unavailable", message: "Explorer is not loaded yet; run 'cmux files show' first", data: nil)
        }
        let selectedWorkspace = tabManager.selectedWorkspace
        if let requested = v2UUID(params, "workspace_id"), requested != selectedWorkspace?.id {
            // The tree shows the selected workspace only; never switch the person's view for an agent.
            return .ok(["applied": false, "reason": "workspace_not_selected"])
        }

        switch method {
        case "files.state":
            return .ok(filesStatePayload(state: state, store: store, workspace: selectedWorkspace))
        case "files.tree":
            let depth = max(1, min(v2Int(params, "depth") ?? 3, 32))
            let limit = max(1, min(v2Int(params, "max_entries") ?? 500, 5_000))
            return .ok(filesTreePayload(store: store, depth: depth, limit: limit))
        case "files.reveal", "files.open":
            guard let raw = v2String(params, "path"), !raw.isEmpty else {
                return .err(code: "invalid_params", message: "Missing 'path' parameter", data: nil)
            }
            guard !store.rootPath.isEmpty else {
                return .err(code: "unavailable", message: "Explorer has no folder yet", data: nil)
            }
            let path = Self.explorerAbsolutePath(raw, root: store.rootPath)
            let revealInTree = method == "files.reveal" || v2Bool(params, "reveal") != false
            if method == "files.open" {
                guard FileManager.default.fileExists(atPath: path),
                      let workspace = selectedWorkspace,
                      let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
                    return .err(code: "not_found", message: "File or pane not found", data: ["path": path])
                }
                let pin = v2Bool(params, "pin") ?? false
                let select = v2Bool(params, "select") ?? false
                guard ExplorerFileOpenCoordinator(state: state).open(
                    path: path, workspace: workspace, pane: pane, pin: pin, focus: select
                ) else {
                    return .err(code: "internal_error", message: "Failed to open file", data: ["path": path])
                }
            }
            if revealInTree {
                if v2Bool(params, "show") != false { state.isVisible = true }
                Task { @MainActor [weak store] in _ = await store?.reveal(path: path) }
            }
            return .ok(["applied": true, "path": path, "root": store.rootPath])
        default:
            return .err(code: "method_not_found", message: "Unknown files method", data: ["method": method])
        }
    }

    private func filesStatePayload(
        state: ExplorerColumnState,
        store: FileExplorerStore,
        workspace: Workspace?
    ) -> [String: Any] {
        var previewPath: Any = NSNull()
        if let workspace,
           let previewId = state.previewPanelIdByWorkspace[workspace.id],
           let panel = workspace.panels[previewId] {
            previewPath = (panel as? FilePreviewPanel)?.filePath ?? (panel as? MarkdownPanel)?.filePath ?? NSNull()
        }
        let now = Date()
        let agentEdits: [[String: Any]] = workspace.map { workspace in
            store.agentActivity.recentFiles(workspaceId: workspace.id, now: now).prefix(50).map { entry in
                [
                    "path": entry.path,
                    "agent": entry.touch.agent,
                    "seconds_ago": Int(now.timeIntervalSince(entry.touch.lastAt)),
                ]
            }
        } ?? []
        return [
            "visible": state.isVisible,
            "follow": state.followAgent,
            "agent_edits": agentEdits,
            "root": store.rootPath,
            "selected": store.selectedPath ?? NSNull(),
            "expanded": store.expandedPaths.sorted(),
            "preview": previewPath,
        ]
    }

    /// The tree as the person sees it: loaded folders only, with git markers.
    private func filesTreePayload(store: FileExplorerStore, depth: Int, limit: Int) -> [String: Any] {
        var entries: [[String: Any]] = []
        var truncated = false
        func visit(_ nodes: [FileExplorerNode], level: Int) {
            for node in nodes {
                guard entries.count < limit else { truncated = true; return }
                var entry: [String: Any] = [
                    "path": node.path,
                    "name": node.name,
                    "depth": level,
                    "type": node.isDirectory ? "directory" : "file",
                ]
                if let status = FileExplorerGitStatusLookup.status(
                    for: node.path, in: store.gitStatusByPath, rootPath: store.rootPath
                ) {
                    entry["git"] = Self.explorerGitLabel(status)
                }
                if node.isDirectory {
                    entry["expanded"] = store.expandedPaths.contains(node.path)
                    entry["loaded"] = node.children != nil
                }
                entries.append(entry)
                if level + 1 < depth, let children = node.sortedChildren, store.expandedPaths.contains(node.path) {
                    visit(children, level: level + 1)
                }
            }
        }
        visit(store.rootNodes, level: 0)
        return ["root": store.rootPath, "entries": entries, "truncated": truncated]
    }

    static func explorerAbsolutePath(_ raw: String, root: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (root as NSString).appendingPathComponent(expanded)
        // Collapse "." and ".." only; NSString.standardizingPath would also drop
        // a "/private" prefix and stop matching the tree's root spelling.
        return URL(fileURLWithPath: absolute).standardized.path
    }

    static func explorerGitLabel(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        case .ignored: "ignored"
        }
    }
}
