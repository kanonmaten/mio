import Foundation

/// Progress of detailed lesson notes, counted in text parts, for iOS's continued-processing UI.
struct MioLessonNotesProgress: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case running
        case finished
        /// Work stopped before all parts were done (AI off, failure or rate limit).
        case stopped
    }

    let completed: Int
    let total: Int

    init(completed: Int, total: Int) {
        self.total = max(0, total)
        self.completed = min(max(0, completed), self.total)
    }

    init(document: MioLessonDocument) {
        // Parts marked as unprocessed are finished work too; nothing more will be sent for them.
        self.init(completed: document.completedCount + document.unprocessedCount, total: document.fragments.count)
    }

    var isComplete: Bool { total > 0 && completed == total }
    var subtitle: String { "\(completed) av \(total) textdelar klara" }

    func step(hasPendingWork: Bool) -> Step {
        if isComplete { return .finished }
        return hasPendingWork ? .running : .stopped
    }
}
