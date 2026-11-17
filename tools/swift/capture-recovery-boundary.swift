import Foundation

struct AudioCaptureStamp: Sendable { }
protocol AudioCapturing: AnyObject, Sendable {
    func start() async throws
    func stop() async
    var lastBufferUptime: TimeInterval { get }
    var droppedBufferCount: Int { get }
    func checkAfterForeground()
}
enum PipelineEvent: Sendable {
    case interruptionBegan, interruptionEnded(shouldResume: Bool), mediaServicesReset
    case needsResume(String), routeChanged(String), restartFailed(String)
}
struct AVAudioFormat { var channelCount: UInt32 = 1 }
final class AVAudioPCMBuffer { let format = AVAudioFormat() }
struct RefusedStart: Error { }
final class AVAudioEngine: @unchecked Sendable {
    nonisolated(unsafe) static var latest: AVAudioEngine?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var refusing = false
    static var startCount: Int { lock.withLock { starts } }
    static func resetCounts() { lock.withLock { starts = 0; refusing = false } }
    /// Models iOS refusing to activate recording, as it can in the background.
    static func refuseStarts(_ value: Bool) { lock.withLock { refusing = value } }
    var isRunning = false
    init() { Self.latest = self }
    func start() throws {
        let refused = Self.lock.withLock { () -> Bool in
            if Self.refusing { return true }
            Self.starts += 1
            return false
        }
        if refused { throw RefusedStart() }
        isRunning = true
    }
    func stop() { isRunning = false }
}
final class AVAudioSession {
    static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    struct SetActiveOptions: OptionSet {
        let rawValue: UInt
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    struct InterruptionOptions: OptionSet {
        let rawValue: UInt
        static let shouldResume = Self(rawValue: 1)
    }
    enum InterruptionType: UInt { case began = 1, ended = 0 }
    enum RouteChangeReason: UInt { case newDeviceAvailable = 1, categoryChange = 3 }
    static let interruptionNotification = Notification.Name("interruption")
    static let routeChangeNotification = Notification.Name("route")
    static let mediaServicesWereLostNotification = Notification.Name("lost")
    static let mediaServicesWereResetNotification = Notification.Name("reset")
    func setActive(_ active: Bool, options: SetActiveOptions) throws { }
}
let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "reason"
extension Notification.Name {
    static let AVAudioEngineConfigurationChange = Notification.Name("configuration")
}
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []
    func receive(_ event: PipelineEvent) { lock.withLock { events.append(event) } }
    var requestsContinuation: Bool {
        lock.withLock { events.contains { if case .needsResume = $0 { return true }; return false } }
    }
    var reportsRefusal: Bool {
        lock.withLock { events.contains { if case .restartFailed = $0 { return true }; return false } }
    }
    var reportsResume: Bool {
        lock.withLock { events.contains { if case .interruptionEnded(shouldResume: true) = $0 { return true }; return false } }
    }
}
