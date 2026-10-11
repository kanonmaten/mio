import Foundation

/// Up to three ready-made questions for Fråga Mio, built on the phone from post and lesson
/// titles. Tapping one only fills the text field; nothing is sent until the user taps Skicka.
enum MioSuggestedQuestions {
    static func make(content: [MioContentItem], lessonTitles: [String], now: Date, calendar: Calendar) -> [String] {
        var questions: [String] = []
        if let lesson = lessonTitles.lazy.map(clean).first(where: { !$0.isEmpty }) {
            questions.append("Förklara det viktigaste från \(lesson) enkelt.")
        }
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start
        let upcoming = content
            .filter { ($0.kind == .plan || ($0.kind == .task && !$0.isCompleted)) && $0.scheduledAt >= now && $0.scheduledAt < end }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        if let next = upcoming.first {
            let title = clean(next.title)
            questions.append(next.kind == .task ? "Hjälp mig dela upp \(title) i små steg." : "Hur förbereder jag mig för \(title)?")
        }
        questions.append("Hjälp mig planera kvällen i små steg.")
        return Array(questions.prefix(3))
    }

    /// One line, at most 60 characters, so a long title cannot crowd the field.
    private static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
