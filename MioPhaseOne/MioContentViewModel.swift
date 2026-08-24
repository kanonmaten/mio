import Foundation
import Observation

@MainActor
@Observable
final class MioContentViewModel {
    var items: [MioContentItem] = []
    var errorMessage: String?
    var exportURL: URL?
    var isPreparingExport = false

    @ObservationIgnored private let repository: MioContentRepository
    @ObservationIgnored private var hasBootstrapped = false

    init(repository: MioContentRepository = MioContentRepository()) {
        self.repository = repository
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            items = try await repository.loadItems()
        } catch {
            errorMessage = "Kunde inte läsa lokalt innehåll: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(
        id: UUID? = nil,
        kind: MioContentKind,
        title: String,
        body: String,
        scheduledAt: Date,
        isCompleted: Bool,
        sessionID: UUID?
    ) async -> Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            errorMessage = "Skriv en rubrik innan du sparar."
            return false
        }

        let existing = id.flatMap { item(id: $0) }
        let item = MioContentItem(
            id: existing?.id ?? UUID(),
            kind: kind,
            title: cleanTitle,
            body: cleanBody,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now,
            scheduledAt: scheduledAt,
            completedAt: kind == .task && isCompleted
                ? existing?.completedAt ?? .now
                : nil,
            sessionID: sessionID
        )
        do {
            items = try await repository.upsert(item)
            exportURL = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Kunde inte spara innehållet: \(error.localizedDescription)"
            return false
        }
    }

    func delete(id: UUID) async {
        do {
            items = try await repository.delete(id: id)
            exportURL = nil
            errorMessage = nil
        } catch {
            errorMessage = "Kunde inte radera innehållet: \(error.localizedDescription)"
        }
    }

    func setTaskCompleted(id: UUID, isCompleted: Bool) async {
        guard var item = item(id: id), item.kind == .task else { return }
        item.completedAt = isCompleted ? item.completedAt ?? .now : nil
        item.updatedAt = .now
        do {
            items = try await repository.upsert(item)
            exportURL = nil
            errorMessage = nil
        } catch {
            errorMessage = "Kunde inte uppdatera uppgiften: \(error.localizedDescription)"
        }
    }

    func unlinkSession(id: UUID) async {
        let linkedItems = items.filter { $0.sessionID == id }
        guard !linkedItems.isEmpty else { return }
        do {
            var latestItems = items
            for var item in linkedItems {
                item.sessionID = nil
                item.updatedAt = .now
                latestItems = try await repository.upsert(item)
            }
            items = latestItems
            exportURL = nil
        } catch {
            errorMessage = "Kunde inte ta bort sessionskopplingar: \(error.localizedDescription)"
        }
    }

    func prepareExport(sessions: [PhaseOneSession]) async {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        defer { isPreparingExport = false }
        do {
            exportURL = try await repository.makeExportFile(
                content: items,
                sessions: sessions
            )
            errorMessage = nil
        } catch {
            errorMessage = "Kunde inte skapa exportfilen: \(error.localizedDescription)"
        }
    }

    func deleteAllData() async {
        do {
            try await repository.deleteAll()
            items = []
            exportURL = nil
            errorMessage = nil
        } catch {
            errorMessage = "Kunde inte radera lokalt innehåll: \(error.localizedDescription)"
        }
    }

    func item(id: UUID) -> MioContentItem? {
        items.first { $0.id == id }
    }

    func filteredItems(
        kinds: Set<MioContentKind>? = nil,
        searchText: String = ""
    ) -> [MioContentItem] {
        items.filter { item in
            (kinds == nil || kinds?.contains(item.kind) == true)
                && item.matches(searchText: searchText)
        }
    }
}
