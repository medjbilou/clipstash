import Foundation

public enum ClipKind: String, CaseIterable, Sendable {
    case text, link, code, image, file

    public var label: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .code: "Code"
        case .image: "Image"
        case .file: "File"
        }
    }
}

public struct Clip: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var kind: ClipKind
    /// Text body; for files, one absolute path per line.
    public var text: String?
    /// File name of the PNG inside the store's image folder.
    public var image: String?
    /// User-given name, shown instead of the content.
    public var title: String?
    public var app: String?
    public var bundle: String?
    public var created: Date
    public var pinned: Bool
    public var expires: Date?
    public var size: Int

    public var filePaths: [String] {
        kind == .file ? (text ?? "").split(separator: "\n").map(String.init) : []
    }

    /// One-line label for lists.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.count > 1 ? "\(names[0]) +\(names.count - 1) more" : (names.first ?? "File")
        case .image:
            return text ?? "Image"
        default:
            // Only the head matters for a one-line label; trimming a multi-MB clip on every render is not free.
            let line = (text ?? "").prefix(2000).trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return String(line.prefix(200))
        }
    }

    public var hexColor: (r: Double, g: Double, b: Double)? {
        kind == .text ? Classifier.hexColor(text ?? "") : nil
    }
}

public enum ClipFilter: String, CaseIterable, Sendable {
    case all = "All", favorites = "Favorites", text = "Text", links = "Links", code = "Code", images = "Images", files = "Files"

    var kind: ClipKind? {
        switch self {
        case .text: .text
        case .links: .link
        case .code: .code
        case .images: .image
        case .files: .file
        case .all, .favorites: nil
        }
    }
}

public enum Classifier {
    static let codeApps: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "dev.zed.Zed", "com.sublimetext.4", "com.sublimetext.3", "com.panic.Nova", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "io.alacritty",
    ]

    public static func kind(for text: String, bundle: String?) -> ClipKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink(t) { return .link }
        if let bundle, codeApps.contains(bundle) || bundle.hasPrefix("com.jetbrains.") { return .code }
        return looksLikeCode(t) ? .code : .text
    }

    public static func isLink(_ t: String) -> Bool {
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return false }
        if t.lowercased().hasPrefix("www.") { return t.count > 6 }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp"].contains(scheme) && url.host != nil
    }

    public static func looksLikeCode(_ t: String) -> Bool {
        guard t.count >= 4 else { return false }
        let strong = ["=>", "->", "::", "();", "){", ") {", "};", "</", "/>", "#include", "#!/", "&&", "||", "!==", "==="]
        let keywords = ["const ", "let ", "var ", "func ", "function ", "def ", "class ", "import ", "return ",
                        "public ", "private ", "struct ", "enum ", "SELECT ", "npm ", "git ", "sudo ", "cd ", "pip ",
                        "brew ", "curl ", "docker ", "yarn ", "pnpm ", "npx "]
        var score = strong.filter { t.contains($0) }.count * 2
        score += keywords.filter { t.hasPrefix($0) || t.contains("\n" + $0) }.count * 2
        let lines = t.split(separator: "\n")
        score += lines.filter { $0.hasSuffix(";") || $0.hasSuffix("{") || $0.hasSuffix("}") }.count
        if lines.count > 1, lines.contains(where: { $0.hasPrefix("    ") || $0.hasPrefix("\t") }) { score += 1 }
        return score >= 2
    }

    public static func hexColor(_ text: String) -> (r: Double, g: Double, b: Double)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#") else { return nil }
        var hex = String(t.dropFirst())
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// 6-8 digit codes, optionally split once by a space or dash ("482 913", "123-456").
    public static func isOneTimeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.range(of: #"^\d{3,4}[ -]?\d{3,4}$"#, options: .regularExpression) != nil
            && t.filter(\.isNumber).count >= 6
    }
}
