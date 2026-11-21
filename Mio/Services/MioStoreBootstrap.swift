import Foundation
import SwiftData

/// Chooses the storage backend once per launch, off the main actor: opens the SwiftData
/// store, runs the one-time migration and falls back without destroying anything.
final class MioStoreResolver: Sendable {
    static let shared = MioStoreResolver()
    private let task: Task<MioResolvedStores, Never>

    private init() {
        task = Task.detached(priority: .userInitiated) { await MioStoreResolver.resolve(files: .standard) }
    }

    func stores() async -> MioResolvedStores { await task.value }

    var deferred: MioDeferredStores {
        MioDeferredStores(resolve: { await MioStoreResolver.shared.stores() })
    }

    private static func resolve(files: MioLegacyStoreFiles) async -> MioResolvedStores {
        let container: ModelContainer
        do {
            container = try MioPersistentStore.makeContainer(files: files)
        } catch {
            MioLog.error(.storage, "store open failed")
            let migrated: Bool
            do { migrated = try files.readMarker() != nil } catch { migrated = true }
            guard migrated else {
                // Nothing has moved yet: the untouched legacy files stay authoritative.
                return .legacyFiles(message: "Mio kunde inte öppna den nya databasen. Ingenting har flyttats eller raderats; "
                    + "Mio fortsätter med de gamla filerna och försöker igen vid nästa start.")
            }
            // Data already lives in the store; never start parallel legacy files beside it.
            let message = "Mio kunde inte öppna databasen. Dina sparade data är orörda men visas inte, "
                + "och ändringar under den här körningen sparas inte. Starta om Mio."
            return temporaryStores(message: message)
        }
        let target = MioSwiftDataMigrationTarget(modelContainer: container)
        let outcome = await MioStoreMigrator(files: files, target: target).run()
        switch outcome {
        case let .useStore(message):
            // A restore she confirmed (fas 6) replaces every row in one transaction here, before any
            // repository opens, so nothing can write beside it. Never into legacy or temporary stores.
            let deletionPending = FileManager.default.fileExists(
                atPath: files.directory.appendingPathComponent("operations-v1.json").path)
            // Any deletion begun after the copy was chosen refuses it, even one that has finished.
            let restored = await MioBackupRestore.applyPending(files: files, target: target, deletionPending: deletionPending,
                deletionGeneration: MioBackupRestore.deletionGeneration(in: .standard))
            return stores(container: container, message: [message, restored].compactMap { $0 }.joined(separator: "\n\n").nilIfEmpty)
        case let .useLegacyFiles(message):
            return .legacyFiles(message: message)
        case let .useTemporaryStore(message):
            return temporaryStores(message: message)
        }
    }

    /// Never the real legacy files: data may already live in the store (ultrareview B2).
    private static func temporaryStores(message: String) -> MioResolvedStores {
        if let memory = try? MioPersistentStore.makeInMemoryContainer() {
            return stores(container: memory, message: message, temporary: true)
        }
        return .temporaryFiles(message: message)
    }

    private static func stores(container: ModelContainer, message: String?, temporary: Bool = false) -> MioResolvedStores {
        MioResolvedStores(sessions: MioSwiftDataSessionRepository(modelContainer: container),
                          content: MioSwiftDataContentRepository(modelContainer: container),
                          assistant: MioSwiftDataAssistantRepository(modelContainer: container),
                          message: message, isTemporary: temporary)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
