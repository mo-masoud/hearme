import AVFoundation
import AudioToolbox

enum AudioError: LocalizedError {
    case noInputDevice
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input is available."
        case .unreadable(let path): return "Could not read audio file: \(path)"
        }
    }
}

/// 16 kHz mono float32: the only format the model accepts.
enum PCM {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Transcriber.sampleRate),
        channels: 1,
        interleaved: false
    )!

    static func makeConverter(from source: AVAudioFormat) -> AVAudioConverter? {
        let converter = AVAudioConverter(from: source, to: format)
        converter?.downmix = true
        return converter
    }

    /// Converts one buffer. The converter keeps resampler state between calls,
    /// so a stream of buffers converts without clicks at the seams.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, flush: Bool = false) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = flush ? .endOfStream : .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              let converter = makeConverter(from: file.processingFormat) else {
            throw AudioError.unreadable(url.path)
        }
        try file.read(into: buffer)
        return convert(buffer, with: converter, flush: true)
    }

    /// Writes 16-bit PCM WAV, so history clips open anywhere and can feed fine-tuning later.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let rate = UInt32(Transcriber.sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))          // PCM, mono
        append(rate); append(rate * 2)                // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))         // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        try data.write(to: url)
    }
}

/// Captures a microphone as 16 kHz mono float32 with an input-only Audio Queue.
///
/// The queue can stay open between recordings ("standby"): a Bluetooth headset
/// needs ~2 s to switch into call mode each time its mic opens, which cut off
/// the first words. While open and idle it keeps the last 0.3 s as pre-roll, so
/// the very start of a sentence is kept too.
final class AudioRecorder {
    /// Called on the main queue when a recording reaches `maxSeconds`.
    var onLimitReached: (() -> Void)?
    /// Called on the main queue once the open mic delivers real sound.
    var onLive: (() -> Void)?
    var maxSeconds: Double = 300

    private static let bufferCount = 4
    private static let bufferFrames = Transcriber.sampleRate / 20 // 50 ms
    private static let prerollSamples = Transcriber.sampleRate * 3 / 10 // 300 ms

    private let callbackQueue = DispatchQueue(label: "hearme.mic", qos: .userInteractive)
    private let lock = NSLock()
    private var queue: AudioQueueRef?
    private var openDeviceUID: String?
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var limitSignalled = false
    private var capturing = false
    private var live = false

    var isRecording: Bool { lock.withLock { capturing } }
    var isOpen: Bool { queue != nil }
    /// True once the open mic has delivered sound: a recording starting now loses nothing.
    var isLive: Bool { lock.withLock { live } }

    /// Opens the mic without recording, so the next `start` is instant.
    func prepare(device: AudioInputDevice?) throws {
        try open(device: device)
    }

    /// Opens the mic (or keeps it open) and starts collecting samples.
    func start(device: AudioInputDevice?) throws {
        try open(device: device)
        lock.withLock {
            samples = preroll
            preroll.removeAll(keepingCapacity: true)
            limitSignalled = false
            capturing = true
        }
    }

    /// Stops collecting and returns the recording. The mic stays open until `close()`.
    func stop() -> [Float] {
        let captured: [Float] = lock.withLock {
            guard capturing else { return [] }
            capturing = false
            return samples
        }
        let firstSound = captured.firstIndex { abs($0) > 0.0001 } ?? captured.count
        DebugLog.write("capture ended: \(captured.count) samples, first sound at \(firstSound * 1000 / Transcriber.sampleRate) ms")
        return captured
    }

    func close() {
        guard let queue else { return }
        lock.withLock {
            capturing = false
            live = false
            preroll.removeAll()
        }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
        openDeviceUID = nil
        DebugLog.write("mic closed")
    }

    private func open(device: AudioInputDevice?) throws {
        let wanted = device?.uid ?? ""
        if queue != nil, openDeviceUID == wanted { return }
        close()

        let began = Date()
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(Transcriber.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&created, &format, 0, callbackQueue) {
            [weak self] queue, buffer, _, _, _ in
            self?.append(buffer)
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let created else { throw AudioError.noInputDevice }

        if let device {
            var uid = device.uid as CFString
            AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice,
                                  &uid, UInt32(MemoryLayout<CFString>.size))
        }
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(created, UInt32(Self.bufferFrames * 4), &buffer)
            if let buffer { AudioQueueEnqueueBuffer(created, buffer, 0, nil) }
        }
        guard AudioQueueStart(created, nil) == noErr else {
            AudioQueueDispose(created, true)
            throw AudioError.noInputDevice
        }
        lock.withLock { live = false }
        queue = created
        openDeviceUID = wanted
        DebugLog.write("mic opened in \(Int(Date().timeIntervalSince(began) * 1000)) ms (\(device?.name ?? "system default"))")
    }

    private func append(_ buffer: AudioQueueBufferRef) {
        let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
        let pointer = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        let chunk = UnsafeBufferPointer(start: pointer, count: count)
        let limit = Int(maxSeconds) * Transcriber.sampleRate

        let (becameLive, reachedLimit): (Bool, Bool) = lock.withLock {
            var becameLive = false
            if !live, chunk.contains(where: { abs($0) > 0.0001 }) {
                live = true
                becameLive = true
            }
            guard capturing else {
                preroll.append(contentsOf: chunk)
                if preroll.count > Self.prerollSamples {
                    preroll.removeFirst(preroll.count - Self.prerollSamples)
                }
                return (becameLive, false)
            }
            samples.append(contentsOf: chunk)
            guard samples.count >= limit, !limitSignalled else { return (becameLive, false) }
            limitSignalled = true
            return (becameLive, true)
        }
        if becameLive {
            DebugLog.write("mic live")
            DispatchQueue.main.async { [weak self] in self?.onLive?() }
        }
        if reachedLimit {
            DispatchQueue.main.async { [weak self] in self?.onLimitReached?() }
        }
    }
}
