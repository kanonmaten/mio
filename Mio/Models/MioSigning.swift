import Foundation

/// When SideStore's signature runs out (fas 6, user decision 2026-11-19). The expiry is read from
/// the app's own `embedded.mobileprovision`, a CMS-signed property list: the XML between `<plist`
/// and `</plist>` is parsed and the signature itself is not checked, since only the date is used.
/// A build without the file (the simulator, App Store) shows nothing. **Ej verifierat** with a
/// SideStore installation: SideStore may re-sign with its own profile, whose date is the one read.
enum MioSigning {
    /// Outside the "mio." prefix, so it is never listed among the daily notifications.
    static let reminderID = "app.mio.signing.renew"
    static let reminderLead: TimeInterval = 24 * 60 * 60
    static let reminderTitle = "Mio behöver förnyas i morgon"
    static let reminderBody = "1. Stäng av Tailscale. 2. Öppna SideStore och slå på LocalDevVPN. 3. Tryck Uppdatera vid Mio. 4. Stäng av LocalDevVPN och slå på Tailscale igen."

    static func expirationDate(fromProvisioningProfile data: Data) -> Date? {
        guard data.count <= 1_048_576,
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Whole days left, counted on the calendar; 0 on the day it runs out, negative after.
    static func daysLeft(until expiration: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiration)).day ?? 0
    }

    /// The settings line.
    static func text(expiration: Date, now: Date, calendar: Calendar = .current) -> String {
        guard expiration > now else { return "Har gått ut. Förnya Mio i SideStore." }
        switch daysLeft(until: expiration, now: now, calendar: calendar) {
        case ...0: return "Går ut i dag"
        case 1: return "1 dag kvar"
        case let days: return "\(days) dagar kvar"
        }
    }

    /// When the reminder fires: 24 hours before, or nil when that moment has passed.
    static func reminderDate(expiration: Date, now: Date) -> Date? {
        let date = expiration.addingTimeInterval(-reminderLead)
        return date > now ? date : nil
    }
}
