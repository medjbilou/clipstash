import AppKit
import Carbon.HIToolbox
import ClipCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState!
    private var monitor: ClipboardMonitor!
    private var panel: PanelController!
    private var screenshots: ScreenshotWatcher!
    private var statusItem: NSStatusItem!
    private var openKey: HotKey!
    private var nextKey: HotKey!
    private var sweepTimer: Timer?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil) // already running
            return
        }
        Prefs.register()
        Prefs.applyTheme()

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipStash", isDirectory: true)
        let store: Store
        do {
            store = try Store(directory: dir)
        } catch {
            let alert = NSAlert()
            alert.messageText = "ClipStash can't open its history"
            alert.informativeText = "\(dir.path)\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        state = AppState(store: store)
        state.openSettings = { [weak self] in self?.showSettings() }
        monitor = ClipboardMonitor(store: store) { [weak self] in self?.state.reload() }
        state.monitor = monitor
        monitor.start()
        panel = PanelController(state: state)
        screenshots = ScreenshotWatcher { [weak self] url in
            guard let data = try? Data(contentsOf: url) else { return }
            self?.monitor.saveImage(data, name: url.deletingPathExtension().lastPathComponent, app: "Screenshot", bundle: nil)
        }

        openKey = HotKey(id: 1) { [weak self] in self?.panel.toggle() }
        nextKey = HotKey(id: 2) { [weak self] in self?.state.pasteNext() }
        registerOpenKey()
        nextKey.register(code: UInt32(kVK_ANSI_V), mods: UInt32(controlKey | cmdKey))

        setupStatusItem()
        applyPrefs()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.applyPrefs()
        }
        state.sweep()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.state.sweep() }
        sweepTimer?.tolerance = 5

        if !Prefs.welcomed { showWelcome() }
    }

    func applicationWillTerminate(_ note: Notification) {
        state?.commitDelete()
    }

    @discardableResult
    private func registerOpenKey() -> Bool {
        let k = Prefs.hotKey
        return openKey.register(code: k.code, mods: k.mods)
    }

    private var lastLimits: (Int, Int)?

    private func applyPrefs() {
        Prefs.applyTheme()
        screenshots.setEnabled(Prefs.saveScreenshots && !Prefs.paused)
        let symbol = Prefs.paused ? "pause.circle" : "doc.on.clipboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: Prefs.paused ? "ClipStash (paused)" : "ClipStash")
        image?.isTemplate = true
        statusItem.button?.image = image
        let limits = (Prefs.maxClips, Prefs.storageBytes)
        if lastLimits.map({ $0 != limits }) ?? true {
            lastLimits = limits
            _ = try? state.store.prune(maxClips: limits.0, maxImageBytes: limits.1)
            state.reload()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "Open History  \(Prefs.hotKey.label)", action: #selector(openHistory), keyEquivalent: "")
        menu.addItem(open)
        if !state.queue.isEmpty {
            menu.addItem(withTitle: "Paste Queue: \(state.queue.count) left (⌃⌘V)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Clear Paste Queue", action: #selector(clearQueue), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: Prefs.paused ? "Resume Saving" : "Pause Saving", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Welcome Guide", action: #selector(showWelcome), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipStash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
    }

    @objc private func openHistory() { panel.show() }
    @objc private func clearQueue() { state.queue.removeAll() }
    @objc private func togglePause() { Prefs.paused.toggle() }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Every clip except pinned ones is deleted. This can't be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { state.clearHistory() }
    }

    // MARK: Windows

    @objc private func showSettings() {
        panel.hide()
        if settingsWindow == nil {
            let view = SettingsView(state: state) { [weak self] in self?.registerOpenKey() ?? false }
            settingsWindow = makeWindow(title: "ClipStash Settings", view: view)
        }
        present(settingsWindow!)
    }

    @objc private func showWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = makeWindow(title: "Welcome to ClipStash", view: WelcomeView { [weak self] in
                Prefs.welcomed = true
                self?.welcomeWindow?.close()
            })
        }
        present(welcomeWindow!)
    }

    private func makeWindow(title: String, view: some View) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        return window
    }

    private func present(_ window: NSWindow) {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

#if DEBUG
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    Snapshots.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
