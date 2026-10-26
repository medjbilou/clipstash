import Foundation
import Testing
@testable import ClipCore

/// One test per finding from adversarial ("breaker") testing. Each failed before its fix.
@Suite struct BreakerRegressionTests {
    func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    // High 1
    @Test func nulBytesSurviveRoundTrip() throws {
        let s = try Store(directory: tempDir())
        try s.add(kind: .text, text: "password123\0SECRET-TAIL", app: nil, bundle: nil)
        try s.add(kind: .text, text: "\0leading", app: nil, bundle: nil)
        let texts = Set(try s.clips().compactMap(\.text))
        #expect(texts == ["password123\0SECRET-TAIL", "\0leading"])
        #expect(try s.clips(search: "TAIL").count == 1)
    }

    // High 2
    @Test func pinnedClipsNeverExpire() throws {
        let s = try Store(directory: tempDir())
        let id = try s.add(kind: .text, text: "1234 5678", app: nil, bundle: nil, expires: Date(timeIntervalSince1970: 300))
        try s.setPinned(id, true)
        try s.deleteExpired(now: Date(timeIntervalSince1970: 301))
        let clip = try #require(try s.clip(id: id))
        #expect(clip.expires == nil)
    }

    // High 2 / Medium 6
    @Test func oneTimeCodeRuleSkipsOrdinaryNumbers() {
        for code in ["482 913", "482913", "482-913"] { #expect(Classifier.isOneTimeCode(code), "\(code)") }
        for other in ["555-1234", "123 4567", "12345678", "4111 1111", "2024-1031", "0612 3456", "1000 000", "١٢٣٤٥٦"] {
            #expect(!Classifier.isOneTimeCode(other), "\(other)")
        }
    }

    // Medium 8
    @Test func recopyStartsFresh() throws {
        let s = try Store(directory: tempDir())
        try s.add(kind: .text, text: "482 913", app: nil, bundle: nil, expires: Date(timeIntervalSince1970: 300), now: Date(timeIntervalSince1970: 0))
        try s.add(kind: .text, text: "482 913", app: nil, bundle: nil, expires: nil, now: Date(timeIntervalSince1970: 310))
        try s.deleteExpired(now: Date(timeIntervalSince1970: 320))
        #expect(try s.count() == 1)
    }

    // Medium 1
    @Test func classifyingHugeTextIsCheap() {
        let huge = String(repeating: "lorem ipsum dolor sit amet ", count: 200_000) // ~5.4 MB
        let t = Date()
        _ = Classifier.kind(for: huge, bundle: nil)
        _ = Classifier.isOneTimeCode(huge)
        _ = Classifier.hexColor(huge)
        #expect(Date().timeIntervalSince(t) < 0.05)
    }

    // Medium 3
    @Test func twoStoresOnOneDirectoryDoNotLoseWrites() async throws {
        let dir = tempDir()
        let a = try Store(directory: dir), b = try Store(directory: dir)
        let failures = await withTaskGroup(of: Int.self) { group in
            for (n, store) in [a, b].enumerated() {
                group.addTask {
                    var failed = 0
                    for i in 0..<300 {
                        do { try store.add(kind: .text, text: "s\(n)-\(i)", app: nil, bundle: nil) } catch { failed += 1 }
                    }
                    return failed
                }
            }
            return await group.reduce(0, +)
        }
        #expect(failures == 0)
        #expect(try a.count() == 600)
    }

    // Medium 3
    @Test func imageFolderDeletedWhileRunningIsRecreated() throws {
        let s = try Store(directory: tempDir())
        try FileManager.default.removeItem(at: s.imageDir)
        try s.add(kind: .image, text: "img", png: Data([1, 2, 3]), app: nil, bundle: nil)
        let clip = try #require(try s.clips().first)
        #expect(FileManager.default.fileExists(atPath: s.imageURL(clip)!.path))
    }

    // Medium 4
    @Test func corruptDatabaseIsMovedAsideAndStartsFresh() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 8192).write(to: dir.appendingPathComponent("history.sqlite"))
        let (store, movedTo) = try Store.openRecovering(directory: dir)
        #expect(try store.count() == 0)
        let backup = try #require(movedTo)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    // Medium 5
    @Test func searchIgnoresCaseAndAccents() throws {
        let s = try Store(directory: tempDir())
        try s.add(kind: .text, text: "Éclair au café", app: nil, bundle: nil)
        for q in ["éclair", "eclair", "CAFÉ", "cafe", "ÉCLAIR"] { #expect(try s.clips(search: q).count == 1, "\(q)") }
    }

    // Medium 5: existing databases get the new search column filled in.
    @Test func searchWorksOnDatabasesFromBeforeTheFix() throws {
        let dir = tempDir()
        do {
            let s = try Store(directory: dir)
            try s.add(kind: .text, text: "Crème brûlée", app: nil, bundle: nil)
        }
        let reopened = try Store(directory: dir)
        #expect(try reopened.clips(search: "creme").count == 1)
    }
}

/// Re-run finding: folding one long accented string was super-linear and hung migration at launch.
@Suite struct FoldPerformanceTests {
    @Test func foldingLongAccentedTextIsLinear() {
        let text = String(repeating: "Crème brûlée à la française, déjà vu. ", count: 25_000) // ~1 MB
        let t = Date()
        let folded = Store.fold(text)
        #expect(Date().timeIntervalSince(t) < 1)
        #expect(folded.hasPrefix("creme brulee a la francaise"))
    }
    /// Re-run High: `ß`, ligatures and decomposed accents made folding quadratic (1 MB took 2.5 s).
    @Test(arguments: ["Straße ", "ﬁle ", "ŉ x ", "E\u{0301}clair Cafe\u{0301} "])
    func foldingExpandingTextIsLinear(unit: String) {
        let text = String(repeating: unit, count: 2_000_000 / unit.utf8.count) // ~2 MB
        let t = Date()
        _ = Store.fold(text)
        #expect(Date().timeIntervalSince(t) < 0.3, "\(unit)")
    }

    @Test func searchFindsTextNearTheStartOfHugeClips() throws {
        let s = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try s.add(kind: .text, text: "Straße head " + String(repeating: "Straße ", count: 600_000), app: nil, bundle: nil)
        #expect(try s.clips(search: "strasse head").count == 1)
    }

    /// Re-run Low: `Set(...).prefix(64)` kept a random 64 words, so the same query could change results.
    @Test func longQueriesAreDeterministic() throws {
        let s = try Store(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let words = (0..<70).map { "w\($0)" }
        try s.add(kind: .text, text: words.prefix(64).joined(separator: " "), app: nil, bundle: nil)
        #expect(try s.clips(search: words.joined(separator: " ")).count == 1) // first 64 words, in order
    }

    /// Re-run Low: two recoveries in the same second collided on the backup name.
    @Test func twoRecoveriesInOneSecondBothSucceed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<2 {
            try Data(repeating: 0xAB, count: 8192).write(to: dir.appendingPathComponent("history.sqlite"))
            let (_, moved) = try Store.openRecovering(directory: dir)
            #expect(moved != nil)
        }
    }
}
