import XCTest
@testable import JustUs

@MainActor
final class MemoryPhotoTests: XCTestCase {
  private let finished = SeedID.uuid("17171717-1717-4171-8171-171717171717")

  func testAPhotoSurvivesARestartAndThePartnerSeesIt() async throws {
    let store = FakeStore(inMemory: true)
    let alex = FakeBackend(store: store, cooldown: 0)
    try await signIn(alex, "alex@couple-a.test")
    let jpeg = PhotoBytes.sample()
    XCTAssertTrue(MemoryPhoto.accepted(jpeg))
    try await alex.savePhoto(dateId: finished, jpeg: jpeg)

    let restarted = FakeBackend(store: store, cooldown: 0)
    try await signIn(restarted, "alex@couple-a.test")
    let mine = try await restarted.memories()
    let saved = try XCTUnwrap(mine.first { $0.id == finished })
    XCTAssertEqual(saved.photoJPEG, jpeg)
    XCTAssertEqual(saved.photoState, .saved)
    XCTAssertEqual(
      saved.photoPath,
      MemoryPhoto.objectPath(coupleId: SeedID.coupleA, dateId: finished)
    )

    let blair = FakeBackend(store: store, cooldown: 0)
    try await signIn(blair, "blair@couple-a.test")
    let shared = try await blair.memories()
    XCTAssertEqual(shared.first { $0.id == finished }?.photoJPEG, jpeg)
  }

  func testANonPartnerCannotSeeOrReplaceThePhoto() async throws {
    let store = FakeStore(inMemory: true)
    let alex = FakeBackend(store: store, cooldown: 0)
    try await signIn(alex, "alex@couple-a.test")
    try await alex.savePhoto(dateId: finished, jpeg: PhotoBytes.sample())

    let casey = FakeBackend(store: store, cooldown: 0)
    try await signIn(casey, "casey@couple-b.test")
    let theirs = try await casey.memories()
    XCTAssertFalse(theirs.contains { $0.id == finished })
    do {
      try await casey.savePhoto(dateId: finished, jpeg: PhotoBytes.sample())
      XCTFail("A non-partner saved a photo")
    } catch let error as AppError {
      XCTAssertEqual(error, .saveFailed)
    }
  }

  func testTheBucketRulesRejectANonJpegAndAnOversizedFile() {
    XCTAssertFalse(MemoryPhoto.accepted(Data([0, 1, 2])))
    var huge = Data([0xFF, 0xD8, 0xFF])
    huge.append(Data(repeating: 0, count: MemoryPhoto.byteLimit))
    XCTAssertFalse(MemoryPhoto.accepted(huge))
  }

  func testAManualSwapStaysUntilTheNightIsFinished() async throws {
    let backend = FakeBackend(store: FakeStore(inMemory: true), cooldown: 0)
    try await signIn(backend, "alex@couple-a.test")
    let before = try XCTUnwrap(try await backend.ritual())
    XCTAssertEqual(before.date?.plannerUserId, SeedID.alex)
    try await backend.swapPlanner()
    try await backend.ensureDraft()
    let after = try XCTUnwrap(try await backend.ritual())
    XCTAssertEqual(after.date?.plannerUserId, SeedID.blair)
    XCTAssertFalse(after.isPlanner)
    let held = try XCTUnwrap(try await backend.ritual())
    XCTAssertEqual(held.date?.plannerUserId, SeedID.blair)
  }

  private func signIn(_ backend: FakeBackend, _ email: String) async throws {
    _ = try await backend.sendCode(email: email)
    _ = try await backend.verify(email: email, code: "000000")
  }
}
