import Foundation

enum APIDate {
  static func parse(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }

  static func clock(_ value: String) -> String {
    String(value.prefix(5))
  }
}

struct MemberRow: Decodable {
  var userId: UUID
  var displayName: String
  var memberIndex: Int
  var coupleId: UUID

  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case displayName = "display_name"
    case memberIndex = "member_index"
    case coupleId = "couple_id"
  }
}

struct CoupleRow: Decodable {
  var id: UUID
  var weekday: Int
  var localTime: String
  var timezone: String
  var durationMinutes: Int
  var inviteeName: String

  enum CodingKeys: String, CodingKey {
    case id
    case weekday
    case localTime = "local_time"
    case timezone
    case durationMinutes = "default_duration_minutes"
    case inviteeName = "invitee_display_name"
  }
}

struct NightRow: Decodable {
  var plannerUserId: UUID
  var status: DateStatus
  var scheduledAt: String?
  var createdAt: String?
  enum CodingKeys: String, CodingKey {
    case plannerUserId = "planner_user_id"
    case status
    case scheduledAt = "scheduled_at"
    case createdAt = "created_at"
  }
}

struct DateRow: Decodable {
  var id: UUID
  var plannerUserId: UUID
  var status: DateStatus
  var scheduledAt: String
  var durationMinutes: Int
  var location: LocationKind
  var locationIsOverride: Bool
  var publicTeaser: String?
  var outfitHint: String?
  var revealedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case plannerUserId = "planner_user_id"
    case status
    case scheduledAt = "scheduled_at"
    case durationMinutes = "duration_minutes"
    case location
    case locationIsOverride = "location_is_override"
    case publicTeaser = "public_teaser"
    case outfitHint = "outfit_hint"
    case revealedAt = "revealed_at"
  }
}

struct MoodRow: Decodable {
  var userId: UUID
  var mood: String
  enum CodingKeys: String, CodingKey {
    case userId = "user_id"
    case mood
  }
}

struct PlanRow: Decodable {
  var ideaId: String
  var privateNotes: String?
  enum CodingKeys: String, CodingKey {
    case ideaId = "idea_id"
    case privateNotes = "private_notes"
  }
}

struct NoteRow: Decodable, Identifiable {
  var id: UUID
  var authorUserId: UUID?
  var authorName: String?
  var note: String
  enum CodingKeys: String, CodingKey {
    case id
    case authorUserId = "author_user_id"
    case authorName = "author_name"
    case note
  }
}

struct MemoryDateRow: Decodable {
  var id: UUID
  var scheduledAt: String
  var location: String
  var completedAt: String?
  var snapshotTitle: String?
  var snapshotEmoji: String?
  var snapshotSummary: String?
  var snapshotIdeaId: String?
  var memoryPhotoPath: String?
  var memoryNotes: [NoteRow]?

  enum CodingKeys: String, CodingKey {
    case id
    case scheduledAt = "scheduled_at"
    case location
    case completedAt = "completed_at"
    case snapshotTitle = "snapshot_title"
    case snapshotEmoji = "snapshot_emoji"
    case snapshotSummary = "snapshot_summary"
    case snapshotIdeaId = "snapshot_idea_id"
    case memoryPhotoPath = "memory_photo_path"
    case memoryNotes = "memory_notes"
  }
}

struct InviteRow: Decodable {
  var expiresAt: String
  enum CodingKeys: String, CodingKey {
    case expiresAt = "expires_at"
  }
}

struct CreateCoupleParams: Encodable {
  var pSelfName: String
  var pPartnerName: String
  var pWeekday: Int
  var pLocalTime: String
  var pTimezone: String
  var pDurationMinutes: Int

  enum CodingKeys: String, CodingKey {
    case pSelfName = "p_self_name"
    case pPartnerName = "p_partner_name"
    case pWeekday = "p_weekday"
    case pLocalTime = "p_local_time"
    case pTimezone = "p_timezone"
    case pDurationMinutes = "p_duration_minutes"
  }
}

struct RedeemParams: Encodable {
  var pToken: String
  var pReplaceEmpty: Bool
  enum CodingKeys: String, CodingKey {
    case pToken = "p_token"
    case pReplaceEmpty = "p_replace_empty"
  }
}

struct CompleteParams: Encodable {
  var pDateId: UUID
  var pNote: String
  enum CodingKeys: String, CodingKey {
    case pDateId = "p_date_id"
    case pNote = "p_note"
  }
}

struct CoupleIDParams: Encodable {
  var pCoupleId: UUID
  enum CodingKeys: String, CodingKey {
    case pCoupleId = "p_couple_id"
  }
}

struct PhotoPathParams: Encodable {
  var pDateId: UUID
  var pPath: String
  enum CodingKeys: String, CodingKey {
    case pDateId = "p_date_id"
    case pPath = "p_path"
  }
}

struct MemberIdRow: Decodable {
  var userId: UUID
  enum CodingKeys: String, CodingKey { case userId = "user_id" }
}

struct DeviceKeyRow: Decodable {
  var id: UUID
  var userId: UUID
  var publicKey: String
  var createdAt: String
  var retiredAt: String?
  enum CodingKeys: String, CodingKey {
    case id
    case userId = "user_id"
    case publicKey = "public_key"
    case createdAt = "created_at"
    case retiredAt = "retired_at"
  }
}

struct DeviceKeyRetire: Encodable {
  var retiredAt: String
  enum CodingKeys: String, CodingKey { case retiredAt = "retired_at" }
}

struct DeviceKeyInsert: Encodable {
  var id: UUID
  var userId: UUID
  var publicKey: String
  enum CodingKeys: String, CodingKey {
    case id
    case userId = "user_id"
    case publicKey = "public_key"
  }
}

struct EnvelopeWire: Codable {
  var keyId: UUID
  var box: String
  enum CodingKeys: String, CodingKey {
    case keyId = "key_id"
    case box
  }
}

struct ChatMessageRow: Decodable {
  var id: UUID
  var senderUserId: UUID
  var senderPublicKey: String
  var createdAt: String
  var envelopes: [EnvelopeWire]
  var kind: String
  var retention: String?
  var photoPath: String?
  var openedAt: String?
  var expiresAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case senderUserId = "sender_user_id"
    case senderPublicKey = "sender_public_key"
    case createdAt = "created_at"
    case envelopes
    case kind
    case retention
    case photoPath = "photo_path"
    case openedAt = "opened_at"
    case expiresAt = "expires_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    senderUserId = try container.decode(UUID.self, forKey: .senderUserId)
    senderPublicKey = try container.decode(String.self, forKey: .senderPublicKey)
    createdAt = try container.decode(String.self, forKey: .createdAt)
    envelopes = try container.decode([EnvelopeWire].self, forKey: .envelopes)
    kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "text"
    retention = try container.decodeIfPresent(String.self, forKey: .retention)
    photoPath = try container.decodeIfPresent(String.self, forKey: .photoPath)
    openedAt = try container.decodeIfPresent(String.self, forKey: .openedAt)
    expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
  }
}

struct ChatPhotoInsert: Encodable {
  var id: UUID
  var coupleId: UUID
  var senderUserId: UUID
  var senderPublicKey: String
  var envelopes: [EnvelopeWire]
  var kind: String
  var retention: String?
  var photoPath: String?

  enum CodingKeys: String, CodingKey {
    case id
    case coupleId = "couple_id"
    case senderUserId = "sender_user_id"
    case senderPublicKey = "sender_public_key"
    case envelopes
    case kind
    case retention
    case photoPath = "photo_path"
  }
}

struct ChatInsert: Encodable {
  var id: UUID
  var coupleId: UUID
  var senderUserId: UUID
  var senderPublicKey: String
  var envelopes: [EnvelopeWire]
  enum CodingKeys: String, CodingKey {
    case id
    case coupleId = "couple_id"
    case senderUserId = "sender_user_id"
    case senderPublicKey = "sender_public_key"
    case envelopes
  }
}
