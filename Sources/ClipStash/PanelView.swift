import AppKit
import ClipCore
import ImageIO
import SwiftUI

private let accent = Color(red: 0.36, green: 0.36, blue: 0.94)

struct PanelView: View {
    @ObservedObject var state: AppState
    @FocusState private var focus: Field?
    @AppStorage("paused") private var paused = false
    enum Field { case search, rename }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focus, equals: .search)
                if paused {
                    Text("Saving paused").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                }
                Button { state.openSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 4) {
                ForEach(ClipFilter.allCases, id: \.self) { f in
                    Button(f.rawValue) { state.filter = f }
                        .buttonStyle(PillStyle(selected: state.filter == f))
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            Divider()
            HStack(spacing: 0) {
                ClipList(state: state).frame(width: 470)
                Divider()
                if let clip = state.selected {
                    DetailView(state: state, clip: clip, focus: $focus).id(clip.id)
                } else {
                    Text(state.query.isEmpty ? "Copy something to get started" : "No matches")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Footer(state: state)
        }
        .frame(width: 780, height: 470)
        .onChange(of: state.query) { _ in state.reload() }
        .onChange(of: state.filter) { _ in state.reload() }
        .onChange(of: focus) { state.isRenaming = $0 == .rename }
        .onReceive(state.$openToken) { _ in focus = .search }
        .onReceive(state.$renameToken.dropFirst()) { _ in focus = .rename }
    }
}

private struct ClipList: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(state.clips) { clip in
                        ClipRow(state: state, clip: clip)
                            .id(clip.id)
                            .contentShape(Rectangle())
                            .onTapGesture { state.paste(clip) }
                            .onHover { inside in
                                guard inside, NSEvent.mouseLocation != state.keyNavMouse else { return }
                                state.selectedID = clip.id
                            }
                            .contextMenu { ClipMenu(state: state, clip: clip) }
                    }
                }
                .padding(6)
            }
            .onChange(of: state.selectedID) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

private struct ClipMenu: View {
    let state: AppState
    let clip: Clip

    var body: some View {
        Button("Paste") { state.paste(clip) }
        Button("Copy") { state.copy(clip) }
        Button(state.queue.contains(clip.id) ? "Remove from Queue" : "Add to Queue") { state.toggleQueue(clip) }
        Button(clip.pinned ? "Unpin" : "Pin") { state.togglePin(clip) }
        Button("Rename…") { state.selectedID = clip.id; state.renameToken += 1 }
        if clip.kind == .image { Button("Save to Downloads") { state.saveImage(clip) } }
        Divider()
        Button("Delete") { state.delete(clip) }
    }
}

private struct ClipRow: View {
    @ObservedObject var state: AppState
    let clip: Clip

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(state: state, clip: clip, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayTitle)
                    .font(clip.kind == .code && clip.title == nil ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    Text([clip.kind.label, clip.app, ago(clip.created, state.now)].compactMap { $0 }.joined(separator: " · "))
                    if let expires = clip.expires { TimerBadge(remaining: expires.timeIntervalSince(state.now)) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let n = state.queue.firstIndex(of: clip.id) {
                Text("\(n + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(accent, in: Circle())
            }
            if clip.pinned { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(state.selectedID == clip.id ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ClipIcon: View {
    let state: AppState
    let clip: Clip
    let size: CGFloat

    var body: some View {
        Group {
            if let c = clip.hexColor {
                RoundedRectangle(cornerRadius: 5).fill(Color(red: c.r, green: c.g, blue: c.b))
            } else if clip.kind == .image, let url = state.store.imageURL(clip), let img = Thumbs.image(url, max: size * 2) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
            } else if clip.kind == .file, let path = clip.filePaths.first {
                Image(nsImage: Thumbs.fileIcon(path)).resizable()
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.42)).foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch clip.kind {
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .file: "doc"
        case .text: "text.alignleft"
        }
    }
}

private struct DetailView: View {
    @ObservedObject var state: AppState
    let clip: Clip
    var focus: FocusState<PanelView.Field?>.Binding
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { preview.frame(maxWidth: .infinity, alignment: .topLeading).padding(12) }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                TextField("Add a name…", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                    .focused(focus, equals: .rename)
                    .onSubmit { state.rename(clip, to: name); focus.wrappedValue = .search }
                row(clip.kind.label, ByteCountFormatter.string(fromByteCount: Int64(clip.size), countStyle: .file))
                row(clip.app ?? "Unknown app", ago(clip.created, state.now) ?? "")
                HStack {
                    Label("Delete after", systemImage: "timer").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    ExpiryPicker(state: state, clip: clip)
                }
                actions
            }
            .padding(12)
        }
        .onAppear { name = clip.title ?? "" }
    }

    @ViewBuilder private var preview: some View {
        if let c = clip.hexColor {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 10).fill(Color(red: c.r, green: c.g, blue: c.b)).frame(height: 120)
                Text(clip.text ?? "").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Text("rgb(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
        } else if clip.kind == .image {
            if let url = state.store.imageURL(clip), let img = Thumbs.image(url, max: 900) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Image file missing").foregroundStyle(.secondary)
            }
        } else if clip.kind == .file {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(clip.filePaths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(nsImage: Thumbs.fileIcon(path)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading) {
                            Text((path as NSString).lastPathComponent).font(.system(size: 12))
                            Text(path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        } else {
            let text = clip.text ?? ""
            // Huge clips stay fully pasteable; only the preview is trimmed to keep the panel instant.
            Text(text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text)
                .font(clip.kind == .code ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            Button(clip.pinned ? "Unpin" : "Pin") { state.togglePin(clip) }
            switch clip.kind {
            case .image: Button("Save to Downloads") { state.saveImage(clip) }
            case .link:
                if let url = URL(string: clip.text?.hasPrefix("www.") == true ? "https://" + clip.text! : clip.text ?? "") {
                    Button("Open") { NSWorkspace.shared.open(url); state.hidePanel() }
                }
            case .file:
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(clip.filePaths.map { URL(fileURLWithPath: $0) })
                    state.hidePanel()
                }
            default: EmptyView()
            }
        }
        .controlSize(.small)
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

private struct ExpiryPicker: View {
    @ObservedObject var state: AppState
    let clip: Clip
    static let options: [(String, Int?)] = [("Off", nil), ("5m", 5), ("1h", 60), ("24h", 1440)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options, id: \.0) { label, minutes in
                Button(label) { state.setExpiry(clip, minutes: minutes) }
                    .buttonStyle(PillStyle(selected: label == current, compact: true))
            }
        }
    }

    /// Highlights the smallest option that covers the time left.
    private var current: String {
        guard let expires = clip.expires else { return "Off" }
        let left = expires.timeIntervalSince(state.now) / 60
        return Self.options.first { ($0.1 ?? 0) > 0 && Double($0.1!) >= left - 0.5 }?.0 ?? "24h"
    }
}

private struct TimerBadge: View {
    let remaining: TimeInterval

    var body: some View {
        let m = max(0, Int(remaining / 60))
        Label(m >= 60 ? "\(m / 60)h" : "\(max(m, 1))m", systemImage: "timer")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}

private struct Footer: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Hint(key: "↵", label: "Paste")
            Hint(key: "⌘C", label: "Copy")
            Hint(key: "⇧↵", label: "Queue")
            Hint(key: "⌘P", label: "Pin")
            Hint(key: "⌘R", label: "Rename")
            Hint(key: "⌘⌫", label: "Delete")
            Spacer()
            if let toast = state.toast {
                Text(toast).foregroundStyle(accent).transition(.opacity)
            } else if !state.queue.isEmpty {
                Text("\(state.queue.count) queued · ⌃⌘V pastes next").foregroundStyle(accent)
            } else {
                Text("\(state.total) items").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .animation(.easeOut(duration: 0.15), value: state.toast)
    }
}

private struct Hint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            Text(label)
        }
        .foregroundStyle(.secondary)
    }
}

struct PillStyle: ButtonStyle {
    let selected: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: selected ? .semibold : .regular))
            .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 2 : 4)
            .foregroundStyle(selected ? Color.white : Color.secondary)
            .background(selected ? accent : Color.clear, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Downsampled thumbnails and file icons, cached so scrolling 10k rows stays cheap.
enum Thumbs {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ url: URL, max: CGFloat) -> NSImage? {
        let key = "\(url.path)#\(Int(max))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: max] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options) else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        cache.setObject(img, forKey: key)
        return img
    }

    static func fileIcon(_ path: String) -> NSImage {
        let key = "icon:\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: key)
        return img
    }
}

func ago(_ date: Date, _ now: Date) -> String? {
    let s = Int(now.timeIntervalSince(date))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(s / 60)m ago"
    case ..<86400: return "\(s / 3600)h ago"
    case ..<(86400 * 30): return "\(s / 86400)d ago"
    default: return date.formatted(date: .abbreviated, time: .omitted)
    }
}
