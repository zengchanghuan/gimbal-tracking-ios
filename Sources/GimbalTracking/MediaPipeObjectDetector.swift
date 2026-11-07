#if canImport(MediaPipeTasksVision)
import CoreVideo
import Foundation
import MediaPipeTasksVision
import Metal

final class MediaPipeObjectDetector: ObjectDetecting {
    static let modelSHA256 = ObjectDetectionModels.mediaPipeSHA256
    let modelIdentifier = ObjectDetectionModels.mediaPipeIdentifier
    let backend: ObjectDetectionBackend
    private let labelPolicy: ObjectDetectionLabelPolicy

    private let detector: ObjectDetector
    private var metalTextureCache: CVMetalTextureCache?
    private var lastTimestampMilliseconds = -1

    init(backend: ObjectDetectionBackend, bundle: Bundle = .main,
         labelPolicy: ObjectDetectionLabelPolicy = .benchmarkSixClasses) throws {
        guard backend == .mediaPipeCPU || backend == .mediaPipeGPU else {
            throw ObjectDetectionError.unsupportedBackend(backend)
        }
        #if targetEnvironment(simulator)
        guard backend != .mediaPipeGPU else {
            // The SDK can abort in its Metal helper on Simulator rather than
            // returning an NSError. Reject before constructing its GPU graph.
            throw ObjectDetectionError.gpuUnavailable(ObjectTrackingLocalized("This backend is unavailable in Simulator. Evaluate the GPU on a physical device."))
        }
        #endif
        self.backend = backend
        self.labelPolicy = labelPolicy
        if backend == .mediaPipeGPU {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw ObjectDetectionError.gpuUnavailable(ObjectTrackingLocalized("No Metal GPU is available on this device."))
            }
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess, let cache else {
                throw ObjectDetectionError.gpuUnavailable(ObjectTrackingLocalized("Cannot create Metal texture cache (%@)", String(describing: status)))
            }
            metalTextureCache = cache
        }
        let modelURL = try ObjectDetectionResources.url(
            name: ObjectDetectionModels.mediaPipeResource, extension: "tflite", bundle: bundle)
        let options = ObjectDetectorOptions()
        options.baseOptions.modelAssetPath = modelURL.path
        options.baseOptions.delegate = backend == .mediaPipeGPU ? .GPU : .CPU
        options.runningMode = .video
        options.scoreThreshold = ObjectDetectionDefaults.scoreThreshold
        // MediaPipe 0.10.35's Metal postprocessor CHECKs that every class is
        // allowed. A subset categoryAllowlist aborts the process on real GPUs.
        // Use the same unrestricted graph for CPU/GPU, then apply the chosen
        // application label policy and top-K below. Limiting here could let other classes
        // displace relevant objects before the application-level filter.
        options.maxResults = -1
        options.displayNamesLocale = "en"
        // Initialization failures must reach the caller. A failed GPU request
        // must not be silently relabeled as a successful GPU benchmark on CPU.
        detector = try ObjectDetector(options: options)
    }

    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [ObjectDetection] {
        try ObjectDetectionResources.validate(pixelBuffer: pixelBuffer, timestamp: timestampMilliseconds,
                                              previousTimestamp: lastTimestampMilliseconds)
        if let metalTextureCache {
            try validateMetalCompatibility(pixelBuffer, cache: metalTextureCache)
        }
        lastTimestampMilliseconds = timestampMilliseconds
        let image = try MPImage(pixelBuffer: pixelBuffer, orientation: .up)
        let result = try detector.detect(videoFrame: image, timestampInMilliseconds: timestampMilliseconds)
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let detections = result.detections.compactMap { detection -> ObjectDetection? in
            guard let category = detection.categories.max(by: { $0.score < $1.score }),
                  let label = category.categoryName,
                  labelPolicy.accepts(label) else { return nil }
            // MediaPipe returns pixel coordinates with the unrotated image's
            // top-left origin. Convert once to the common Vision convention.
            let pixels = detection.boundingBox
            let normalized = CGRect(x: pixels.minX / width, y: 1 - pixels.maxY / height,
                                    width: pixels.width / width, height: pixels.height / height)
            guard let box = ObjectDetectionDefaults.normalizedBox(normalized) else { return nil }
            return ObjectDetection(label: label, confidence: category.score, boundingBox: box)
        }
        return ObjectDetectionDefaults.filtered(detections, labelPolicy: labelPolicy)
    }

    /// MediaPipe's Metal helper CHECKs texture creation instead of returning an
    /// NSError. Verify the actual buffer can be mapped before calling that API;
    /// an allocation attribute alone does not prove its backing is compatible.
    private func validateMetalCompatibility(_ pixelBuffer: CVPixelBuffer,
                                            cache: CVMetalTextureCache) throws {
        defer { CVMetalTextureCacheFlush(cache, 0) }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture)
        guard status == kCVReturnSuccess, let texture,
              CVMetalTextureGetTexture(texture) != nil else {
            throw ObjectDetectionError.gpuUnavailable(
                ObjectTrackingLocalized("Cannot map input to a Metal texture (%@). Use a Metal-compatible IOSurface pixel buffer.", String(describing: status)))
        }
    }
}

#endif
