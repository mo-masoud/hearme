import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State: Equatable {
        case loading
        case ready
        case recording
        case transcribing
        case failed(String)
    }

    /// A press shorter than this is a tap: recording continues until the next press.
    private static let tapThreshold: TimeInterval = 0.35
    /// Clips shorter than this are treated as accidental presses.
    private static let minimumSeconds = 0.3
    /// Keeps recording briefly after release so the last word isn't clipped.
    private static let releaseTail: TimeInterval = 0.25

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let hotKey = HotKeyMonitor()
    private let shortcutRecorder = ShortcutRecorder()
    private let correctionsWindow = CorrectionsWindowController()
    private let historyWindow = HistoryWindowController()
    private var cleanupTimer: Timer?
    private var shortcut = Shortcut.load() ?? .defaultShortcut
    private let recorder = AudioRecorder()
    private let work = DispatchQueue(label: "hearme.transcribe", qos: .userInitiated)
    private var transcriber: Transcriber?
    /// Optional: without it, the whole clip (silence included) goes to the model.
    private var speechDetector: SpeechDetector?

    private var state: State = .loading {
        didSet {
            DebugLog.write("state \(state)")
            refresh()
        }
    }
    private var pressedAt = Date.distantPast
    private var toggleMode = false
    private var lastText: String?
    private var lastNote: String?
    private var trustTimer: Timer?

    /// "hold": hold the key while speaking (a quick tap also toggles).
    /// "toggle": press once to start, press again to stop.
    private var mode: String {
        get { UserDefaults.standard.string(forKey: "mode") ?? "hold" }
        set { UserDefaults.standard.set(newValue, forKey: "mode"); refresh() }
    }

    /// Seconds the mic stays open after dictating: "0" (off), "15" or "30" (default).
    /// Open means the next dictation starts instantly, but a Bluetooth headset stays in call mode meanwhile.
    private static let standbyChoices = [("0", "Off (close after each dictation)"),
                                         ("15", "15 Seconds After Dictating"),
                                         ("30", "30 Seconds After Dictating")]
    private var standby: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "standby") ?? "30"
            return Self.standbyChoices.contains { $0.0 == saved } ? saved : "30"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "standby")
            recorder.close()
            applyStandby()
        }
    }
    private var standbyTimer: Timer?

    /// "system" (default), "builtin", or a device UID.
    private var microphone: String {
        get { UserDefaults.standard.string(forKey: "microphone") ?? AudioDevices.systemChoice }
        set {
            UserDefaults.standard.set(newValue, forKey: "microphone")
            recorder.close()
            applyStandby()
        }
    }

    private var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "ar" }
        set { UserDefaults.standard.set(newValue, forKey: "language"); refresh() }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Transcriber.configureLogging()
        Corrections.ensureFile()
        refresh()

        hotKey.onPress = { [weak self] in self?.hotKeyPressed() }
        hotKey.onRelease = { [weak self] releasedAt in self?.hotKeyReleased(at: releasedAt) }
        hotKey.onEscape = { [weak self] in
            if self?.state == .recording { self?.cancelRecording() }
        }
        recorder.onLimitReached = { [weak self] in self?.finishRecording() }
        // The start cue plays once the mic really hears something, so you know when to speak.
        // No sound here: playing through Bluetooth headphones while their mic is
        // waking interrupts the mic again. The icon turns red once it's live.
        recorder.onLive = { [weak self] in self?.refresh() }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        registerSavedShortcut()
        watchAccessibility()
        loadModel()
        applyStandby()
        if CommandLine.arguments.contains("--show-corrections") {
            correctionsWindow.show()
        }
        if CommandLine.arguments.contains("--show-history") {
            historyWindow.show()
        }

        // Old recordings are removed per the History window's setting (default: 2 months).
        History.cleanup()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            History.cleanup()
        }
    }

    private func loadModel() {
        state = .loading
        work.async { [weak self] in
            let result: Result<Transcriber, Error> = Result {
                guard let url = AppPaths.resolveModel() else {
                    throw TranscriberError.open(AppPaths.missingModelMessage)
                }
                let transcriber = try Transcriber(modelURL: url)
                if let vad = AppPaths.resolveVAD() {
                    do {
                        let detector = try SpeechDetector(modelURL: vad)
                        DispatchQueue.main.async { self?.speechDetector = detector }
                    } catch {
                        FileHandle.standardError.write(Data("[vad] \(error.localizedDescription)\n".utf8))
                    }
                }
                // Pays the one-time Metal shader setup now instead of on the first dictation.
                _ = try? transcriber.transcribe([Float](repeating: 0, count: Transcriber.sampleRate), language: "ar")
                return transcriber
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let transcriber):
                    self.transcriber = transcriber
                    self.state = .ready
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Falls back to F13 if the saved shortcut was taken by another app meanwhile.
    private func registerSavedShortcut() {
        if hotKey.register(shortcut) { return }
        let wanted = shortcut
        if wanted != .defaultShortcut, hotKey.register(.defaultShortcut) {
            shortcut = .defaultShortcut
            shortcut.save()
            lastNote = "\(wanted.display) is used by another app, so HearMe went back to F13."
        } else {
            lastNote = "\(wanted.display) is used by another app. Choose another shortcut."
        }
    }

    /// Closes the mic or keeps it open, per the "Keep Microphone Ready" setting.
    private func applyStandby() {
        standbyTimer?.invalidate()
        standbyTimer = nil
        defer { refresh() }
        guard !recorder.isRecording else { return }
        let seconds = TimeInterval(standby) ?? 0
        guard seconds > 0 else {
            recorder.close()
            return
        }
        // The mic opens on a dictation, then stays ready this long for the next one.
        guard recorder.isOpen else { return }
        standbyTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, !self.recorder.isRecording else { return }
            self.recorder.close()
            self.refresh()
        }
    }

    /// Pasting and the Esc monitor need Accessibility, so poll until it is granted.
    private func watchAccessibility() {
        if Accessibility.isTrusted {
            hotKey.startEscapeMonitor()
            return
        }
        Accessibility.prompt()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Accessibility.isTrusted else { return }
            timer.invalidate()
            self?.hotKey.startEscapeMonitor()
            self?.refresh()
        }
    }

    // MARK: Hotkey

    private func hotKeyPressed() {
        switch state {
        case .ready:
            beginRecording()
            if mode == "toggle" { toggleMode = true; refresh() }
        case .recording where toggleMode:
            finishRecording(after: Self.releaseTail)
        default:
            break
        }
    }

    /// Arrives after the hot key's debounce, so the recording already ran ~0.3 s past
    /// the real release: enough tail for the last word, no extra delay needed.
    private func hotKeyReleased(at releasedAt: Date) {
        guard state == .recording, !toggleMode else { return }
        if releasedAt.timeIntervalSince(pressedAt) < Self.tapThreshold {
            toggleMode = true
            refresh()
        } else {
            finishRecording()
        }
    }

    // MARK: Recording

    private func beginRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            lastNote = "Microphone access is off. Allow HearMe in System Settings → Privacy & Security → Microphone."
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            Sounds.play("Basso")
            refresh()
            return
        }
        // Before the mic starts: starting can take a moment, and hold-vs-tap is measured from here.
        pressedAt = Date()
        standbyTimer?.invalidate()
        let wasLive = recorder.isLive
        do {
            try recorder.start(device: AudioDevices.resolve(microphone))
            toggleMode = false
            lastNote = nil
            state = .recording
            // The mic was already open and hearing: speak right away.
            // Otherwise the icon turns from orange to red once it wakes.
            if wasLive { Sounds.play("Tink") }
        } catch {
            lastNote = error.localizedDescription
            Sounds.play("Basso")
            refresh()
        }
    }

    private func cancelRecording() {
        _ = recorder.stop()
        pressedAt = .distantPast // drops a pending delayed finish
        Sounds.play("Funk")
        state = .ready
        applyStandby()
    }

    private func finishRecording(after delay: TimeInterval) {
        let pressed = pressedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // Skip if this recording was cancelled or replaced meanwhile.
            guard let self, self.pressedAt == pressed else { return }
            self.finishRecording()
        }
    }

    private func finishRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        Sounds.play("Pop")
        applyStandby()
        let seconds = Double(samples.count) / Double(Transcriber.sampleRate)
        if seconds >= Self.minimumSeconds, !samples.contains(where: { abs($0) > 0.0001 }) {
            lastNote = "The microphone sent only silence. Pick another one under Microphone."
            state = .ready
            return
        }
        guard seconds >= Self.minimumSeconds, let transcriber else {
            state = .ready
            return
        }

        state = .transcribing
        let language = self.language
        let detector = speechDetector
        work.async { [weak self] in
            let started = Date()
            // Only the speech goes to the model; a clip with no speech is dropped.
            let speech = (try? detector?.speechOnly(samples)) ?? samples
            guard !speech.isEmpty else {
                DispatchQueue.main.async {
                    self?.lastNote = "No speech heard."
                    self?.state = .ready
                }
                return
            }
            let outcome = Result { try transcriber.transcribe(speech, language: language) }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            var finalText: String?
            if case .success(let raw) = outcome {
                let text = Corrections.apply(raw)
                finalText = text
                History.save(samples: samples, entry: .init(
                    date: started, language: language, durationSeconds: seconds,
                    transcribeMilliseconds: elapsed, raw: raw, final: text))
            }

            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success:
                    if let text = finalText, !text.isEmpty {
                        self.lastText = text
                        self.lastNote = Paster.paste(text)
                            ? nil
                            : "Copied to clipboard. Grant Accessibility so HearMe can paste for you."
                    }
                case .failure(let error):
                    self.lastNote = error.localizedDescription
                    Sounds.play("Basso")
                }
                self.state = .ready
            }
        }
    }

    // MARK: Menu bar

    private func refresh() {
        statusItem.button?.image = icon()
        statusItem.button?.toolTip = "HearMe: \(statusLine)"
        statusItem.menu = buildMenu()
    }

    private var statusLine: String {
        switch state {
        case .loading: return "Loading model…"
        case .ready:
            guard Accessibility.isTrusted else { return "Ready: grant Accessibility to paste" }
            return mode == "toggle"
                ? "Ready: press \(shortcut.display) to start, again to stop"
                : "Ready: hold \(shortcut.display) to talk"
        case .recording where !recorder.isLive: return "Waking the microphone…"
        case .recording: return toggleMode ? "Listening: press \(shortcut.display) again to finish" : "Listening: release to finish"
        case .transcribing: return "Transcribing…"
        case .failed(let message): return message
        }
    }

    private func icon() -> NSImage? {
        let (name, tint): (String, NSColor?) = switch state {
        case .loading: ("hourglass", nil)
        case .ready: (Accessibility.isTrusted ? "waveform" : "waveform.slash", nil)
        case .recording: recorder.isLive ? ("mic.fill", .systemRed) : ("mic", .systemOrange)
        case .transcribing: ("ellipsis.circle", nil)
        case .failed: ("exclamationmark.triangle", .systemOrange)
        }
        var image = NSImage(systemSymbolName: name, accessibilityDescription: "HearMe")
        guard let tint else {
            image?.isTemplate = true
            return image
        }
        image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
        image?.isTemplate = false
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabled(statusLine))
        if state == .ready || state == .recording {
            menu.addItem(disabled(mode == "toggle" ? "Esc cancels" : "Tap \(shortcut.display) to toggle · Esc cancels"))
        }
        if let lastNote {
            menu.addItem(disabled("⚠︎ " + lastNote))
        }
        if let lastText {
            menu.addItem(.separator())
            let preview = lastText.count > 48 ? String(lastText.prefix(48)) + "…" : lastText
            menu.addItem(item("Copy last: \(preview)", #selector(copyLast)))
        }

        menu.addItem(.separator())
        let languages = NSMenu()
        for (code, title) in [("ar", "Arabic (with English terms)"), ("en", "English")] {
            let entry = item(title, #selector(chooseLanguage(_:)))
            entry.representedObject = code
            entry.state = language == code ? .on : .off
            languages.addItem(entry)
        }
        let modes = NSMenu()
        for (code, title) in [("hold", "Hold to Talk"), ("toggle", "Press to Start, Press to Stop")] {
            let entry = item(title, #selector(chooseMode(_:)))
            entry.representedObject = code
            entry.state = mode == code ? .on : .off
            modes.addItem(entry)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modes
        menu.addItem(modeItem)

        let microphones = NSMenu()
        var micChoices: [(String, String)] = [
            (AudioDevices.systemChoice, "System Default"),
            (AudioDevices.builtInChoice, "Built-in Microphone (silent with the lid closed)"),
        ]
        for device in AudioDevices.inputs() where !device.isBuiltIn {
            micChoices.append((device.uid, device.name + (device.isBluetooth ? " (Bluetooth, slower start)" : "")))
        }
        for (choice, title) in micChoices {
            let entry = item(title, #selector(chooseMicrophone(_:)))
            entry.representedObject = choice
            entry.state = microphone == choice ? .on : .off
            microphones.addItem(entry)
        }
        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = microphones
        menu.addItem(microphoneItem)

        let standbyMenu = NSMenu()
        for (code, title) in Self.standbyChoices {
            let entry = item(title, #selector(chooseStandby(_:)))
            entry.representedObject = code
            entry.state = standby == code ? .on : .off
            standbyMenu.addItem(entry)
        }
        let standbyItem = NSMenuItem(title: "Keep Microphone Ready", action: nil, keyEquivalent: "")
        standbyItem.submenu = standbyMenu
        menu.addItem(standbyItem)

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        menu.addItem(languageItem)
        let shortcutItem = item("Shortcut: \(shortcut.display)", #selector(changeShortcut))
        shortcutItem.isEnabled = state != .recording && state != .transcribing
        menu.addItem(shortcutItem)
        if shortcut != .defaultShortcut {
            menu.addItem(item("Reset Shortcut to F13", #selector(resetShortcut)))
        }
        menu.addItem(item("Edit Corrections…", #selector(editCorrections)))
        menu.addItem(item("History…", #selector(openHistory)))

        menu.addItem(.separator())
        if !Accessibility.isTrusted {
            menu.addItem(item("Grant Accessibility Access…", #selector(grantAccessibility)))
        }
        if case .failed = state {
            menu.addItem(item("Retry Loading Model", #selector(retryLoad)))
        }
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit HearMe", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: Menu actions

    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func chooseStandby(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { standby = code }
    }

    @objc private func chooseMicrophone(_ sender: NSMenuItem) {
        if let choice = sender.representedObject as? String { microphone = choice }
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { mode = code }
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { language = code }
    }

    @objc private func changeShortcut() {
        guard !shortcutRecorder.isOpen, state != .recording, state != .transcribing else { return }
        // Off while recording the new combination, so pressing the old one doesn't start dictation.
        hotKey.unregister()
        shortcutRecorder.begin(current: shortcut) { [weak self] chosen in
            self?.applyShortcut(chosen)
        }
    }

    @objc private func resetShortcut() {
        applyShortcut(.defaultShortcut)
    }

    /// Switches only if the new shortcut registers; otherwise the old one stays active.
    private func applyShortcut(_ chosen: Shortcut?) {
        if let chosen, chosen != shortcut {
            if hotKey.register(chosen) {
                shortcut = chosen
                shortcut.save()
                lastNote = nil
            } else {
                lastNote = "\(chosen.display) is used by another app. Kept \(shortcut.display)."
                Sounds.play("Basso")
                _ = hotKey.register(shortcut)
            }
        } else if !hotKey.isRunning {
            _ = hotKey.register(shortcut)
        }
        refresh()
    }

    @objc private func editCorrections() {
        correctionsWindow.show()
    }

    @objc private func openHistory() {
        historyWindow.show()
    }

    @objc private func grantAccessibility() {
        Accessibility.prompt()
        Accessibility.openSettings()
    }

    @objc private func retryLoad() {
        loadModel()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastNote = "Launch at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// System sounds played off the main thread: waking Bluetooth headphones can
/// block for up to a second, which delayed the hotkey handling.
enum Sounds {
    private static let queue = DispatchQueue(label: "hearme.sounds")

    static func play(_ name: String) {
        queue.async { NSSound(named: NSSound.Name(name))?.play() }
    }
}
