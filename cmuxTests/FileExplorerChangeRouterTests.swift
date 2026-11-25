import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File explorer change router")
struct FileExplorerChangeRouterTests {
    private let router = FileExplorerChangeRouter(rootPath: "/repo", canonicalRootPath: "/private/repo")

    @Test("A change deep in the tree refreshes only its loaded parent folder")
    func nestedChangeRefreshesParent() {
        let plan = router.plan(
            changedPaths: ["/repo/src/app/main.swift"],
            requiresFullRescan: false,
            loadedDirectories: ["/repo/src", "/repo/src/app"]
        )
        #expect(plan.directories == ["/repo/src/app"])
        #expect(plan.refreshGitStatus)
    }

    @Test("Changes under folders that are not loaded do nothing to the tree")
    func unloadedFolderIsSkipped() {
        let plan = router.plan(
            changedPaths: ["/repo/vendor/lib/a.c"],
            requiresFullRescan: false,
            loadedDirectories: ["/repo/src"]
        )
        #expect(plan.directories.isEmpty)
    }

    @Test("Root-level changes refresh the root")
    func rootChangeRefreshesRoot() {
        let plan = router.plan(changedPaths: ["/repo/README.md"], requiresFullRescan: false, loadedDirectories: [])
        #expect(plan.directories == ["/repo"])
    }

    @Test("Symlink-resolved FSEvents paths map back to the tree's spelling")
    func canonicalPathsAreRespelled() {
        #expect(router.treePath(for: "/private/repo/src/a.swift") == "/repo/src/a.swift")
        #expect(router.treePath(for: "/elsewhere/a.swift") == nil)
        let plan = router.plan(
            changedPaths: ["/private/repo/src/a.swift"],
            requiresFullRescan: false,
            loadedDirectories: ["/repo/src"]
        )
        #expect(plan.directories == ["/repo/src"])
    }

    @Test("Git metadata never refreshes the tree, but commits refresh status")
    func gitMetadataOnlyRefreshesStatus() {
        let objects = router.plan(
            changedPaths: ["/repo/.git/objects/ab/cdef"],
            requiresFullRescan: false,
            loadedDirectories: []
        )
        #expect(objects == FileExplorerChangeRouter.Plan())

        let index = router.plan(changedPaths: ["/repo/.git/index"], requiresFullRescan: false, loadedDirectories: [])
        #expect(index.directories.isEmpty)
        #expect(index.refreshGitStatus)
    }

    @Test("Churn inside ignored folders does not re-run git status")
    func ignoredChurnSkipsGitStatus() {
        let plan = router.plan(
            changedPaths: ["/repo/node_modules/pkg/index.js"],
            requiresFullRescan: false,
            loadedDirectories: ["/repo/node_modules/pkg"],
            isIgnored: { $0.hasPrefix("/repo/node_modules") }
        )
        #expect(plan.directories == ["/repo/node_modules/pkg"])
        #expect(plan.refreshGitStatus == false)
    }

    @Test("A dropped-event rescan refreshes every loaded folder")
    func fullRescanRefreshesLoadedFolders() {
        let plan = router.plan(changedPaths: [], requiresFullRescan: true, loadedDirectories: ["/repo/src"])
        #expect(plan.directories == ["/repo", "/repo/src"])
        #expect(plan.refreshGitStatus)
    }
}
