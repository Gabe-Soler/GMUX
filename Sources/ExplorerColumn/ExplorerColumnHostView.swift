import AppKit
import CmuxAppKitSupportUI
import CmuxGit
import SwiftUI

/// Lays out `[Explorer column | terminal content]` and gives the column only the
/// width the terminal can spare. Only this view reads the column's width, so a
/// resize drag never re-renders `ContentView`.
struct ExplorerColumnLayout<Column: View, Terminal: View>: View {
    let state: ExplorerColumnState
    let minimumTerminalWidth: CGFloat
    @ViewBuilder let column: (CGFloat) -> Column
    @ViewBuilder let terminal: () -> Terminal

    @State private var availableWidth: CGFloat = .infinity

    var body: some View {
        let width = ExplorerColumnState.renderedWidth(
            preferred: state.width,
            isVisible: state.isVisible,
            availableWidth: availableWidth,
            minimumTerminalWidth: minimumTerminalWidth
        )
        HStack(spacing: 0) {
            if state.hasBeenShown {
                column(width)
            }
            terminal()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }
}

/// The Explorer column: the shared file explorer engine hosted beside the tabs.
struct ExplorerColumnPanel: View {
    let width: CGFloat
    let state: ExplorerColumnState
    let store: FileExplorerStore
    let fileExplorerState: FileExplorerState
    let appearance: WindowAppearanceSnapshot
    let isFullScreen: Bool
    let runtimeCache: WorkspacePresentationModeRuntimeCache
    /// Double click / Return: open pinned.
    let onOpenFilePreview: (String) -> Void
    /// Single click: open in the workspace's preview tab.
    let onPreviewFile: (String) -> Void
    /// A file row under an expanded commit in the Graph: open its diff for that commit.
    let onOpenCommitFile: (URL, GitCommit, GitCommitFileChange) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var graphDragStartHeight: CGFloat?
    @State private var columnHeight: CGFloat = 0

    /// The file tree always keeps at least this much height.
    private static let minimumTreeHeight: CGFloat = 120

    var body: some View {
        ZStack(alignment: .leading) {
            WindowBackdropLayer(role: .rightSidebar, snapshot: appearance)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                BranchBarHost(model: state.graphModel, store: store)
                FileExplorerPanelView(
                    store: store,
                    state: fileExplorerState,
                    onOpenFilePreview: onOpenFilePreview,
                    presentation: .files,
                    placement: .explorerColumn,
                    onPreviewFile: onPreviewFile
                )
                .overlay(alignment: .topTrailing) { followAgentToggle }
                graphSection
            }
            .environment(\.colorScheme, appearance.sidebarContentColorScheme)
            .environment(\.sidebarReadabilityBackdrop, appearance.sidebarReadabilityBackdrop)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { columnHeight = $0 }
            .modifier(WorkspacePresentationModeContentTopPaddingModifier(
                isFullScreen: isFullScreen,
                runtimeCache: runtimeCache
            ))
        }
        .onAppear {
            state.graphModel.attach(to: store)
            syncGraphVisibility()
        }
        .onChange(of: state.graphExpanded) { syncGraphVisibility() }
        .onChange(of: width > 0) { syncGraphVisibility() }
        .frame(width: max(width, 0), alignment: .leading)
        .clipped()
        .overlay(alignment: .trailing) {
            if width > 0 {
                ZStack(alignment: .trailing) {
                    WindowChromeBorder(
                        orientation: .vertical,
                        backgroundColor: appearance.resolvedChromeBackgroundColor
                    )
                    resizeHandle
                }
            }
        }
        .accessibilityHidden(width == 0)
    }

    /// Only read history while the section is open and the column is on screen.
    private func syncGraphVisibility() {
        state.graphModel.isGraphVisible = state.graphExpanded && width > 0
    }

    private var graphSection: some View {
        let header = CommitGraphSectionView.headerHeight
        let available = max(columnHeight - Self.minimumTreeHeight - BranchBarView.height, header)
        let height = state.graphExpanded ? min(state.graphHeight, available) : header
        return VStack(spacing: 0) {
            Divider()
                .overlay(alignment: .center) {
                    if state.graphExpanded { graphResizeHandle }
                }
            CommitGraphSectionView(
                model: state.graphModel,
                isExpanded: state.graphExpanded,
                onToggle: { state.graphExpanded.toggle() },
                onOpenFile: { commit, change in
                    guard let root = state.graphModel.repositoryRoot else { return }
                    onOpenCommitFile(root, commit, change)
                }
            )
        }
        .frame(height: height)
    }

    private var graphResizeHandle: some View {
        Color.clear
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = graphDragStartHeight ?? state.graphHeight
                        if graphDragStartHeight == nil { graphDragStartHeight = start }
                        let maximum = max(columnHeight - Self.minimumTreeHeight - BranchBarView.height, 0)
                        withTransaction(Transaction(animation: nil)) {
                            state.setGraphHeight(min(start - value.translation.height, maximum))
                        }
                    }
                    .onEnded { _ in graphDragStartHeight = nil }
            )
    }

    /// Follow-agent toggle in the header's trailing corner.
    private var followAgentToggle: some View {
        let label = String(
            localized: "explorerColumn.followAgent.tooltip",
            defaultValue: "Follow agent: open each file an agent edits beside its terminal"
        )
        return Button {
            state.followAgent.toggle()
        } label: {
            Image(systemName: state.followAgent ? "eye.fill" : "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state.followAgent ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: RightSidebarChromeMetrics.secondaryBarHeight)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(state.followAgent ? Text(verbatim: "on") : Text(verbatim: "off"))
        .padding(.trailing, 4)
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? state.width
                        if dragStartWidth == nil { dragStartWidth = start }
                        withTransaction(Transaction(animation: nil)) {
                            state.setWidth(start + value.translation.width)
                        }
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

/// Feeds the branch bar the Explorer's own git status for the dirty dot, so
/// untracked files count too without another git call.
private struct BranchBarHost: View {
    @ObservedObject var model: CommitGraphModel
    @ObservedObject var store: FileExplorerStore

    var body: some View {
        BranchBarView(
            model: model,
            hasLocalChanges: store.gitStatusByPath.values.contains { $0 != .ignored }
        )
    }
}
