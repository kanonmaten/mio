import Foundation

/// Marks a segment as direct address. Since 2026-11-20 only "Mio, kom ihåg" and "Mio, notera"
/// at the start of a sentence count; a lone "Mio" is just a word in the conversation.
enum MioWakeWordDetector {
    static func containsWakeWord(in text: String) -> Bool {
        MioDirectCommandGrammar.containsWakePhrase(text)
    }
}
