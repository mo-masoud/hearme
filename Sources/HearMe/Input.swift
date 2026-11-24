import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Push-to-talk through a Carbon hot key: works without Accessibility,
/// reports press and release, and the key never reaches the focused app.
/// Esc (to cancel) is watched with an event monitor, which needs Accessibility.
final class HotKeyMonitor {
    private static let escapeKeyCode = UInt16(kVK_Escape)
    private static let signature: OSType = 0x4852_4D45 // "HRME"

    /// A release followed by a press within this window is key repeat, not a real release.
    private static let releaseDebounce: TimeInterval = 0.3

    var onPress: (() -> Void)?
    /// Receives when the key actually went up (before the debounce delay).
    var onRelease: ((Date) -> Void)?
    var onEscape: (() -> Void)?

    private(set) var isHeld = false
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var escapeMonitors: [Any] = []
    private var pendingRelease: DispatchWorkItem?

    var isRunning: Bool { hotKeyRef != nil }

    /// Registers `shortcut`, replacing any previous one.
    /// Returns false (and leaves nothing registered) if another app already owns it.
    func register(_ shortcut: Shortcut) -> Bool {
        installHandlerIfNeeded()
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        pendingRelease?.cancel()
        pendingRelease = nil
        isHeld = false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(kind: GetEventKind(event))
            return noErr
        }, events.count, &events, context, &handlerRef)
    }

    /// Call once Accessibility is granted; global key monitors see nothing before that.
    func startEscapeMonitor() {
        guard escapeMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == Self.escapeKeyCode { self?.onEscape?() }
        }
        let added: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handler($0); return $0 },
        ]
        escapeMonitors = added.compactMap { $0 }
    }

    /// Holding the key makes macOS repeat it, which arrives as released/pressed pairs.
    /// A release only counts once no press follows it within `releaseDebounce`.
    private func handle(kind: UInt32) {
        DebugLog.write("hotkey \(Int(kind) == kEventHotKeyPressed ? "pressed" : "released") held=\(isHeld) pending=\(pendingRelease != nil)")
        switch Int(kind) {
        case kEventHotKeyPressed:
            if let pending = pendingRelease {
                pending.cancel() // key repeat: the key never really went up
                pendingRelease = nil
                return
            }
            guard !isHeld else { return }
            isHeld = true
            onPress?()
        case kEventHotKeyReleased where isHeld && pendingRelease == nil:
            let releasedAt = Date()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRelease = nil
                self.isHeld = false
                self.onRelease?(releasedAt)
            }
            pendingRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDebounce, execute: work)
        default:
            break
        }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that points at the Accessibility list.
    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Types text into the focused app by pasting it, then puts the old clipboard back.
enum Paster {
    private static let vKeyCode: CGKeyCode = 9

    /// Returns false when Accessibility is missing; the text is then left on the clipboard.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard Accessibility.isTrusted else { return false }
        let ourChange = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // Give the target app time to read the clipboard before restoring it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ourChange else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return true
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
