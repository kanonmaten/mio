import Foundation

enum MioAppTab: String, Hashable, Sendable {
    case capture, lessons, calendar, notes, daily
}

enum MioDailyPeriod: String, Hashable, Sendable {
    case morning, evening
}

/// Notification payloads contain routing names and an opaque local identity only.
enum MioNotificationRoute: Equatable, Sendable {
    case post(UUID)
    case morning
    case evening

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
        default: return nil
        }
    }

    var userInfo: [String: String] {
        switch self {
        case .post(let id): ["mioRoute": "post", "mioPostID": id.uuidString]
        case .morning: ["mioRoute": "morning"]
        case .evening: ["mioRoute": "evening"]
        }
    }

    var notificationBody: String {
        switch self {
        case .post: "Du har en påminnelse i Mio. Öppna appen för att se din post."
        case .morning: "Din morgonöversikt finns i Mio. Öppna appen när det passar."
        case .evening: "Din kvällsöversikt finns i Mio. Öppna appen när det passar."
        }
    }
}

struct MioPresentedPost: Identifiable, Equatable, Sendable {
    let id: UUID
}
