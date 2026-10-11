import Foundation
#if canImport(os)
import os
#endif

enum MioLogCategory: String, Sendable {
    case capture, transcription, ai, storage
}

/// Text-free unified logging. Messages are compile-time constants and the only runtime value
/// is an optional number, so no transcript, question, answer, title or secret can be logged.
enum MioLog {
    static let subsystem = "app.mio.assistant"

    static func notice(_ category: MioLogCategory, _ message: StaticString, value: Int? = nil) {
        #if canImport(os)
        let text = "\(message)"
        if let value {
            logger(category).notice("\(text, privacy: .public) \(value, privacy: .public)")
        } else {
            logger(category).notice("\(text, privacy: .public)")
        }
        #endif
    }

    static func error(_ category: MioLogCategory, _ message: StaticString, value: Int? = nil) {
        #if canImport(os)
        let text = "\(message)"
        if let value {
            logger(category).error("\(text, privacy: .public) \(value, privacy: .public)")
        } else {
            logger(category).error("\(text, privacy: .public)")
        }
        #endif
    }

    #if canImport(os)
    private static let capture = Logger(subsystem: subsystem, category: MioLogCategory.capture.rawValue)
    private static let transcription = Logger(subsystem: subsystem, category: MioLogCategory.transcription.rawValue)
    private static let ai = Logger(subsystem: subsystem, category: MioLogCategory.ai.rawValue)
    private static let storage = Logger(subsystem: subsystem, category: MioLogCategory.storage.rawValue)

    private static func logger(_ category: MioLogCategory) -> Logger {
        switch category {
        case .capture: capture
        case .transcription: transcription
        case .ai: ai
        case .storage: storage
        }
    }
    #endif
}
