import Foundation

/// Own words from the phone (plan phase 4, contract "Egna ord från telefonen"). When she corrects
/// a word or a short phrase in an ended session, Mio may ask whether it should become an own word
/// in Pianissimo's word list on the PC. The word goes only to Pianissimo over Tailscale, never to
/// the gateway or an AI provider, is never logged or kept in diagnostics, and a failure never
/// affects transcription.
enum MioVocabulary {
    static let maximumBytes = 100

    /// The word or short phrase the correction put in, when the correction replaces exactly one
    /// run of words with another. Nil for a deletion, a pure change of case or punctuation, a
    /// longer rewrite or anything the server would refuse.
    static func candidate(original: String, correction: String) -> String? {
        let before = words(original), after = words(correction)
        guard !after.isEmpty, before != after else { return nil }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let replaced = Array(before[prefix..<(before.count - suffix)])
        let inserted = Array(after[prefix..<(after.count - suffix)])
        guard !inserted.isEmpty, !replaced.isEmpty else { return nil }
        let phrase = inserted.map(trimmedPunctuation).filter { !$0.isEmpty }.joined(separator: " ")
        // Only case or punctuation changed: nothing new for the decoder to learn.
        guard normalized(phrase) != normalized(replaced.map(trimmedPunctuation).joined(separator: " ")) else { return nil }
        return validPhrase(phrase)
    }

    /// The server's rule: trimmed, 1–100 bytes UTF-8, one line without control characters, not a comment.
    static func validPhrase(_ value: String) -> String? {
        let phrase = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maximumBytes).contains(phrase.utf8.count), !phrase.hasPrefix("#"),
              !phrase.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        else { return nil }
        return phrase
    }

    static func requestBody(_ phrase: String) throws -> Data {
        guard let phrase = validPhrase(phrase) else { throw MioVocabularyError.invalidPhrase }
        let data = try JSONEncoder().encode(["phrase": phrase])
        guard data.count <= 1_024 else { throw MioVocabularyError.invalidPhrase }
        return data
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "sv-SE"))
            .lowercased(with: Locale(identifier: "sv-SE"))
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func trimmedPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: "+#&")))
    }
}

/// Pianissimo's answer to `POST /v1/vocabulary`: `{"added": true, "vocabulary": 37}`.
struct MioVocabularyReply: Decodable, Equatable, Sendable {
    let added: Bool
    let vocabulary: Int

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4_096, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Superset: a newer Pianissimo may add fields; the word is already saved then.
              Set(object.keys).isSuperset(of: ["added", "vocabulary"]),
              let reply = try? JSONDecoder().decode(Self.self, from: data), (0...500).contains(reply.vocabulary)
        else { throw MioVocabularyError.invalidResponse }
        return reply
    }
}

enum MioVocabularyError: LocalizedError, Equatable {
    case invalidPhrase, unauthorized, full, tooLarge, unavailable, storageFailed, invalidResponse, network

    /// HTTP status from Pianissimo (contract: 400 `invalid_phrase`, 401, 409 `vocabulary_full`, 413;
    /// the server also answers 415 `json_required`, 408 `body_timeout` and 507 `vocabulary_storage_failed`).
    static func http(_ status: Int) -> Self {
        switch status {
        case 400, 415: .invalidPhrase
        case 507: .storageFailed
        case 401, 403: .unauthorized
        case 409: .full
        case 413: .tooLarge
        case 404, 405: .unavailable
        default: .network
        }
    }

    /// One sentence; resending is always her own choice from the correction.
    var errorDescription: String? {
        switch self {
        case .invalidPhrase, .tooLarge: "Datorn tog inte emot ordet. Korta det eller ta bort tecken som # och radbrytningar."
        case .unauthorized: "Datorn godkände inte parningen. Para telefonen med datorn igen i Inställningar."
        case .full: "Ordlistan på datorn är full. Ta bort ord i Mio Kontroll och försök sedan igen."
        case .unavailable: "Datorns transkription tar inte emot egna ord ännu. Uppdatera Pianissimo på datorn."
        case .storageFailed: "Datorn kunde inte spara ordet. Kontrollera att datorns disk har plats och försök igen."
        case .invalidResponse, .network: "Ordet kom inte fram till datorn. Försök igen när datorn är nåbar."
        }
    }
}

/// Which corrections Mio has already asked about, so it never asks about the same word twice.
/// Holds 64-bit FNV-1a hashes of the normalized phrase, never the words themselves.
struct MioVocabularyAskedLog: Codable, Equatable, Sendable {
    static let key = "mio.vocabulary.asked.v1"
    static let maximumEntries = 1_000

    var hashes: [UInt64] = []

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: key), let log = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return log
    }

    static func hasAsked(_ phrase: String, in defaults: UserDefaults) -> Bool {
        load(from: defaults).hashes.contains(hash(phrase))
    }

    static func record(_ phrase: String, in defaults: UserDefaults) {
        var log = load(from: defaults)
        let value = hash(phrase)
        guard !log.hashes.contains(value) else { return }
        log.hashes.append(value)
        log.hashes = Array(log.hashes.suffix(maximumEntries))
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: key) }
    }

    static func reset(in defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    /// Stable across launches (Swift's `Hasher` is seeded per process).
    static func hash(_ phrase: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in MioVocabulary.normalized(phrase).utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        return value
    }
}

/// The question after a correction: "Ska ”X” bli ett eget ord?".
struct MioVocabularyOffer: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sessionID: UUID
    let segmentID: UUID
    let phrase: String
}
