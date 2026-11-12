import Foundation
import AVFoundation
import UIKit

/// 從音檔內嵌的標籤讀封面，縮圖後放進記憶體快取。
final class CoverLoader {
    static let shared = CoverLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let missing = NSCache<NSString, NSNumber>()

    private init() {
        cache.countLimit = 200
        missing.countLimit = 2000
    }

    func cached(_ track: Track) -> UIImage? {
        return cache.object(forKey: track.id as NSString)
    }

    func load(_ track: Track) async -> UIImage? {
        let key = track.id as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if missing.object(forKey: key) != nil { return nil }

        let url = MusicLibrary.documentsURL.appendingPathComponent(track.relPath)
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let full = UIImage(data: data) {
                    return CoverLoader.downscale(full, maxSide: 600)
                }
            }
            return nil
        }.value

        if let image = image {
            cache.setObject(image, forKey: key)
        } else {
            missing.setObject(NSNumber(value: true), forKey: key)
        }
        return image
    }

    private static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        if longest <= maxSide || longest <= 0 { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
