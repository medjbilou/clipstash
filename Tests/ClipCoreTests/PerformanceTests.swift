import Foundation
import Testing
@testable import ClipCore

/// Budget guard: the panel re-queries on every keystroke, so a full 10k history must stay instant.
@Suite struct PerformanceTests {
    @Test func searchFullHistoryWithinBudget() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(directory: dir)
        let big = String(repeating: "lorem ipsum dolor sit amet ", count: 2000) // ~54 KB
        for i in 0..<10_000 {
            try store.add(kind: .text, text: i % 20 == 0 ? "\(i) \(big)" : "clip number \(i) hello@team.com",
                          app: "Mail", bundle: nil, now: Date(timeIntervalSince1970: Double(i)))
        }
        func time(_ body: () throws -> Void) rethrows -> Double {
            let t = Date()
            for _ in 0..<5 { try body() }
            return Date().timeIntervalSince(t) / 5 * 1000
        }
        let all = try time { _ = try store.clips() }
        let search = try time { _ = try store.clips(search: "number 99") }
        print("PERF all=\(String(format: "%.1f", all))ms search=\(String(format: "%.1f", search))ms")
        #expect(all < 50)
        #expect(search < 50)
    }
}

@Suite struct HugeClipTests {
    /// A 20 MB log copied once must not make every list render or keystroke slow.
    @Test func hugeClipStaysCheap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Store(directory: dir)
        var t = Date()
        try store.add(kind: .text, text: "  first line\n" + String(repeating: "x", count: 20_000_000), app: nil, bundle: nil)
        print("PERF huge add=\(String(format: "%.0f", Date().timeIntervalSince(t) * 1000))ms")
        t = Date()
        let clips = try store.clips()
        let load = Date().timeIntervalSince(t) * 1000
        t = Date()
        for _ in 0..<10 { _ = clips[0].displayTitle }
        let title = Date().timeIntervalSince(t) * 100
        print("PERF huge load=\(String(format: "%.1f", load))ms title=\(String(format: "%.2f", title))ms")
        #expect(clips[0].displayTitle == "first line")
        #expect(load < 20)
        #expect(title < 1)
    }
}
