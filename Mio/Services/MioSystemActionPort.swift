import Foundation

/// Cancellation never asks for permission or recreates an action during recovery.
@MainActor
struct MioSystemActionPort {
    var cancel: @MainActor (UUID) async -> MioOperationOutcome
    var removeAll: @MainActor () async -> MioOperationOutcome
    /// 0.9.1 upgrade: removes Mio's alarms and post reminders, keeping the daily notifications.
    var removeLegacy: @MainActor () async -> MioOperationOutcome = { .success }

    static var native: Self {
        #if canImport(AlarmKit)
        Self(cancel: { id in
            await MioSystemServices.shared.cancelActions(for: id) ? .success
                : .failure(MioSystemServices.shared.errorMessage ?? "Kunde inte avbryta postens systemåtgärder. Försök igen.")
        }, removeAll: {
            await MioSystemServices.shared.removeAll() ? .success
                : .failure(MioSystemServices.shared.errorMessage ?? "Kunde inte avbryta Mios systemåtgärder. Kontrollera behörigheten och försök igen.")
        }, removeLegacy: {
            await MioSystemServices.shared.removeLegacyActions() ? .success : .failure("Mios gamla alarm kunde inte tas bort än.")
        })
        #else
        Self(cancel: { _ in .failure("Systemåtgärder är inte tillgängliga på denna plattform.") },
             removeAll: { .failure("Systemåtgärder är inte tillgängliga på denna plattform.") })
        #endif
    }
}
