import AppKit
import Carbon.HIToolbox

/// UserDefaults keys and typed accessors. Views bind the same keys with @AppStorage.
enum Prefs {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            "maxClips": 1000,
            "maxImageMB": 10,
            "storageMB": 1024,
            "paused": false,
            "autoPaste": true,
            "saveScreenshots": true,
            "autoExpireCodes": true,
            "theme": "system",
            "excludedApps": [
                "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
            ],
            "hotKeyCode": kVK_ANSI_V,
            "hotKeyMods": cmdKey | shiftKey,
            "hotKeyLabel": "⌘⇧V",
            "welcomed": false,
        ])
    }

    static var maxClips: Int { d.integer(forKey: "maxClips") }
    static var maxImageBytes: Int { d.integer(forKey: "maxImageMB") * 1_048_576 }
    static var storageBytes: Int { d.integer(forKey: "storageMB") * 1_048_576 }
    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }
    static var autoPaste: Bool { d.bool(forKey: "autoPaste") }
    static var saveScreenshots: Bool { d.bool(forKey: "saveScreenshots") }
    static var autoExpireCodes: Bool { d.bool(forKey: "autoExpireCodes") }
    static var theme: String { d.string(forKey: "theme") ?? "system" }
    static var excludedApps: [String] {
        get { d.stringArray(forKey: "excludedApps") ?? [] }
        set { d.set(newValue, forKey: "excludedApps") }
    }
    static var hotKey: (code: UInt32, mods: UInt32, label: String) {
        (UInt32(d.integer(forKey: "hotKeyCode")), UInt32(d.integer(forKey: "hotKeyMods")), d.string(forKey: "hotKeyLabel") ?? "")
    }
    static var welcomed: Bool {
        get { d.bool(forKey: "welcomed") }
        set { d.set(newValue, forKey: "welcomed") }
    }

    static func applyTheme() {
        NSApp.appearance = switch theme {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}
