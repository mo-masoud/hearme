import CTranscribe
import Foundation

enum TranscriberError: LocalizedError {
    case open(String)
    case run(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Could not load the model: \(message)"
        case .run(let message): return "Transcription failed: \(message)"
        }
    }
}

/// Thin wrapper over the transcribe.cpp C API. Not thread-safe: call it from one queue.
final class Transcriber {
    static let sampleRate = 16_000

    private let session: OpaquePointer

    /// Routes library warnings and errors to stderr and drops the verbose Metal chatter.
    static func configureLogging() {
        transcribe_log_set({ level, message, _ in
            guard level == TRANSCRIBE_LOG_LEVEL_ERROR || level == TRANSCRIBE_LOG_LEVEL_WARN,
                  let message else { return }
            var line = "[transcribe] " + String(cString: message)
            if !line.hasSuffix("\n") { line += "\n" }
            FileHandle.standardError.write(Data(line.utf8))
        }, nil)
    }

    init(modelURL: URL) throws {
        var opened: OpaquePointer?
        let status = transcribe_open(modelURL.path, nil, nil, &opened)
        guard status == TRANSCRIBE_OK, let opened else {
            throw TranscriberError.open(Self.describe(status))
        }
        session = opened
    }

    deinit {
        transcribe_close(session)
    }

    /// - Parameters:
    ///   - pcm: mono float32 samples at 16 kHz.
    ///   - language: "ar" or "en". Forcing "ar" avoids a stray Latin first letter on Arabic speech.
    func transcribe(_ pcm: [Float], language: String) throws -> String {
        guard !pcm.isEmpty else { return "" }
        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        let status = language.withCString { lang -> transcribe_status in
            params.language = lang
            return pcm.withUnsafeBufferPointer { buffer in
                transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &params)
            }
        }
        guard status == TRANSCRIBE_OK else {
            throw TranscriberError.run(Self.describe(status))
        }
        guard let text = transcribe_full_text(session) else { return "" }
        return String(cString: text)
    }

    private static func describe(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}

/// Silero VAD: finds where someone is actually speaking, so silence and
/// background noise never reach the transcription model.
final class SpeechDetector {
    private let model: OpaquePointer
    private let session: OpaquePointer

    init(modelURL: URL) throws {
        var loaded: OpaquePointer?
        var status = transcribe_model_load_file(modelURL.path, nil, &loaded)
        guard status == TRANSCRIBE_OK, let loaded else {
            throw TranscriberError.open("VAD: " + Self.describe(status))
        }
        var opened: OpaquePointer?
        status = transcribe_vad_session_init(loaded, nil, &opened)
        guard status == TRANSCRIBE_OK, let opened else {
            transcribe_model_free(loaded)
            throw TranscriberError.open("VAD: " + Self.describe(status))
        }
        model = loaded
        session = opened
    }

    deinit {
        transcribe_vad_session_free(session)
        transcribe_model_free(model)
    }

    /// Returns only the speech in `pcm`, with long pauses shortened. Empty when nobody spoke.
    func speechOnly(_ pcm: [Float]) throws -> [Float] {
        guard !pcm.isEmpty else { return [] }
        var params = transcribe_vad_params()
        transcribe_vad_params_init(&params)
        params.min_speech_ms = 250    // ignore clicks and short bursts of noise
        params.min_silence_ms = 400   // a natural pause doesn't split the speech
        params.speech_pad_ms = 200    // keep soft word starts and endings

        let status = pcm.withUnsafeBufferPointer { buffer in
            transcribe_vad_run(session, buffer.baseAddress, Int32(buffer.count), &params)
        }
        guard status == TRANSCRIBE_OK else { throw TranscriberError.run("VAD: " + Self.describe(status)) }

        var result = transcribe_vad_result()
        transcribe_vad_result_init(&result)
        transcribe_vad_get_result(session, &result)

        let pause = [Float](repeating: 0, count: Transcriber.sampleRate / 5) // 200 ms between segments
        var speech: [Float] = []
        for index in 0..<result.n_segments {
            var segment = transcribe_vad_segment()
            transcribe_vad_segment_init(&segment)
            guard transcribe_vad_get_segment(session, index, &segment) == TRANSCRIBE_OK else { continue }
            let start = max(0, Int(segment.start_sample))
            let end = min(pcm.count, Int(segment.end_sample))
            guard start < end else { continue }
            if !speech.isEmpty { speech += pause }
            speech += pcm[start..<end]
        }
        return speech
    }

    private static func describe(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}
