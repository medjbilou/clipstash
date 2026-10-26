import Foundation
import Testing
@testable import ClipCore

@Suite struct ClassifierTests {
    @Test func links() {
        #expect(Classifier.kind(for: "https://www.figma.com/design/q3-launch-deck", bundle: nil) == .link)
        #expect(Classifier.kind(for: "www.example.com", bundle: nil) == .link)
        #expect(Classifier.kind(for: "see https://x.com", bundle: nil) != .link)
        #expect(Classifier.kind(for: "mailto:a@b.co", bundle: nil) != .link)
    }

    @Test func code() {
        #expect(Classifier.kind(for: "const total = items.reduce((s, i) => s + i.price, 0);", bundle: nil) == .code)
        #expect(Classifier.kind(for: "npm run dev", bundle: "com.microsoft.VSCode") == .code)
        #expect(Classifier.kind(for: "npm run dev", bundle: nil) == .code)
        #expect(Classifier.kind(for: "221B Baker Street, London NW1 6XE", bundle: nil) == .text)
        #expect(Classifier.kind(for: "See you at 4pm!", bundle: nil) == .text)
    }

    @Test func colors() {
        let c = Classifier.hexColor("#FF5B2E")
        #expect(c?.r == 1 && c?.b == Double(0x2E) / 255)
        #expect(Classifier.hexColor("#fff") != nil)
        #expect(Classifier.hexColor("FF5B2E") == nil)
        #expect(Classifier.hexColor("#GG0000") == nil)
    }

    @Test func oneTimeCodes() {
        #expect(Classifier.isOneTimeCode("482 913"))
        #expect(Classifier.isOneTimeCode("123456"))
        #expect(!Classifier.isOneTimeCode("123-4567")) // 7 digits: phone-shaped, not a 2FA code
        #expect(!Classifier.isOneTimeCode("2041"))
        #expect(!Classifier.isOneTimeCode("1234567890"))
    }
}

@Suite struct StoreTests {
    func makeStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Store(directory: dir)
    }

    @Test func dedupMovesToTop() throws {
        let s = try makeStore()
        let a = try s.add(kind: .text, text: "a", app: "Mail", bundle: nil, now: Date(timeIntervalSince1970: 1))
        try s.add(kind: .text, text: "b", app: "Mail", bundle: nil, now: Date(timeIntervalSince1970: 2))
        let again = try s.add(kind: .text, text: "a", app: "Notes", bundle: nil, now: Date(timeIntervalSince1970: 3))
        #expect(a == again)
        let clips = try s.clips()
        #expect(clips.map(\.text) == ["a", "b"])
        #expect(clips[0].app == "Notes")
    }

    @Test func filtersAndSearch() throws {
        let s = try makeStore()
        try s.add(kind: .text, text: "hello@yourteam.com", app: "Mail", bundle: nil)
        let link = try s.add(kind: .link, text: "https://zoom.us/j/1", app: "Chrome", bundle: nil)
        try s.add(kind: .text, text: "50%_off", app: nil, bundle: nil)
        try s.setPinned(link, true)
        try s.setTitle(link, "Zoom link")
        #expect(try s.clips(filter: .links).count == 1)
        #expect(try s.clips(filter: .favorites).first?.displayTitle == "Zoom link")
        #expect(try s.clips(search: "zoom").count == 1)
        #expect(try s.clips(search: "yourteam mail").count == 1)
        #expect(try s.clips(search: "%_").count == 1)
        #expect(try s.clips(search: "nothing").isEmpty)
    }

    @Test func expiryClearAndPrune() throws {
        let s = try makeStore()
        let otp = try s.add(kind: .text, text: "482 913", app: nil, bundle: nil, expires: Date(timeIntervalSince1970: 10))
        let pinned = try s.add(kind: .text, text: "keep", app: nil, bundle: nil, now: Date(timeIntervalSince1970: 0))
        try s.setPinned(pinned, true)
        for i in 0..<5 { try s.add(kind: .text, text: "t\(i)", app: nil, bundle: nil) }
        #expect(try s.deleteExpired(now: Date(timeIntervalSince1970: 11)) == 1)
        #expect(try !s.clips().contains { $0.id == otp })
        try s.prune(maxClips: 2, maxImageBytes: .max)
        #expect(try s.count() == 3) // 2 unpinned + pinned survives
        try s.clearUnpinned()
        #expect(try s.clips().map(\.id) == [pinned])
    }

    @Test func imagesStoredAndRemoved() throws {
        let s = try makeStore()
        let png = Data(repeating: 7, count: 100)
        let id = try s.add(kind: .image, text: "Screenshot", png: png, app: nil, bundle: nil)
        let clip = try #require(try s.clips().first)
        let url = try #require(s.imageURL(clip))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(clip.size == 100)
        try s.add(kind: .image, text: "b", png: Data(repeating: 8, count: 100), app: nil, bundle: nil)
        try s.prune(maxClips: 10, maxImageBytes: 150) // the older image goes
        #expect(try !s.clips().contains { $0.id == id })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
