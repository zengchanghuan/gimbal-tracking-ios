import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class ScreenFollowFrameAdapter {
    // Extension runs in the background. Do not submit Metal/OpenGL work there.
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    func jpeg(from sample: CMSampleBuffer) throws -> Data {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Unavailable"))
        }
        let raw = (CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
        guard let orientation = CGImagePropertyOrientation(rawValue: raw) else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Orientation Unavailable"))
        }
        let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        let scale = min(1, 640 / max(source.extent.width, source.extent.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Conversion Failed"))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Encoding Failed"))
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenFollowError.message(ScreenFollowLocalized("Screen Frame Encoding Failed")) }
        return data as Data
    }
}
