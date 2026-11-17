// Linux substitutes for Apple-only boundaries; all application/session logic is real.
struct TranscriptionConnection: Sendable { }
@MainActor enum TranscriptionSettings {
    static func connection() throws -> TranscriptionConnection { throw TranscriptionError.notConfigured }
}
final class TranscriptionClient: TranscriptionTransport, @unchecked Sendable {
    init(connection: TranscriptionConnection) { }
    func cancel() { }
    func startTranscription(_ chunk: AudioChunk) -> Task<TranscriptionReply, Error> { Task { throw TranscriptionError.notConfigured } }
    func health() async throws -> TranscriptionHealth { throw TranscriptionError.notConfigured }
}
@MainActor enum SpeechCapabilityService {
    static var microphonePermission: MicrophonePermission { .notDetermined }
}
struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: -1)
}
@MainActor final class UIApplication {
    enum State { case active, background, inactive }
    static let shared = UIApplication()
    static let openSettingsURLString = "app-settings:"
    var applicationState: State = .active
    func beginBackgroundTask(withName: String, expirationHandler: () -> Void) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) { }
    func open(_ url: URL) { }
}
@MainActor final class UIDevice: NSObject {
    enum BatteryState { case unknown, unplugged, charging, full }
    static let current = UIDevice()
    static let batteryLevelDidChangeNotification = Notification.Name("batteryLevel")
    static let batteryStateDidChangeNotification = Notification.Name("batteryState")
    var isBatteryMonitoringEnabled = false
    var batteryLevel: Float = -1
    var batteryState: BatteryState = .unknown
    var systemVersion = "portable-boundary"
}
enum ScenePhase { case active, inactive, background }
@MainActor enum MioFeedback { static func success() { } }
struct CapturedPCMBuffer: Sendable {
    let buffer: Data
    let stamp: AudioCaptureStamp
    var channelCount: Int { 1 }
}
final class BufferConverter {
    func reset() {}
    func transcriptionPCM(_ buffer: Data) throws -> Data { buffer }
    func finishTranscriptionPCM() throws -> Data { Data() }
}

final class UnavailableAudioCapture: AudioCapturing, @unchecked Sendable {
    var lastBufferUptime: TimeInterval { 0 }
    func start() async throws { throw TranscriptionError.notConfigured }
    func stop() async { }
    func checkAfterForeground() { }
}
extension LiveTranscriptionPipeline {
    init(connection: TranscriptionConnection, sessionID: UUID, handlers: Handlers) {
        self.init(sessionID: sessionID, handlers: handlers, transport: TranscriptionClient(connection: connection),
            captureFactory: { _, _ in UnavailableAudioCapture() }, permission: { false })
    }
}
