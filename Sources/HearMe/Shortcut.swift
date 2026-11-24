import AppKit
import Carbon.HIToolbox

/// A push-to-talk key combination, stored in Carbon terms so it can be registered as a hot key.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    var keyName: String

    static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0, keyName: "F13")
    private static let defaultsKey = "shortcut"

    var display: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyName
    }

    static func load() -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    /// Builds a shortcut from a key press. Nil for keys that have no name (e.g. a lone modifier).
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        guard let name = Self.functionKeys[code] ?? Self.specialKeys[code] ?? Self.characterKeys[code] else {
            return nil
        }
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(code), modifiers: carbon, keyName: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// Why this shortcut would be a bad push-to-talk key, or nil if it's safe.
    var problem: String? {
        let code = Int(keyCode)
        let strongModifiers = modifiers & UInt32(cmdKey | optionKey | controlKey)
        if code == kVK_Escape {
            return "Esc is reserved for cancelling a recording."
        }
        if Self.functionKeys[code] == nil && strongModifiers == 0 {
            return "Add ⌘, ⌥ or ⌃ (or use an F-key), so normal typing isn't blocked."
        }
        if modifiers == UInt32(cmdKey) && Self.characterKeys[code] != nil {
            return "⌘ + a single key is an app shortcut (copy, save, quit…). Add another modifier."
        }
        if Self.reserved.contains(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) {
            return "\(display) is used by macOS or your language switcher."
        }
        return nil
    }

    // MARK: Key tables

    /// Combinations macOS or this Mac's setup already relies on.
    private static let reserved: [Shortcut] = [
        Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), keyName: "Space"),      // Spotlight
        Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), keyName: "Space"),  // input source (Karabiner)
        Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), keyName: "Space"),
        Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(cmdKey), keyName: "Tab"),          // app switcher
        Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey), keyName: "3"), // screenshots
        Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), keyName: "4"),
        Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey), keyName: "5"),
        Shortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey | optionKey), keyName: "Q"),
        Shortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey | optionKey), keyName: "Esc"), // Force Quit
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "Tab", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
    ]

    /// US-layout names by key position, so the label is the same with the Arabic layout active.
    private static let characterKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
    ]
}

/// A small window that waits for the next key combination and checks it before accepting.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((Shortcut?) -> Void)?
    private let messageLabel = NSTextField(labelWithString: "")

    var isOpen: Bool { panel != nil }

    /// Calls `completion` once: with the new shortcut, or nil if the user cancelled.
    func begin(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        guard panel == nil else { return }
        self.completion = completion

        let title = NSTextField(labelWithString: "Press the new shortcut")
        title.font = .boldSystemFont(ofSize: 15)
        let currentLabel = NSTextField(labelWithString: "Current: \(current.display)    ·    Esc cancels")
        currentLabel.textColor = .secondaryLabelColor
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = " "
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.preferredMaxLayoutWidth = 340

        let stack = NSStackView(views: [title, currentLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "HearMe Shortcut"
        panel.contentView = stack
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self
        panel.center()
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow: the key belongs to the recorder
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            finish(nil)
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            reject("That key can't be used. Try an F-key or a combination like ⌥⌘D.")
            return
        }
        if let problem = shortcut.problem {
            reject(problem)
            return
        }
        finish(shortcut)
    }

    private func reject(_ message: String) {
        messageLabel.stringValue = message
        NSSound.beep()
    }

    private func finish(_ shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let completion = self.completion
        self.completion = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        completion?(shortcut)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }
}
