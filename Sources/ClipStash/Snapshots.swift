#if DEBUG
import AppKit
import ClipCore
import SwiftUI

/// `swift run ClipStash --snapshot <dir>`: renders the panel offscreen (sample data, light + dark) for design review.
enum Snapshots {
    static func run(to dir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-snap-\(UUID().uuidString)")
        let store = try! Store(directory: tmp)
        let now = Date()
        func add(_ kind: ClipKind, _ text: String, _ app: String, _ minsAgo: Double, png: Data? = nil) -> Int64 {
            try! store.add(kind: kind, text: text, png: png, app: app, bundle: nil, now: now.addingTimeInterval(-minsAgo * 60))
        }
        let addr = add(.text, "221B Baker Street, London NW1 6XE", "Notes", 1440)
        try! store.setPinned(addr, true)
        try! store.setTitle(addr, "Home address")
        _ = add(.text, "#FF5B2E", "Figma", 15)
        _ = add(.code, "const total = items.reduce((s, i) => s + i.price, 0);", "Visual Studio Code", 12)
        _ = add(.file, "/Applications/Safari.app\n/System/Library", "Finder", 10)
        let img = NSImage(systemSymbolName: "photo.artframe", accessibilityDescription: nil)!
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        _ = add(.image, "Screenshot 2026-10-06 at 14.02.11", "Screenshot", 9, png: png)
        _ = add(.link, "https://www.figma.com/design/q3-launch-deck", "Google Chrome", 6)
        let otp = add(.text, "482 913", "Messages", 3)
        try! store.setExpiry(otp, now.addingTimeInterval(240))
        _ = add(.text, "hello@yourteam.com", "Mail", 2)

        let state = AppState(store: store)
        state.reload()
        state.queue = [otp]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            state.filter = .all
            state.query = ""
            state.reload()
            render(PanelView(state: state), appearance, dir.appendingPathComponent("panel-\(name).png"))
            state.query = "zzz"
            state.reload()
            render(PanelView(state: state), appearance, dir.appendingPathComponent("panel-empty-\(name).png"))
        }
        print("snapshots written to \(dir.path)")
        exit(0)
    }

    private static func render(_ view: some View, _ appearance: NSAppearance.Name, _ url: URL) {
        // cacheDisplay skips the window background, so paint it into the view itself.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
#endif
