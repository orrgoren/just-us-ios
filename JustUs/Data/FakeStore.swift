import Foundation

@MainActor
final class FakeStore {
  nonisolated static let fileName = "justus-uitest-world.json"
  var world: FakeWorld
  private var spaceClosed: Set<UUID> = []
  private let persist: Bool

  init(inMemory: Bool = false, now: Date = Date()) {
    persist = !inMemory
    if inMemory {
      world = FakeWorld.seed(now: now)
    } else {
      world = Self.read() ?? FakeWorld.seed(now: now)
    }
  }

  func markSpaceClosed(_ userId: UUID) {
    spaceClosed.insert(userId)
  }

  func takeSpaceClosed(_ userId: UUID) -> Bool {
    spaceClosed.remove(userId) != nil
  }

  func save() {
    guard persist else { return }
    guard let url = Self.fileURL(), let data = try? JSONEncoder().encode(world) else { return }
    try? data.write(to: url, options: .atomic)
  }

  nonisolated static func resetFiles() {
    guard let url = fileURL() else { return }
    try? FileManager.default.removeItem(at: url)
    CacheStore.deleteAll()
  }

  nonisolated private static func read() -> FakeWorld? {
    guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(FakeWorld.self, from: data)
  }

  nonisolated private static func fileURL() -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let folder = base.appendingPathComponent("JustUs", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent(fileName)
  }
}

enum CacheStore {
  static func deleteAll() {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return
    }
    let folder = base.appendingPathComponent("JustUs", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
      return
    }
    for file in files where file.lastPathComponent.hasPrefix("cache-") {
      try? FileManager.default.removeItem(at: file)
    }
  }

  static func url(userId: UUID) -> URL? {
    guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let folder = base.appendingPathComponent("JustUs", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("cache-\(userId.uuidString).json")
  }
}
