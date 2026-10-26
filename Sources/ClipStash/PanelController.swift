import AppKit
import Carbon.HIToolbox
import ClipCore
import SwiftUI

/// Key-capable panel that never activates the app, so the app you were in stays frontmost for pasting.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    let panel: HistoryPanel
    private let state: AppState
    private var keyMonitor: Any?

    init(state: AppState) {
        self.state = state
        panel = HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 470),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                             backing: .buffered, defer: true)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Solid background: a translucent material lets busy windows behind bleed through the text.
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = NSHostingView(rootView: PanelView(state: state))

        state.hidePanel = { [weak self] in self?.hide() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        state.previousApp = NSWorkspace.shared.frontmostApplication
        state.query = ""
        state.reload()
        state.selectedID = state.clips.first?.id
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
        state.openToken += 1
    }

    func hide() {
        state.isRenaming = false
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Panel shortcuts. Returns true when the event was handled.
    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let key = Int(e.keyCode)
        if key == kVK_Escape {
            if state.isRenaming { state.openToken += 1 } else { hide() }
            return true
        }
        if state.isRenaming { return false }
        let clip = state.selected
        switch key {
        case kVK_DownArrow: state.move(cmd ? 100_000 : 1)
        case kVK_UpArrow: state.move(cmd ? -100_000 : -1)
        case kVK_PageDown: state.move(10)
        case kVK_PageUp: state.move(-10)
        case kVK_Tab: state.cycleFilter(shift ? -1 : 1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if shift { clip.map(state.toggleQueue) } else { state.pasteSelectedOrQueued() }
        case kVK_Delete where cmd: clip.map(state.delete)
        default:
            guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
            switch ch {
            case "c" where !shift: clip.map(state.copy)
            case "p": clip.map(state.togglePin)
            case "r": if clip != nil { state.renameToken += 1 }
            case "s": if let clip, clip.kind == .image { state.saveImage(clip) }
            case ",": state.openSettings()
            case "1", "2", "3", "4", "5", "6", "7": state.filter = ClipFilter.allCases[Int(ch)! - 1]
            default: return false
            }
        }
        return true
    }
}
