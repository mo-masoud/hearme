import AppKit

/// `HearMe --transcribe <audio> [--lang ar|en]` runs the same pipeline once from
/// the command line (no UI, no paste, no history) and prints the result.
func runCommandLine(_ arguments: [String]) -> Int32 {
    guard let index = arguments.firstIndex(of: "--transcribe"), index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("usage: HearMe --transcribe <audio> [--lang ar|en]\n".utf8))
        return 2
    }
    let audio = URL(fileURLWithPath: arguments[index + 1])
    var language = "ar"
    if let langIndex = arguments.firstIndex(of: "--lang"), langIndex + 1 < arguments.count {
        language = arguments[langIndex + 1]
    }
    do {
        Transcriber.configureLogging()
        Corrections.ensureFile()
        guard let model = AppPaths.resolveModel() else {
            throw TranscriberError.open(AppPaths.missingModelMessage)
        }
        var clock = Date()
        let transcriber = try Transcriber(modelURL: model)
        let loadMs = Int(Date().timeIntervalSince(clock) * 1000)
        let samples = try PCM.load(audio)
        clock = Date()
        let detector = AppPaths.resolveVAD().flatMap { try? SpeechDetector(modelURL: $0) }
        let speech = try detector?.speechOnly(samples) ?? samples
        print("speech:  \(String(format: "%.1f", Double(speech.count) / 16_000)) s kept by VAD\(detector == nil ? " (VAD not loaded)" : "")")
        guard !speech.isEmpty else {
            print("result:  no speech, nothing pasted")
            return 0
        }
        let raw = try transcriber.transcribe(speech, language: language)
        let runMs = Int(Date().timeIntervalSince(clock) * 1000)
        print("model:   \(model.path)")
        print("audio:   \(String(format: "%.1f", Double(samples.count) / 16_000)) s, load \(loadMs) ms, transcribe \(runMs) ms")
        print("raw:     \(raw)")
        print("final:   \(Corrections.apply(raw))")
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

if CommandLine.arguments.contains("--transcribe") {
    exit(runCommandLine(CommandLine.arguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
