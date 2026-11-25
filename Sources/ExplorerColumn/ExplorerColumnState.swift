import AppKit
import Bonsplit
import Foundation
import Observation

/// Per-window state for the Explorer column that sits between the workspace
/// tabs and the terminal content.
///
/// It persists under its own `explorerColumn.*` keys so it never overwrites the
/// right sidebar's `fileExplorer.*` visibility or width.
@MainActor
@Observable
final class ExplorerColumnState {
    static let visibilityKey = "explorerColumn.isVisible"
    static let widthKey = "explorerColumn.width"
    static let followAgentKey = "explorerColumn.followAgent"

    static let defaultWidth: CGFloat = 240
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = 640

    @ObservationIgnored private let defaults: UserDefaults

    /// The single-click "preview" tab of each workspace (VS Code semantics).
    @ObservationIgnored var previewPanelIdByWorkspace: [UUID: UUID] = [:]

    /// The window's file tree, attached by its ContentView so `cmux files`
    /// commands can drive the same tree the person sees.
    @ObservationIgnored weak var attachedStore: FileExplorerStore?

    /// Follow-agent mode: show each file an agent edits in a pane beside its
    /// terminal, without taking keyboard focus (ExplorerFollowAgent).
    var followAgent: Bool {
        didSet {
            guard followAgent != oldValue else { return }
            defaults.set(followAgent, forKey: Self.followAgentKey)
        }
    }

    /// The stacked live-diff panes each workspace shows followed files in.
    @ObservationIgnored var followPanesByWorkspace: [UUID: [PaneID]] = [:]
    /// Edits waiting to be shown, one entry per file, oldest first.
    @ObservationIgnored var followPending: [ExplorerFollowAgent.Pending] = []
    @ObservationIgnored var followTask: Task<Void, Never>?

    /// Whether the person wants the column shown.
    var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible { hasBeenShown = true }
            defaults.set(isVisible, forKey: Self.visibilityKey)
        }
    }

    /// The width the person chose; layout may render it narrower in a small window.
    private(set) var width: CGFloat

    /// Sets the preferred width, clamped to the column's bounds, and persists it.
    func setWidth(_ proposed: CGFloat) {
        let clamped = Self.clampedWidth(proposed)
        guard clamped != width else { return }
        width = clamped
        defaults.set(Double(clamped), forKey: Self.widthKey)
    }

    /// True once the column has been visible, so its AppKit tree is only built
    /// on demand and then kept mounted across hide/show.
    private(set) var hasBeenShown: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // GMUX shows the Explorer by default; an explicit hide is remembered.
        let visible = defaults.object(forKey: Self.visibilityKey) as? Bool ?? true
        self.isVisible = visible
        self.hasBeenShown = visible
        self.followAgent = defaults.object(forKey: Self.followAgentKey) as? Bool ?? true
        let storedWidth = defaults.double(forKey: Self.widthKey)
        self.width = Self.clampedWidth(storedWidth > 0 ? CGFloat(storedWidth) : Self.defaultWidth)
    }

    func toggle() {
        isVisible.toggle()
    }

    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The width to render inside `availableWidth`, leaving the terminal at least
    /// `minimumTerminalWidth`. Returns 0 when the column cannot fit at its minimum.
    static func renderedWidth(
        preferred: CGFloat,
        isVisible: Bool,
        availableWidth: CGFloat,
        minimumTerminalWidth: CGFloat
    ) -> CGFloat {
        guard isVisible else { return 0 }
        let room = availableWidth - minimumTerminalWidth
        guard room >= minimumWidth else { return 0 }
        return min(clampedWidth(preferred), room)
    }
}
