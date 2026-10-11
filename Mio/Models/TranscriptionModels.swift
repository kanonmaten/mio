import Foundation

struct TranscriptionMetadata: Codable, Hashable, Sendable {
    let model: String
    let revision: String
    let backend: String

    var isValid: Bool {
        [model, revision, backend].allSatisfy { !$0.isEmpty && $0.utf8.count <= 200 }
    }
}

struct CaptureGap: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    let startedAt: Date
    let endedAt: Date
    let reason: String
}

enum TranscriptionConnectionState: String, Sendable {
    case unchecked, connecting, connected, offline, actionRequired
    var title: String {
        switch self {
        case .unchecked: "Inte kontrollerad"
        case .connecting: "Ansluter"
        case .connected: "Ansluten"
        case .offline: "Offline"
        case .actionRequired: "Åtgärd krävs"
        }
    }
}

struct TranscriptionHealth: Decodable, Sendable {
    let apiVersion: Int
    let serverVersion: String
    let status: String
    let metadata: TranscriptionMetadata
    let sampleRate: Int
    let channels: Int
    let encoding: String
    let maxSeconds: Int
    let maxBytes: Int

    /// Pause-cut chunks reach 1 + 22 + 1 s, exactly API v1's 24 s / 768,044-byte limit.
    static let requiredSeconds = 24
    static let requiredBytes = 768_044

    func validate() throws {
        guard apiVersion == 1, status == "ready", metadata.isValid,
              serverVersion.utf8.count <= 100, sampleRate == 16_000, channels == 1,
              encoding == "pcm_s16le_wav", maxSeconds >= Self.requiredSeconds, maxBytes >= Self.requiredBytes
        else { throw TranscriptionError.incompatible }
    }
}

struct TranscriptionWord: Codable, Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
    /// Additive in API v1: a session-local speaker number 1–4, never an identity.
    var speaker: Int? = nil

    private enum CodingKeys: String, CodingKey { case text, start, end, speaker }
}

extension TranscriptionWord {
    /// Declared in an extension so the memberwise initializer remains available.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        // Speaker labels are optional evidence: absent, null, malformed or out-of-range
        // values become nil and never reject an otherwise valid transcript.
        let decoded: Int? = try? values.decodeIfPresent(Int.self, forKey: .speaker)
        speaker = decoded.flatMap { MioSpeakerLabel.range.contains($0) ? $0 : nil }
    }

    /// Consecutive words of one speaker. Unlabelled words stay in the current turn, so a
    /// reply without speaker labels yields exactly one run, as before.
    static func speakerRuns(_ words: [TranscriptionWord]) -> [MioSpeakerRun] {
        var runs: [MioSpeakerRun] = []
        for word in words {
            if let last = runs.indices.last,
               word.speaker == nil || runs[last].speaker == nil || runs[last].speaker == word.speaker {
                runs[last].words.append(word)
                if runs[last].speaker == nil { runs[last].speaker = word.speaker }
            } else {
                runs.append(MioSpeakerRun(speaker: word.speaker, words: [word]))
            }
        }
        return runs
    }
}

struct MioSpeakerRun: Hashable, Sendable {
    var speaker: Int?
    var words: [TranscriptionWord]
}

struct TranscriptionReply: Decodable, Sendable {
    let apiVersion: Int
    let sessionID: UUID
    let chunkID: UUID
    let sequence: Int
    let startSample: Int64
    let words: [TranscriptionWord]
    let metadata: TranscriptionMetadata

    func validatedWords(for chunk: AudioChunk) throws -> [TranscriptionWord] {
        guard apiVersion == 1, sessionID == chunk.sessionID, chunkID == chunk.id,
              sequence == chunk.sequence, startSample == chunk.startSample,
              metadata.isValid, words.count <= 1_500 else { throw TranscriptionError.invalidResponse }
        var previous = 0.0
        for word in words {
            guard word.start.isFinite, word.end.isFinite,
                  word.start >= previous, word.end >= word.start,
                  word.end <= Double(chunk.pcm.count / 2) / 16_000 + 0.02,
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.text.utf8.count <= 400 else { throw TranscriptionError.invalidResponse }
            previous = word.start
        }
        return words.filter {
            let midpoint = ($0.start + $0.end) * 8_000
            return midpoint >= Double(chunk.coreStart) && midpoint < Double(chunk.coreEnd)
        }
    }
}

struct CaptureStartDetails: Sendable { let health: TranscriptionHealth }

enum AudioTimingValidity: String, Codable, Hashable, Sendable {
    case hostTime, sampleTime, estimated
    var isReliable: Bool { self != .estimated }
}

/// Native capture facts. Callback arrival alone never establishes an audio-time anchor.
struct AudioCaptureStamp: Sendable {
    let epoch: UUID
    let sequence: UInt64
    let hostUptime: TimeInterval?
    let sampleTime: Int64?
    let sampleRate: Double
    let frames: Int
    let callbackUptime: TimeInterval
    var channels: Int = 1
    var format: UInt = 0
}

struct ResolvedAudioTiming: Sendable {
    let uptime: TimeInterval
    let validity: AudioTimingValidity
    let missingDuration: TimeInterval
    let discontinuity: Bool
    let droppedBuffers: Int
}

struct AudioCaptureTimeline: Sendable {
    private var previous: AudioCaptureStamp?
    private var previousTime: TimeInterval?
    private var anchorSample: Int64?
    private var anchorUptime: TimeInterval?

    mutating func reset() {
        previous = nil; previousTime = nil; anchorSample = nil; anchorUptime = nil
    }

    mutating func resolve(_ stamp: AudioCaptureStamp) -> ResolvedAudioTiming {
        let compatible = previous?.epoch == stamp.epoch && previous?.sampleRate == stamp.sampleRate
            && previous?.channels == stamp.channels && previous?.format == stamp.format
        if !compatible { anchorSample = nil; anchorUptime = nil }
        let duration = Double(stamp.frames) / stamp.sampleRate
        let validHost = stamp.hostUptime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let dropped = compatible && stamp.sequence > (previous?.sequence ?? 0)
            ? Int(min(stamp.sequence - (previous?.sequence ?? 0) - 1, UInt64(Int.max))) : 0
        var missing = 0.0
        var discontinuity = previous != nil && !compatible
        var sampleDelta: Double?
        if compatible, let previous, let old = previous.sampleTime, let current = stamp.sampleTime {
            sampleDelta = Double(current) - Double(old) - Double(previous.frames)
            if let delta = sampleDelta, delta != 0 {
                discontinuity = true
                missing = max(0, delta / stamp.sampleRate)
                if delta < 0 { anchorSample = nil; anchorUptime = nil }
            }
        } else if dropped > 0, let previous {
            discontinuity = true
            missing = Double(dropped) * Double(previous.frames) / previous.sampleRate
        }
        // A paired host/sample anchor remains valid when later taps carry sample time only.
        if let host = validHost, let sample = stamp.sampleTime, anchorUptime == nil {
            anchorUptime = host; anchorSample = sample
        }
        var validity: AudioTimingValidity = .estimated
        var time = max(0, stamp.callbackUptime - duration)
        if let sample = stamp.sampleTime, let anchorSample, let anchorUptime {
            time = anchorUptime + (Double(sample) - Double(anchorSample)) / stamp.sampleRate
            validity = validHost == nil ? .sampleTime : .hostTime
        } else if let host = validHost {
            time = host; validity = .hostTime
            // Contiguous delivery/sample facts distinguish small host-clock jitter from lost frames.
            if compatible, dropped == 0, sampleDelta == nil, let previous, let previousTime,
               abs(host - previousTime - Double(previous.frames) / previous.sampleRate) < 0.25 {
                time = previousTime + Double(previous.frames) / previous.sampleRate
            }
        } else if compatible, !discontinuity, let previous, let previousTime {
            time = previousTime + Double(previous.frames) / previous.sampleRate
            validity = .estimated
            // No sample time means the continuation is estimated even after an old valid host tap.
            if stamp.sampleTime == nil { validity = .estimated }
        }
        if dropped > 0 { discontinuity = true }
        previous = stamp; previousTime = time
        return .init(uptime: time, validity: validity, missingDuration: missing,
                     discontinuity: discontinuity, droppedBuffers: dropped)
    }
}

struct STTDiagnostic: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case capture, conversion, droppedBuffer, retry, expired, result, failure }
    let kind: Kind
    var chunkID: UUID? = nil
    var sequence: Int? = nil
    var sampleRate: Double? = nil
    var channels: Int? = nil
    var frames: Int? = nil
    var duration: Double? = nil
    var timingValidity: AudioTimingValidity? = nil
    var count: Int? = nil
    var category: String? = nil

    var isValid: Bool {
        (sequence == nil || (0...1_000_000_000).contains(sequence!))
            && (sampleRate == nil || (sampleRate!.isFinite && (8_000...192_000).contains(sampleRate!)))
            && (channels == nil || (1...32).contains(channels!))
            && (frames == nil || (0...20_000_000).contains(frames!))
            && (duration == nil || (duration!.isFinite && (0...86_400).contains(duration!)))
            && (count == nil || (0...1_000_000).contains(count!))
            && (category == nil || ["tap_buffering_newest", "stream_drop", "audio_expired", "audio_conversion",
                "transport_retry", "response_rejected"].contains(category!))
    }
}

struct AudioPipelineClock: Sendable {
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var date: @Sendable () -> Date = { .now }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(max(0, seconds)))
    }
}

struct AudioChunk: Sendable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let sequence: Int
    let startSample: Int64
    let origin: Date
    let capturedUptime: TimeInterval
    let coreStart: Int
    let coreEnd: Int
    let pcm: Data
    var timingValidity: AudioTimingValidity = .hostTime
    var captureEpoch: UUID = UUID()

    var startedAt: Date { origin.addingTimeInterval(Double(coreStart) / 16_000) }
    var endedAt: Date { origin.addingTimeInterval(Double(coreEnd) / 16_000) }
    var expiresAt: TimeInterval { capturedUptime + 60 }

    var wave: Data {
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

/// Pause-cut cores of 8–22 s with one second of context on each available side. Origin is
/// captured once per audio epoch; a real capture gap starts another epoch, so missing audio
/// is never compressed out of time. At most 23 s plus one tap is retained between cuts.
struct AudioChunkAssembler: Sendable {
    private var bytes = Data()
    /// Mean-square energy per 20 ms frame of `bytes`; the buffer start stays frame-aligned
    /// because every cut lands on a frame and the kept context is 50 frames.
    private var energies: [Double] = []
    private let detector: SpeechPauseDetector
    private var offset: Int64 = 0
    private var coreStart = 0
    private var origin: Date?
    private var uptime: TimeInterval = 0
    private var validity: AudioTimingValidity = .hostTime
    private var epoch = UUID()
    private(set) var sequence = 0
    let sessionID: UUID

    init(sessionID: UUID, detector: SpeechPauseDetector = SpeechPauseDetector()) {
        self.sessionID = sessionID; self.detector = detector
    }

    var expiresAt: TimeInterval? { bytes.isEmpty ? nil : uptime + 60 }
    var retainedSamples: Int { bytes.count / 2 }
    var retainedGap: CaptureGap? {
        guard let origin, bytes.count / 2 > coreStart else { return nil }
        return CaptureGap(startedAt: origin.addingTimeInterval(Double(coreStart) / 16_000),
                          endedAt: origin.addingTimeInterval(Double(bytes.count / 2) / 16_000),
                          reason: "Ljudets 60 sekunder i minnet löpte ut.")
    }
    mutating func discard() { reset() }

    mutating func append(_ pcm: Data, at date: Date, uptime: TimeInterval,
                         timingValidity: AudioTimingValidity = .hostTime, captureEpoch: UUID? = nil) -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        if origin != nil, (!bytes.isEmpty),
           (abs(uptime - self.uptime - Double(bytes.count / 2) / 16_000) > 1.0 / 16_000
            || timingValidity != validity || (captureEpoch != nil && captureEpoch != epoch)) {
            if let tail = finish() { chunks.append(tail) }
        }
        if origin == nil {
            origin = date; self.uptime = uptime; validity = timingValidity
            if let captureEpoch { epoch = captureEpoch }
        }
        bytes.append(pcm)
        energies += SpeechPauseDetector.frameEnergies(bytes, from: energies.count)
        let frame = SpeechPauseDetector.frameSamples
        while let end = detector.coreEnd(energies: energies, coreStart: coreStart / frame) {
            chunks.append(take(coreEnd: end * frame, end: end * frame + 16_000))
        }
        return chunks
    }

    mutating func finish() -> AudioChunk? {
        guard bytes.count / 2 > coreStart else { reset(); return nil }
        let chunk = take(coreEnd: bytes.count / 2, end: bytes.count / 2)
        reset()
        return chunk
    }

    private mutating func take(coreEnd: Int, end: Int) -> AudioChunk {
        let chunk = AudioChunk(id: UUID(), sessionID: sessionID, sequence: sequence,
                               startSample: offset, origin: origin!, capturedUptime: uptime,
                               coreStart: coreStart, coreEnd: coreEnd, pcm: Data(bytes.prefix(end * 2)),
                               timingValidity: validity, captureEpoch: epoch)
        sequence += 1
        let discard = max(0, coreEnd - 16_000)
        bytes.removeFirst(discard * 2)
        energies.removeFirst(min(energies.count, discard / SpeechPauseDetector.frameSamples))
        offset += Int64(discard)
        origin = origin?.addingTimeInterval(Double(discard) / 16_000)
        uptime += Double(discard) / 16_000
        coreStart = coreEnd - discard
        return chunk
    }

    private mutating func reset() {
        offset += Int64(bytes.count / 2)
        bytes.removeAll(keepingCapacity: false); energies.removeAll(); coreStart = 0; origin = nil
        // Sequence remains unique across interruptions in this pipeline.
    }
}

enum TranscriptionError: LocalizedError, Sendable {
    case notConfigured, invalidAddress, invalidToken, keychain, incompatible, invalidResponse
    case http(Int, retryAfter: Double)
    var retryDelay: Double? {
        if case let .http(status, retryAfter) = self, [408, 429, 500, 502, 503, 504].contains(status) {
            return min(30, max(1, retryAfter))
        }
        return nil
    }
    var errorDescription: String? {
        switch self {
        case .notConfigured: "Konfigurera transkriptionsservern i Inställningar först."
        case .invalidAddress: "Ange serverns privata HTTPS-adress som slutar med .ts.net, utan sökväg."
        case .invalidToken: "Ange en åtkomsttoken med 32–256 bokstäver, siffror, bindestreck eller understreck."
        case .keychain: "Åtkomsttoken kunde inte läsas eller sparas säkert. Lås upp telefonen och försök igen."
        case .incompatible: "Serverns API eller ljudformat är inte kompatibelt med denna Mio-version."
        case .invalidResponse: "Servern lämnade ett ogiltigt transkript. Sessionen har pausats."
        case let .http(status, _):
            switch status {
            case 401, 403: "Servern nekade åtkomst. Kontrollera token och Tailscale-behörighet i Inställningar."
            case 429: "Servern är upptagen. Mio försöker igen."
            case 503: "Transkriptionsmodellen är inte redo. Mio försöker igen."
            default: "Transkriptionsservern svarade med HTTP \(status)."
            }
        }
    }
}
