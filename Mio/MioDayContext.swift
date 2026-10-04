import Foundation
import Observation

/// Calendar notifications can be delayed while asleep. Foreground refresh is also
/// required, and an explicitly selected historical day must stay selected.
@MainActor @Observable
final class MioDayContext {
    private(set) var selectedDate: Date
    private(set) var referenceDate: Date
    private(set) var calendar: Calendar
    private(set) var followsToday = true
    private(set) var revision: UInt64 = 0

    init(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        selectedDate = now
        referenceDate = now
        self.calendar = calendar
    }

    var startOfToday: Date { calendar.startOfDay(for: referenceDate) }
    var overviewDate: Date {
        // An autoupdating calendar can change without a different stored value.
        // Views of a historical date must still observe an explicit refresh.
        _ = revision
        return selectedDate
    }

    func select(_ date: Date) {
        selectedDate = date
        followsToday = calendar.isDate(date, inSameDayAs: referenceDate)
    }

    func refresh(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        referenceDate = now
        self.calendar = calendar
        if followsToday { selectedDate = now }
        revision &+= 1
    }
}
