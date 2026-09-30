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

    func validate() throws {
        guard apiVersion == 1, status == "ready", metadata.isValid,
              serverVersion.utf8.count <= 100, sampleRate == 16_000, channels == 1,
              encoding == "pcm_s16le_wav", maxSeconds >= 22, maxBytes >= 704_044
        else { throw TranscriptionError.incompatible }
    }
}

struct TranscriptionWord: Codable, Hashable, Sendable {
    let text: String
    let start: Double
    let end: Double
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

/// Twenty-second cores with one second of context. Origin is captured once per audio epoch;
/// a real capture gap starts another epoch, so missing audio is never compressed out of time.
struct AudioChunkAssembler: Sendable {
    private var bytes = Data()
    private var offset: Int64 = 0
    private var coreStart = 0
    private var origin: Date?
    private var uptime: TimeInterval = 0
    private(set) var sequence = 0
    let sessionID: UUID

    mutating func append(_ pcm: Data, at date: Date, uptime: TimeInterval) -> [AudioChunk] {
        if origin == nil { origin = date; self.uptime = uptime }
        bytes.append(pcm)
        var chunks: [AudioChunk] = []
        while bytes.count / 2 >= coreStart + 21 * 16_000 {
            chunks.append(take(coreEnd: coreStart + 20 * 16_000, end: coreStart + 21 * 16_000))
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
                               coreStart: coreStart, coreEnd: coreEnd, pcm: Data(bytes.prefix(end * 2)))
        sequence += 1
        let discard = max(0, coreEnd - 16_000)
        bytes.removeFirst(discard * 2)
        offset += Int64(discard)
        origin = origin?.addingTimeInterval(Double(discard) / 16_000)
        uptime += Double(discard) / 16_000
        coreStart = coreEnd - discard
        return chunk
    }

    private mutating func reset() {
        offset += Int64(bytes.count / 2)
        bytes.removeAll(keepingCapacity: false); coreStart = 0; origin = nil
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
