import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Explorer column state")
struct ExplorerColumnStateTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "ExplorerColumnStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Shows by default and persists an explicit hide")
    func visibilityDefaultsAndPersists() {
        let defaults = makeDefaults()
        let state = ExplorerColumnState(defaults: defaults)
        #expect(state.isVisible)
        #expect(state.hasBeenShown)

        state.toggle()
        #expect(ExplorerColumnState(defaults: defaults).isVisible == false)
    }

    @Test("Follow-agent mode is on by default and remembers being turned off")
    func followAgentDefaultsOnAndPersists() {
        let defaults = makeDefaults()
        let state = ExplorerColumnState(defaults: defaults)
        #expect(state.followAgent)
        state.followAgent = false
        #expect(ExplorerColumnState(defaults: defaults).followAgent == false)
    }

    @Test("Width is clamped and persisted")
    func widthClampsAndPersists() {
        let defaults = makeDefaults()
        let state = ExplorerColumnState(defaults: defaults)
        #expect(state.width == ExplorerColumnState.defaultWidth)

        state.setWidth(10)
        #expect(state.width == ExplorerColumnState.minimumWidth)
        state.setWidth(10_000)
        #expect(state.width == ExplorerColumnState.maximumWidth)
        state.setWidth(300)
        #expect(ExplorerColumnState(defaults: defaults).width == 300)
    }

    @Test("Never writes the right sidebar's fileExplorer keys")
    func leavesRightSidebarKeysAlone() {
        let defaults = makeDefaults()
        let state = ExplorerColumnState(defaults: defaults)
        state.toggle()
        state.setWidth(320)
        #expect(defaults.object(forKey: "fileExplorer.isVisible") == nil)
        #expect(defaults.object(forKey: "fileExplorer.width") == nil)
    }

    @Test("Rendered width yields to the terminal and collapses when it cannot fit")
    func renderedWidthFitsWindow() {
        let wide = ExplorerColumnState.renderedWidth(
            preferred: 240, isVisible: true, availableWidth: 1200, minimumTerminalWidth: 200
        )
        #expect(wide == 240)

        let squeezed = ExplorerColumnState.renderedWidth(
            preferred: 240, isVisible: true, availableWidth: 400, minimumTerminalWidth: 200
        )
        #expect(squeezed == 200)

        let collapsed = ExplorerColumnState.renderedWidth(
            preferred: 240, isVisible: true, availableWidth: 300, minimumTerminalWidth: 200
        )
        #expect(collapsed == 0)

        let hidden = ExplorerColumnState.renderedWidth(
            preferred: 240, isVisible: false, availableWidth: 1200, minimumTerminalWidth: 200
        )
        #expect(hidden == 0)
    }

    @Test("A visible Explorer column keeps the shared explorer root in sync")
    func explorerColumnDrivesRootSync() {
        for mode in RightSidebarMode.allCases {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: false,
                    mode: mode,
                    isExplorerColumnVisible: true
                )
            )
        }
    }
}
