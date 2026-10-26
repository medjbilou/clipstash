import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let state: AppState
    let onShortcutChange: () -> Bool

    var body: some View {
        TabView {
            GeneralTab(onShortcutChange: onShortcutChange).tabItem { Label("General", systemImage: "gearshape") }
            HistoryTab(state: state).tabItem { Label("History", systemImage: "clock") }
            ExcludedAppsTab().tabItem { Label("Excluded Apps", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 430)
        .padding(.top, 4)
    }
}

private struct GeneralTab: View {
    let onShortcutChange: () -> Bool
    @AppStorage("theme") private var theme = "system"
    @AppStorage("paused") private var paused = false
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("saveScreenshots") private var saveScreenshots = true
    @AppStorage("autoExpireCodes") private var autoExpireCodes = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Open history") { ShortcutRecorder(onChange: onShortcutChange) }
                LabeledContent("Paste next in queue") { Text("⌃⌘V").foregroundStyle(.secondary) }
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section {
                Toggle("Pause saving new copies", isOn: $paused)
                Toggle("Save new screenshots to history", isOn: $saveScreenshots)
                Toggle("Delete one-time codes after 5 minutes", isOn: $autoExpireCodes)
            }
            Section {
                Toggle("Paste automatically after choosing a clip", isOn: $autoPaste)
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility access granted" : "Needs Accessibility access to paste for you. Without it, ↵ copies and you press ⌘V.")
                        .font(.caption)
                    Spacer()
                    if !trusted { Button("Open Settings") { Paster.requestAccessibility() } }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct HistoryTab: View {
    let state: AppState
    @AppStorage("maxClips") private var maxClips = 1000
    @AppStorage("maxImageMB") private var maxImageMB = 10
    @AppStorage("storageMB") private var storageMB = 1024
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Picker("Keep up to", selection: $maxClips) {
                    ForEach([100, 500, 1000, 5000, 10000], id: \.self) { Text("\($0.formatted()) clips").tag($0) }
                }
                Picker("Skip images larger than", selection: $maxImageMB) {
                    ForEach([2, 5, 10, 25, 50], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Picker("Image storage limit", selection: $storageMB) {
                    ForEach([256, 512, 1024, 2048, 5120], id: \.self) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64($0) * 1_048_576, countStyle: .file)).tag($0)
                    }
                }
                Text("Oldest unpinned clips go first. Pinned clips are kept forever.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                    Spacer()
                    Button("Show Data Folder") { NSWorkspace.shared.open(state.store.imageDir.deletingLastPathComponent()) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { state.clearHistory() }
        } message: {
            Text("Every clip except pinned ones is deleted. This can't be undone.")
        }
    }
}

private struct ExcludedAppsTab: View {
    @State private var apps = Prefs.excludedApps
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing copied in these apps is saved. Items password managers mark as concealed are always skipped.")
                .font(.caption).foregroundStyle(.secondary)
            List(apps, id: \.self, selection: $selection) { id in
                HStack {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: url.path))
                    } else {
                        Image(systemName: "app.dashed").frame(width: 18)
                        Text(id).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 4) {
                Button { add() } label: { Image(systemName: "plus") }
                Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
            }
        }
        .padding(20)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { !apps.contains($0) }
        apps += ids
        Prefs.excludedApps = apps
    }

    private func remove() {
        apps.removeAll { $0 == selection }
        selection = nil
        Prefs.excludedApps = apps
    }
}

/// Click, then press the new combination. Esc cancels.
private struct ShortcutRecorder: View {
    let onChange: () -> Bool
    @AppStorage("hotKeyLabel") private var label = "⌘⇧V"
    @State private var recording = false
    @State private var monitor: Any?
    @State private var failed = false

    var body: some View {
        HStack {
            if failed { Text("Taken by another app").font(.caption).foregroundStyle(.red) }
            Button(recording ? "Press shortcut…" : label) { recording ? stop() : start() }
                .frame(minWidth: 110)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        failed = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require ⌘, ⌥ or ⌃ so plain typing never triggers the panel.
            guard !mods.intersection([.command, .option, .control]).isEmpty else { NSSound.beep(); return nil }
            let old = Prefs.hotKey
            Prefs.d.set(Int(e.keyCode), forKey: "hotKeyCode")
            Prefs.d.set(Int(HotKey.carbonMods(mods)), forKey: "hotKeyMods")
            Prefs.d.set(HotKey.label(e), forKey: "hotKeyLabel")
            if !onChange() {
                Prefs.d.set(Int(old.code), forKey: "hotKeyCode")
                Prefs.d.set(Int(old.mods), forKey: "hotKeyMods")
                Prefs.d.set(old.label, forKey: "hotKeyLabel")
                _ = onChange()
                failed = true
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct WelcomeView: View {
    let close: () -> Void
    @AppStorage("hotKeyLabel") private var hotKey = "⌘⇧V"
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ClipStash is running 👋").font(.system(size: 22, weight: .semibold))
            Text("It lives in your menu bar and quietly remembers everything you copy. Two things to know:")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            step(done: true, n: 1, title: "Press \(hotKey) from any app", detail: "Your clipboard history pops up. Type to search, ↵ to paste.")
            step(done: trusted, n: 2, title: "Let ClipStash paste for you",
                 detail: trusted ? "Done. ↵ pastes straight into the app you were using."
                                 : "Turn ClipStash on in the list that opens. Skip it and ↵ only copies; you press ⌘V.") {
                if !trusted { Button("Open Accessibility Settings") { Paster.requestAccessibility() } }
            }
            HStack {
                Spacer()
                Button("Got it", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }

    private func step(done: Bool, n: Int, title: String, detail: String,
                      @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 24, height: 24)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(n)").font(.system(size: 12, weight: .semibold)) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
    }
}
