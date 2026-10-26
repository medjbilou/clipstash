import AppKit
import ClipCore
import Combine

/// UI state for the history panel plus every clip action.
final class AppState: ObservableObject {
    let store: Store
    @Published var clips: [Clip] = []
    @Published var total = 0
    @Published var query = ""
    @Published var filter: ClipFilter = .all
    @Published var selectedID: Int64?
    @Published var queue: [Int64] = []
    @Published var now = Date()
    @Published var toast: String?
    /// Bumped each time the panel opens so the view refocuses search.
    @Published var openToken = 0
    /// Bumped to move focus into the rename field.
    @Published var renameToken = 0
    var isRenaming = false
    /// Mouse position at the last keyboard move; hover only selects once the mouse really moves.
    var keyNavMouse: NSPoint?

    var monitor: ClipboardMonitor?
    var hidePanel: () -> Void = {}
    var openSettings: () -> Void = {}
    var previousApp: NSRunningApplication?

    init(store: Store) { self.store = store }

    var selected: Clip? { clips.first { $0.id == selectedID } }

    func reload() {
        now = Date()
        clips = (try? store.clips(filter: filter, search: query)) ?? []
        total = (try? store.count()) ?? 0
        if selected == nil { selectedID = clips.first?.id }
    }

    func move(_ delta: Int) {
        guard !clips.isEmpty else { return }
        let i = clips.firstIndex { $0.id == selectedID } ?? -1
        selectedID = clips[max(0, min(clips.count - 1, i + delta))].id
        keyNavMouse = NSEvent.mouseLocation
    }

    func cycleFilter(_ delta: Int) {
        let all = ClipFilter.allCases
        let i = all.firstIndex(of: filter)!
        filter = all[(i + delta + all.count) % all.count]
    }

    // MARK: Actions

    /// ↵: pastes the first queued clip if a queue exists, otherwise the selection.
    func pasteSelectedOrQueued() {
        if let first = queue.first, let clip = try? store.clip(id: first) {
            queue.removeFirst()
            paste(clip)
        } else if let clip = selected {
            paste(clip)
        }
    }

    func paste(_ clip: Clip) {
        guard write(clip) else { return }
        hidePanel()
        guard Paster.canAutoPaste else { return }
        let target = previousApp
        if let target, target != NSRunningApplication.current { target.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Paster.pressCommandV() }
    }

    /// Global ⌃⌘V: pastes the next queued clip into the frontmost app.
    func pasteNext() {
        while let id = queue.first {
            queue.removeFirst()
            guard let clip = try? store.clip(id: id), write(clip) else { continue }
            if Paster.canAutoPaste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Paster.pressCommandV() }
            }
            return
        }
        NSSound.beep()
    }

    func copy(_ clip: Clip) {
        guard write(clip) else { return }
        flash("Copied")
    }

    func toggleQueue(_ clip: Clip) {
        if let i = queue.firstIndex(of: clip.id) { queue.remove(at: i) } else { queue.append(clip.id) }
    }

    func togglePin(_ clip: Clip) {
        try? store.setPinned(clip.id, !clip.pinned)
        reload()
    }

    func rename(_ clip: Clip, to title: String) {
        try? store.setTitle(clip.id, title)
        reload()
    }

    func setExpiry(_ clip: Clip, minutes: Int?) {
        try? store.setExpiry(clip.id, minutes.map { Date().addingTimeInterval(Double($0) * 60) })
        reload()
    }

    func delete(_ clip: Clip) {
        let i = clips.firstIndex(of: clip) ?? 0
        try? store.delete(clip.id)
        queue.removeAll { $0 == clip.id }
        reload()
        if !clips.isEmpty { selectedID = clips[min(i, clips.count - 1)].id }
    }

    func saveImage(_ clip: Clip) {
        guard let src = store.imageURL(clip),
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let base = (clip.title ?? clip.text ?? "Image").replacingOccurrences(of: "/", with: "-")
        var dest = downloads.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            flash("Saved to Downloads")
        } catch {
            flash("Couldn't save image")
        }
    }

    func clearHistory() {
        try? store.clearUnpinned()
        queue.removeAll { (try? store.clip(id: $0)) == nil }
        reload()
    }

    /// Drops expired clips and refreshes relative times.
    func sweep() {
        let removed = (try? store.deleteExpired()) ?? 0
        if removed > 0 { queue.removeAll { (try? store.clip(id: $0)) == nil } }
        reload()
    }

    private func write(_ clip: Clip) -> Bool {
        guard Paster.write(clip, store: store) else {
            NSSound.beep()
            flash("This clip's content is no longer available")
            return false
        }
        monitor?.ignoreCurrent()
        try? store.touch(clip.id)
        reload()
        return true
    }

    private func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == message { self?.toast = nil }
        }
    }
}
