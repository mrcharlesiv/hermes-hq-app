// [share] A picture that reaches the sheet as an object instead of a file or bytes (docs/spec/3x-share.md §7.6): a
// screenshot or a drawing an app hands over as a UIImage. ShareKit has no UIKit, so the sheet passes this to
// `ShareItemLoader.load(…, picture:)`. Also compiled into the app, only so the unit tests can exercise it.

import UIKit

nonisolated enum SharePictures {
    /// `value` as a bitmap the way a photo file is sent: at most `maxPixel` on its long side, the right way up (its
    /// orientation is drawn, not tagged), transparent pixels on white. Nil when `value` is not a picture.
    static func bitmap(_ value: Any, maxPixel: Int = ShareMedia.maxPixel) -> CGImage? {
        guard let image = value as? UIImage else { return nil }
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let ratio = min(1, CGFloat(maxPixel) / max(width, height))
        let size = CGSize(width: max(1, (width * ratio).rounded()), height: max(1, (height * ratio).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
