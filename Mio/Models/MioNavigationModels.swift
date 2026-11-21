import Foundation

/// Four sections plus the separate capture (mic) tab. Morgon and Kväll live on Hem.
enum MioAppTab: String, Hashable, Sendable {
    // 0.9.1: Kalender and Anteckningar gave way to Förslag; Apple's apps own the items.
    case home, lessons, proposals, capture
}

enum MioDailyPeriod: String, Hashable, Sendable {
    case morning, evening
}

/// Notification payloads contain routing names and an opaque local identity only.
enum MioNotificationRoute: Equatable, Sendable {
    case post(UUID)
    case morning
    case evening
    /// Fallback when iOS refused to restart the microphone in the background. Opening the
    /// app is what resumes listening; the route itself only selects the capture tab.
    case resumeListening
    /// "Lyssnar Mio fortfarande?" after 20 minutes without speech. Ja keeps listening without
    /// restarting the microphone; opening the notification also counts as Ja and shows Fånga.
    case stillListening
    /// "Anteckningarna från lektionen är klara" (fas 3): opens the lesson's review sheet. Carries
    /// only the session's opaque local UUID; the lock-screen text never names the lesson.
    case lessonReview(UUID)

    init?(userInfo: [AnyHashable: Any]) {
        guard let name = userInfo["mioRoute"] as? String else { return nil }
        switch name {
        case "post":
            guard userInfo.count == 2, let value = userInfo["mioPostID"] as? String,
                  value.utf8.count == 36, let id = UUID(uuidString: value) else { return nil }
            self = .post(id)
        case "morning":
            guard userInfo.count == 1 else { return nil }
            self = .morning
        case "evening":
            guard userInfo.count == 1 else { return nil }
            self = .evening
        case "resumeListening":
            guard userInfo.count == 1 else { return nil }
            self = .resumeListening
        case "stillListening":
            guard userInfo.count == 1 else { return nil }
            self = .stillListening
        case "lessonReview":
            guard userInfo.count == 2, let value = userInfo["mioSessionID"] as? String,
                  value.utf8.count == 36, let id = UUID(uuidString: value) else { return nil }
            self = .lessonReview(id)
        default: return nil
        }
    }

    var userInfo: [String: String] {
        switch self {
        case .post(let id): ["mioRoute": "post", "mioPostID": id.uuidString]
        case .morning: ["mioRoute": "morning"]
        case .evening: ["mioRoute": "evening"]
        case .resumeListening: ["mioRoute": "resumeListening"]
        case .stillListening: ["mioRoute": "stillListening"]
        case .lessonReview(let id): ["mioRoute": "lessonReview", "mioSessionID": id.uuidString]
        }
    }

    var notificationBody: String {
        switch self {
        case .post: "Du har en påminnelse i Mio. Öppna appen för att se din post."
        case .morning: "Din morgonöversikt finns i Mio. Öppna appen när det passar."
        case .evening: "Din kvällsöversikt finns i Mio. Öppna appen när det passar."
        case .resumeListening: "Tryck för att fortsätta lyssna."
        case .stillListening: "Inget tal på 20 minuter. Svara Ja för att fortsätta lyssna. Annars pausar Mio om fem minuter."
        case .lessonReview: "Anteckningarna från lektionen är klara."
        }
    }
}

struct MioPresentedPost: Identifiable, Equatable, Sendable {
    let id: UUID
}
