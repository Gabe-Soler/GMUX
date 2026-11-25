import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Live diff rows")
struct LiveDiffRowsTests {
    @Test("Merged listing puts removals before additions with both line numbers")
    func mergedListing() {
        let merged = LiveDiffRows.merged(baseline: ["a", "b", "c"], current: ["a", "B", "c", "d"])
        #expect(merged.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(merged.map(\.kind) == [.unchanged, .removed, .added, .unchanged, .added])
        #expect(merged.map(\.old) == [1, 2, nil, 3, nil])
        #expect(merged.map(\.new) == [1, nil, 2, 3, 4])
    }

    @Test("A new file is entirely additions")
    func newFileIsAllAdded() {
        let merged = LiveDiffRows.merged(baseline: [], current: ["x", "y"])
        #expect(merged.allSatisfy { $0.kind == .added })
    }

    @Test("Lines split on newlines without a phantom trailing line, CRLF tolerated")
    func lineSplitting() {
        #expect(LiveDiffRows.lines(of: "a\nb\n") == ["a", "b"])
        #expect(LiveDiffRows.lines(of: "a\r\nb") == ["a", "b"])
        #expect(LiveDiffRows.lines(of: "") == [])
    }

    @Test("Unchanged rows keep their ids; only the latest edit's rows are fresh")
    func stableIdsAcrossEdits() {
        let baseline = ["one", "two", "three"]
        let first = LiveDiffRows.update(previous: [], nextId: 0, baseline: baseline, current: ["one", "TWO", "three"])
        #expect(first.rows.map(\.kind) == [.unchanged, .removed, .added, .unchanged])
        #expect(first.freshIds.count == 4)

        // A second edit appends a line: only that row is new, every other id is kept.
        let second = LiveDiffRows.update(
            previous: first.rows, nextId: first.nextId, baseline: baseline,
            current: ["one", "TWO", "three", "four"]
        )
        #expect(Array(second.rows.prefix(4).map(\.id)) == first.rows.map(\.id))
        #expect(second.freshIds == [second.rows[4].id])
        #expect(second.rows[4].kind == .added)
        #expect(second.rows[4].text == "four")
    }

    @Test("Reverting an edit removes its rows without new ones")
    func revertDropsRows() {
        let baseline = ["one", "two"]
        let edited = LiveDiffRows.update(previous: [], nextId: 0, baseline: baseline, current: ["one", "2", "two"])
        let reverted = LiveDiffRows.update(previous: edited.rows, nextId: edited.nextId, baseline: baseline, current: baseline)
        #expect(reverted.rows.map(\.kind) == [.unchanged, .unchanged])
        #expect(reverted.freshIds.isEmpty)
    }
}
