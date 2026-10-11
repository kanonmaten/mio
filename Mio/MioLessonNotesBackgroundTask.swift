import BackgroundTasks
import Foundation
import os

/// Presents detailed lesson-note generation as an iOS 26 continued-processing task, so iOS
/// shows its own progress and keeps Mio running after the user leaves the app.
/// The parts are produced by MioAnalysisCoordinator whether or not iOS starts the task;
/// the task only mirrors progress and stops that work when iOS or the user ends it.
/// Unfinished parts stay listed in the workflow and are resumed on the next launch.
@MainActor
final class MioLessonNotesBackgroundTask {
    /// Matches the wildcard `app.mio.assistant.lesson-notes.*` in BGTaskSchedulerPermittedIdentifiers.
    static let identifierPrefix = "app.mio.assistant.lesson-notes."
    private static let pollInterval: Duration = .seconds(3)

    private struct Running {
        let task: BGContinuedProcessingTask
        let monitor: Task<Void, Never>
    }

    private let capture: MioViewModel
    private let analysis: MioAnalysisCoordinator
    private let assistant: MioAssistantViewModel
    private var running: [UUID: Running] = [:]
    private let logger = Logger(subsystem: "app.mio.assistant", category: "lesson-notes")

    init(capture: MioViewModel, analysis: MioAnalysisCoordinator, assistant: MioAssistantViewModel) {
        self.capture = capture
        self.analysis = analysis
        self.assistant = assistant
    }

    /// Call right after the user's own action (ending a lesson or continuing its notes);
    /// iOS accepts the request only while Mio is in the foreground.
    func begin(sessionID: UUID) {
        guard running[sessionID] == nil, analysis.hasPendingLessonNotes(sessionID: sessionID) else { return }
        // Each submission needs its own identifier; registering one twice raises an exception.
        let identifier = Self.identifierPrefix + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continued = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(continued, sessionID: sessionID)
            }
        }
        guard registered else {
            logger.error("Continued processing handler was not registered")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Mio skriver lektionsanteckningar",
                                                       subtitle: progress(for: sessionID).subtitle)
        // A queued start could begin long after the user left; without iOS's task the
        // notes still continue while Mio stays open.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Continued processing request failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func run(_ task: BGContinuedProcessingTask, sessionID: UUID) {
        guard running[sessionID] == nil else {
            // A duplicate submission for notes that already report progress elsewhere.
            task.setTaskCompleted(success: true)
            return
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.expire(sessionID: sessionID) }
        }
        let monitor = Task { [weak self] in
            var lastSubtitle = ""
            while !Task.isCancelled {
                guard let self else { return }
                let progress = self.progress(for: sessionID)
                task.progress.totalUnitCount = Int64(max(1, progress.total))
                task.progress.completedUnitCount = Int64(progress.completed)
                if progress.subtitle != lastSubtitle {
                    lastSubtitle = progress.subtitle
                    task.updateTitle(task.title, subtitle: progress.subtitle)
                }
                switch progress.step(hasPendingWork: self.analysis.hasPendingLessonNotes(sessionID: sessionID)) {
                case .running:
                    try? await Task.sleep(for: Self.pollInterval)
                case .finished:
                    self.finish(sessionID: sessionID, success: true)
                    return
                case .stopped:
                    self.finish(sessionID: sessionID, success: false)
                    return
                }
            }
        }
        running[sessionID] = Running(task: task, monitor: monitor)
    }

    /// iOS or the user ended the task: stop sending further parts now. Saved parts stay,
    /// and the workflow resumes the rest on the next launch or when the user continues.
    private func expire(sessionID: UUID) {
        guard running[sessionID] != nil else { return }
        analysis.stopLessonNotes(sessionID: sessionID, assistant: assistant)
        finish(sessionID: sessionID, success: false)
    }

    private func finish(sessionID: UUID, success: Bool) {
        guard let entry = running.removeValue(forKey: sessionID) else { return }
        entry.monitor.cancel()
        entry.task.setTaskCompleted(success: success)
    }

    private func progress(for sessionID: UUID) -> MioLessonNotesProgress {
        guard let session = capture.session(id: sessionID) else { return MioLessonNotesProgress(completed: 0, total: 0) }
        return MioLessonNotesProgress(document: MioLessonDocument(session: session, records: assistant.analyses))
    }
}
