import Foundation

/// Everything HearMe keeps lives in ~/Library/Application Support/HearMe.
enum AppPaths {
    static let modelFileName = "cohere-transcribe-arabic-07-2026-Q8_0.gguf"

    static let support: URL = directory(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearMe", isDirectory: true)
    )
    static var history: URL { directory(support.appendingPathComponent("history", isDirectory: true)) }
    static var models: URL { directory(support.appendingPathComponent("models", isDirectory: true)) }
    static var corrections: URL { support.appendingPathComponent("corrections.json") }

    static let vadFileName = "silero-vad-v6.2-F32.gguf"

    static func resolveModel() -> URL? { resolve(modelFileName) }
    static func resolveVAD() -> URL? { resolve(vadFileName) }

    /// Models live only in HearMe's own folder; scripts/download-models.sh puts them there.
    private static func resolve(_ fileName: String) -> URL? {
        let url = models.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let missingModelMessage =
        "model file not found (\(modelFileName)). Run scripts/download-models.sh from the HearMe repo."

    private static func directory(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Appends a timestamped line to ~/Library/Application Support/HearMe/debug.log.
enum DebugLog {
    private static let url = AppPaths.support.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "hearme.debuglog")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Personal fix-ups applied after every transcription: misheard words and
/// English terms the model writes in Arabic letters. Edited by hand as JSON.
enum Corrections {
    private static let seed: [String: String] = [
        "لارافيل": "Laravel",
        "جيت هاب": "GitHub",
        "دوكر": "Docker",
        "ريديس": "Redis",
        "بوستمان": "Postman",
    ]

    static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: AppPaths.corrections.path) else { return }
        save(seed)
    }

    static func save(_ table: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(table).write(to: AppPaths.corrections, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[corrections] \(error.localizedDescription)\n".utf8))
        }
    }

    /// Read on every call so edits apply to the next dictation without a restart.
    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: AppPaths.corrections),
              let table = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return table
    }

    static func apply(_ text: String, table: [String: String] = load()) -> String {
        var result = text
        // Longest first, so "جيت هاب أكشنز" wins over "جيت هاب".
        for key in table.keys.sorted(by: { $0.count > $1.count }) where !key.isEmpty {
            guard let regex = pattern(for: key) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: table[key]!))
        }
        return tidy(result)
    }

    /// Matches a key loosely: any alef/hamza form, ه/ة, ي/ى, and optional tashkeel,
    /// so one entry "لارافيل" also catches "لأرافيل" or "لارافيلَ".
    private static func pattern(for key: String) -> NSRegularExpression? {
        let tashkeel = "[\\u064B-\\u0652\\u0670]*"
        var pattern = ""
        for character in key {
            switch character {
            case "ا", "أ", "إ", "آ": pattern += "[اأإآ]"
            case "ه", "ة": pattern += "[هة]"
            case "ي", "ى": pattern += "[يى]"
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            pattern += tashkeel
        }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Non-speech tags the model emits: "@@@ضوضاء" for background noise and
    /// "<hesitation>" for filler sounds like "eh" or "umm".
    private static let nonSpeechTag = try! NSRegularExpression(pattern: "@{2,}\\S*|<[a-z_]+>")

    /// Strips non-speech tags, and the space the model puts before Arabic punctuation ("مرحبًا ،").
    private static func tidy(_ text: String) -> String {
        var result = nonSpeechTag.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        for mark in ["،", "؛", "؟", ".", ",", "!", "?", ":"] {
            result = result.replacingOccurrences(of: " " + mark, with: mark)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps each clip with what the model heard and what was pasted.
/// Over time this becomes a ready-made dataset for fine-tuning on your voice.
enum History {
    struct Entry: Codable {
        let date: Date
        let language: String
        let durationSeconds: Double
        let transcribeMilliseconds: Int
        let raw: String
        var final: String
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    static let didChange = Notification.Name("HearMeHistoryDidChange")

    /// One saved dictation: its metadata and the two files on disk.
    struct Item: Identifiable, Equatable {
        let id: String // file name without extension
        var entry: Entry
        var json: URL { AppPaths.history.appendingPathComponent(id + ".json") }
        var wav: URL { AppPaths.history.appendingPathComponent(id + ".wav") }

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.entry.final == rhs.entry.final
        }
    }

    /// Days to keep recordings; 0 keeps them forever. Default: 60 (two months).
    static var retentionDays: Int {
        get { UserDefaults.standard.object(forKey: "retentionDays") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "retentionDays") }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(samples: [Float], entry: Entry) {
        let base = AppPaths.history.appendingPathComponent(stampFormatter.string(from: entry.date))
        do {
            try PCM.writeWAV(samples, to: base.appendingPathExtension("wav"))
            try encoder.encode(entry).write(to: base.appendingPathExtension("json"))
        } catch {
            FileHandle.standardError.write(Data("[history] \(error.localizedDescription)\n".utf8))
        }
        notifyChange()
    }

    /// Newest first.
    static func loadAll() -> [Item] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.history, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Item? in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? decoder.decode(Entry.self, from: data) else { return nil }
                return Item(id: url.deletingPathExtension().lastPathComponent, entry: entry)
            }
            .sorted { $0.entry.date > $1.entry.date }
    }

    /// Saves an edited transcript.
    static func update(_ item: Item) {
        try? encoder.encode(item.entry).write(to: item.json, options: .atomic)
    }

    /// Moves a dictation to the Trash, so a mistaken delete can be undone from there.
    static func trash(_ items: [Item]) {
        for item in items {
            for url in [item.json, item.wav] {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        notifyChange()
    }

    /// Permanently deletes dictations older than `retentionDays`. Returns how many went.
    @discardableResult
    static func cleanup(now: Date = Date()) -> Int {
        let days = retentionDays
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let old = loadAll().filter { $0.entry.date < cutoff }
        for item in old {
            try? FileManager.default.removeItem(at: item.json)
            try? FileManager.default.removeItem(at: item.wav)
        }
        if !old.isEmpty {
            DebugLog.write("history cleanup: removed \(old.count) older than \(days) days")
            notifyChange()
        }
        return old.count
    }

    /// Bytes used by the history folder.
    static func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.history, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func notifyChange() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }
}
