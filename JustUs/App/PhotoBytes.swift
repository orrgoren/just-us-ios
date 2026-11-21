import CoreTransferable
import UniformTypeIdentifiers
import UIKit

/// PhotosPicker's `Data` transferable often comes back empty for a library
/// photo, so the upload never runs. Importing the image type yields bytes.
struct PickedImage: Transferable {
  let data: Data

  static func imported(_ data: Data) throws -> PickedImage {
    guard data.isEmpty == false else { throw CocoaError(.coderReadCorrupt) }
    return PickedImage(data: data)
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .image) { data in
      try PickedImage.imported(data)
    }
  }
}

enum PhotoBytes {
  static func jpeg(from data: Data, maxEdge: CGFloat = 1600, quality: CGFloat = 0.72) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let longest = max(image.size.width, image.size.height)
    let scale = longest > 0 ? min(1, maxEdge / longest) : 1
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: size)
    let rendered = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    return rendered.jpegData(compressionQuality: quality)
  }

  static func sample() -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
    let image = renderer.image { context in
      UIColor(red: 110 / 255, green: 36 / 255, blue: 54 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }
    return image.jpegData(compressionQuality: 0.8) ?? Data()
  }
}
