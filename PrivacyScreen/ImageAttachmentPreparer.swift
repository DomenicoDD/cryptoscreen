import ImageIO
import UIKit

/// Turns a picked photo into an upload-ready JPEG plus a small preview.
///
/// Uses ImageIO thumbnailing so a 48 MP photo is never fully decoded
/// (UIImage(data:) would allocate ~190 MB), and runs off the main actor so
/// picking an image doesn't hitch the UI. Shared by the app and the iMessage
/// extension so the two paths can't drift apart again.
enum ImageAttachmentPreparer {
  struct Prepared: Sendable {
    let data: Data
    let preview: UIImage
  }

  enum PreparationError: Error {
    case unreadableImage
    case tooLarge
  }

  static func prepare(
    _ data: Data,
    maxPixelDimension: CGFloat = 2400,
    previewPixelDimension: CGFloat = 400
  ) async throws -> Prepared {
    try await Task.detached(priority: .userInitiated) {
      try prepareSync(data, maxPixelDimension: maxPixelDimension, previewPixelDimension: previewPixelDimension)
    }.value
  }

  static func prepareSync(
    _ data: Data,
    maxPixelDimension: CGFloat,
    previewPixelDimension: CGFloat
  ) throws -> Prepared {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let fullImage = downsample(source, maxPixelDimension: maxPixelDimension) else {
      throw PreparationError.unreadableImage
    }

    let opaqueImage = flattened(fullImage)

    for quality in [0.86, 0.74, 0.62] as [CGFloat] {
      guard let encoded = opaqueImage.jpegData(compressionQuality: quality) else {
        continue
      }

      if encoded.count <= SealedMessageCrypto.maxImageAttachmentByteCount {
        let preview = downsample(source, maxPixelDimension: previewPixelDimension).map(UIImage.init(cgImage:)) ?? opaqueImage
        return Prepared(data: encoded, preview: preview)
      }
    }

    throw PreparationError.tooLarge
  }

  private static func downsample(_ source: CGImageSource, maxPixelDimension: CGFloat) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelDimension))
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// JPEG has no alpha; composite transparent images onto the app background
  /// (matching the previous behaviour) at 1x scale.
  private static func flattened(_ image: CGImage) -> UIImage {
    let size = CGSize(width: image.width, height: image.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor(red: 0.045, green: 0.047, blue: 0.043, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
    }
  }
}
