import Foundation
import SwiftData
import XCTest
@testable import Mio

/// Exercises the real SwiftData content path in memory: an existing row must be updated in place.
final class MioSwiftDataContentTests: XCTestCase {
    func testCompletingAStoredTaskUpdatesTheExistingRow() async throws {
        let container = try MioPersistentStore.makeInMemoryContainer()
        let repository = MioSwiftDataContentRepository(modelContainer: container)
        var task = MioContentItem(kind: .task, title: "Syntetisk uppgift", scheduledAt: .now)
        _ = try await repository.upsert(task)

        task.completedAt = .now
        task.updatedAt = .now
        let saved = try await repository.upsert(task)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved.first?.isCompleted == true)

        // A second actor on the same container reads only what was committed.
        let reread = try await MioSwiftDataContentRepository(modelContainer: container).loadItems()
        XCTAssertEqual(reread.map(\.id), [task.id])
        XCTAssertTrue(reread.first?.isCompleted == true)
    }

    @MainActor
    func testSetTaskCompletedTogglesThroughTheViewModel() async throws {
        let container = try MioPersistentStore.makeInMemoryContainer()
        let model = MioContentViewModel(repository: MioSwiftDataContentRepository(modelContainer: container),
                                        systemActions: MioSystemActionPort(cancel: { _ in .success }, removeAll: { .success }))
        let created = await model.saveOutcome(kind: .task, title: "Syntetisk uppgift", body: "", scheduledAt: .now,
                                              isCompleted: false, sessionID: nil)
        XCTAssertEqual(created, .success)
        let id = try XCTUnwrap(model.items.first?.id)

        await model.setTaskCompleted(id: id, isCompleted: true)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.item(id: id)?.isCompleted == true)

        await model.setTaskCompleted(id: id, isCompleted: false)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.item(id: id)?.isCompleted == false)
    }
}
