import Foundation
import Observation

@MainActor @Observable
final class MioContentViewModel {
    private(set) var items: [MioContentItem] = []
    var errorMessage: String?
    var exportURL: URL?
    var isPreparingExport = false
    private(set) var stateRevision: UInt64 = 0

    @ObservationIgnored private let repository: any MioContentStore
    @ObservationIgnored private let diagnostics: MioDiagnosticsRepository
    @ObservationIgnored private let metrics: MioMetricArchive
    @ObservationIgnored private let systemActions: MioSystemActionPort
    @ObservationIgnored private var hasBootstrapped = false

    init(repository: any MioContentStore = MioContentRepository(), diagnostics: MioDiagnosticsRepository = .shared,
         systemActions: MioSystemActionPort? = nil, metrics: MioMetricArchive = .shared) {
        self.repository = repository; self.diagnostics = diagnostics; self.systemActions = systemActions ?? .native
        self.metrics = metrics
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        do { update(try await repository.loadItems()); hasBootstrapped = true }
        catch { errorMessage = "Kunde inte läsa lokalt innehåll: \(error.localizedDescription)" }
    }

    func latestItems() async throws -> [MioContentItem] { try await repository.loadItems() }

    @discardableResult
    func save(id: UUID? = nil, kind: MioContentKind, title: String, body: String,
              scheduledAt: Date, isCompleted: Bool, sessionID: UUID?) async -> Bool {
        await saveOutcome(id: id, kind: kind, title: title, body: body, scheduledAt: scheduledAt,
                          isCompleted: isCompleted, sessionID: sessionID).isSuccess
    }

    func saveOutcome(id: UUID? = nil, kind: MioContentKind, title: String, body: String,
                     scheduledAt: Date, isCompleted: Bool, sessionID: UUID?) async -> MioOperationOutcome {
        guard MioMaintenanceState.shared.beginWrite() else { return publish(.conflict("Vänta tills dataåtgärden är klar och försök igen.")) }
        defer { MioMaintenanceState.shared.endWrite() }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return publish(.failure("Skriv en rubrik innan du sparar.")) }
        do {
            try Task.checkCancellation()
            let existing = try await repository.loadItems().first { $0.id == id }
            if let existing, existing.kind == .task || existing.kind == .plan,
               (kind == .task && isCompleted) || (kind != .task && kind != .plan) {
                let cancelled = await systemActions.cancel(existing.id)
                guard cancelled.isSuccess else { return publish(cancelled) }
            }
            try Task.checkCancellation()
            let item = MioContentItem(id: existing?.id ?? id ?? UUID(), kind: kind, title: cleanTitle,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: existing?.createdAt ?? .now,
                updatedAt: .now, scheduledAt: scheduledAt,
                completedAt: kind == .task && isCompleted ? existing?.completedAt ?? .now : nil, sessionID: sessionID)
            update(try await repository.upsert(item))
            return publish(.success)
        } catch is CancellationError { return publish(.cancelled) }
        catch { return publish(.failure("Kunde inte spara innehållet: \(error.localizedDescription)")) }
    }

    func saveApproved(_ item: MioContentItem) async -> MioOperationOutcome {
        guard MioMaintenanceState.shared.beginWrite() else { return publish(.conflict("Vänta tills dataåtgärden är klar och granska igen.")) }
        defer { MioMaintenanceState.shared.endWrite() }
        do {
            try Task.checkCancellation()
            update(try await repository.saveApprovedIfAbsent(item))
            return publish(.success)
        } catch is CancellationError { return publish(.cancelled) }
        catch { return publish(.failure("Kunde inte spara den godkända posten: \(error.localizedDescription)")) }
    }

    func delete(id: UUID) async { _ = await deleteOutcome(id: id) }

    func deleteOutcome(id: UUID, ignoreMaintenance: Bool = false, cancelSystem: Bool = true) async -> MioOperationOutcome {
        if !ignoreMaintenance, !MioMaintenanceState.shared.beginWrite() { return publish(.conflict("Vänta tills dataåtgärden är klar.")) }
        defer { if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() } }
        if cancelSystem {
            let cancelled = await systemActions.cancel(id)
            guard cancelled.isSuccess else { return publish(cancelled) }
        }
        do { update(try await repository.delete(id: id)); return publish(.success) }
        catch { return publish(.failure("Kunde inte radera innehållet: \(error.localizedDescription)")) }
    }

    func setTaskCompleted(id: UUID, isCompleted: Bool) async {
        guard let item = items.first(where: { $0.id == id && $0.kind == .task }) else { return }
        _ = await saveOutcome(id: id, kind: .task, title: item.title, body: item.body, scheduledAt: item.scheduledAt,
                              isCompleted: isCompleted, sessionID: item.sessionID)
    }

    func unlinkSession(id: UUID) async { _ = await unlinkSessionOutcome(id: id) }

    func unlinkSessionOutcome(id: UUID, ignoreMaintenance: Bool = false) async -> MioOperationOutcome {
        if !ignoreMaintenance, !MioMaintenanceState.shared.beginWrite() { return publish(.conflict("Vänta tills dataåtgärden är klar.")) }
        defer { if !ignoreMaintenance { MioMaintenanceState.shared.endWrite() } }
        do { update(try await repository.unlinkSession(id: id)); return publish(.success) }
        catch { return publish(.failure("Kunde inte ta bort sessionskopplingar: \(error.localizedDescription)")) }
    }

    /// Legacy callers delegate to the same snapshot writer; cross-store reads belong to the workflow.
    func prepareExport(sessions: [MioSession], assistant: MioAssistantStoreDocument? = nil) async {
        guard MioMaintenanceState.shared.beginWrite() else { return }
        defer { MioMaintenanceState.shared.endWrite() }
        _ = await prepareExportSnapshot(content: items, sessions: sessions, assistant: assistant)
    }

    func prepareExportSnapshot(content: [MioContentItem], sessions: [MioSession],
                               assistant: MioAssistantStoreDocument?) async -> MioOperationOutcome {
        guard !isPreparingExport else { return publish(.conflict("En export skapas redan.")) }
        isPreparingExport = true
        defer { isPreparingExport = false }
        do {
            let journal = await diagnostics.snapshot()
            let configuration = MioDiagnosticsConfiguration(
                cloudEnabled: UserDefaults.standard.bool(forKey: MioCloudSettings.enabledKey),
                analysisEnabled: MioDiagnosticsRuntime.analysisEnabled,
                serverConfigured: (try? MioCloudSettings.endpoint(for: MioCloudSettings.serverAddress)) != nil,
                accessConfigured: MioCloudSettings.usesAccess)
            var diagnosticsExport = MioDiagnosticsExport(configuration: configuration, journal: journal)
            diagnosticsExport.metricReports = await metrics.reports()
            let exported = try await repository.makeExportFile(content: content, sessions: sessions, assistant: assistant,
                diagnostics: diagnosticsExport)
            exportURL = exported
            let result = publish(.success)
            if journal.storageStatus != .available {
                errorMessage = "Exporten skapades, men diagnostikjournalen är ofullständig. Se lagringsstatus i exporten."
            }
            return result
        } catch { return publish(.failure("Kunde inte skapa exportfilen: \(error.localizedDescription)")) }
    }

    func deleteAllData() async { _ = await deleteAllDataOutcome() }

    func deleteAllDataOutcome() async -> MioOperationOutcome {
        do { try await repository.deleteAll(); update([]); return publish(.success) }
        catch { return publish(.failure("Kunde inte radera lokalt innehåll: \(error.localizedDescription)")) }
    }

    func removeExportsOutcome() async -> MioOperationOutcome {
        do { try await repository.removeTemporaryExports(); exportURL = nil; return .success }
        catch { return publish(.failure("Kunde inte radera tidigare exportfiler: \(error.localizedDescription)")) }
    }

    func item(id: UUID) -> MioContentItem? { items.first { $0.id == id } }

    func filteredItems(kinds: Set<MioContentKind>? = nil, searchText: String = "") -> [MioContentItem] {
        items.filter { (kinds == nil || kinds?.contains($0.kind) == true) && $0.matches(searchText: searchText) }
    }

    private func update(_ latest: [MioContentItem]) { items = latest; stateRevision &+= 1; exportURL = nil }
    private func publish(_ outcome: MioOperationOutcome) -> MioOperationOutcome { errorMessage = outcome.message; return outcome }
}
