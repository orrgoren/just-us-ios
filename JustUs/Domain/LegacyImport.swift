import Foundation

struct LegacyMemory: Equatable, Sendable {
  var ideaId: String?
  var title: String
  var emoji: String?
  var date: String
  var planner: Int?
  var note: String?
}

struct LegacyPreview: Equatable, Sendable {
  var memories: [LegacyMemory]
  var names: [String]?
  var day: Int?
  var time: String?
  var declaredCount: Int?
  var countMismatch: Bool
  var ignoredActivePlan: Bool
  var unknownIdeaIds: [String]
}

enum LegacyImport {
  static func analyze(_ data: Data) throws -> LegacyPreview {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any] else { throw AppError.server(code: "invalid_import") }
    let settings = root["settings"] as? [String: Any]
    let memoriesRaw = (root["memories"] as? [Any]) ?? []
    guard memoriesRaw.count <= 500 else { throw AppError.server(code: "invalid_import") }
    var memories: [LegacyMemory] = []
    for item in memoriesRaw {
      guard let row = item as? [String: Any] else { throw AppError.server(code: "invalid_import") }
      let title = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let date = row["date"] as? String ?? ""
      guard (1...200).contains(title.count), date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
        throw AppError.server(code: "invalid_import")
      }
      let note = (row["note"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      memories.append(LegacyMemory(
        ideaId: (row["ideaId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        title: title,
        emoji: (row["emoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
        date: date,
        planner: row["planner"] as? Int,
        note: note?.nilIfEmpty
      ))
    }
    let namesSource = (settings?["names"] as? [String]) ?? (root["names"] as? [String])
    let names = namesSource?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let dayValue = (settings?["day"] as? Int) ?? (root["day"] as? Int)
    let day = dayValue.flatMap { (0...6).contains($0) ? $0 : nil }
    let time = cleanTime((settings?["time"] as? String) ?? (root["time"] as? String))
    let declared = root["count"] as? Int
    let unknown = Array(Set(memories.compactMap(\.ideaId).filter { $0.range(of: #"^[ho]\d+$"#, options: .regularExpression) == nil })).sorted()
    return LegacyPreview(
      memories: memories,
      names: names,
      day: day,
      time: time,
      declaredCount: declared,
      countMismatch: declared != nil && declared != memories.count,
      ignoredActivePlan: root["planned"] != nil && !(root["planned"] is NSNull),
      unknownIdeaIds: unknown
    )
  }

  private static func cleanTime(_ value: String?) -> String? {
    guard let value, let match = value.range(of: #"^\d{2}:\d{2}"#, options: .regularExpression) else { return nil }
    let prefix = String(value[match])
    guard Validation.time(prefix) != nil else { return nil }
    return prefix
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
