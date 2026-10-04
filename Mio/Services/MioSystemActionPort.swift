import Foundation

/// Cancellation never asks for permission or recreates an action during recovery.
@MainActor
struct MioSystemActionPort {
    var cancel: @MainActor (UUID) async -> MioOperationOutcome
    var removeAll: @MainActor () async -> MioOperationOutcome

    static var native: Self {
        #if canImport(AlarmKit)
        Self(cancel: { id in
            await MioSystemServices.shared.cancelActions(for: id) ? .success
                : .failure(MioSystemServices.shared.errorMessage ?? "Kunde inte avbryta postens systemåtgärder. Försök igen.")
        }, removeAll: {
            await MioSystemServices.shared.removeAll() ? .success
                : .failure(MioSystemServices.shared.errorMessage ?? "Kunde inte avbryta Mios systemåtgärder. Kontrollera behörigheten och försök igen.")
        })
        #else
        Self(cancel: { _ in .failure("Systemåtgärder är inte tillgängliga på denna plattform.") },
             removeAll: { .failure("Systemåtgärder är inte tillgängliga på denna plattform.") })
        #endif
    }
}
