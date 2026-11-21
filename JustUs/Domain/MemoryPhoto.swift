import Foundation

/// The object key `set_memory_photo_path` accepts, and the JPEG the bucket stores.
enum MemoryPhoto {
  /// Live `date-photos` file_size_limit. 10 MB, image/jpeg only.
  static let byteLimit = 10 * 1024 * 1024

  static func objectPath(coupleId: UUID, dateId: UUID) -> String {
    "\(coupleId.uuidString.lowercased())/\(dateId.uuidString.lowercased()).jpg"
  }

  static func isJPEG(_ data: Data) -> Bool {
    guard data.count >= 3 else { return false }
    let start = data.startIndex
    return data[start] == 0xFF && data[start + 1] == 0xD8 && data[start + 2] == 0xFF
  }

  static func accepted(_ data: Data) -> Bool {
    isJPEG(data) && data.count <= byteLimit
  }
}
