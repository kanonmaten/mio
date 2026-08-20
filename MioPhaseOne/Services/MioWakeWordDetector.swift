import Foundation

enum MioWakeWordDetector {
    static func containsWakeWord(in text: String) -> Bool {
        let normalized = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "sv-SE"))
            .lowercased(with: Locale(identifier: "sv-SE"))

        let words = normalized.split { character in
            !character.isLetter && !character.isNumber
        }

        return words.contains { $0 == "mio" }
    }
}
