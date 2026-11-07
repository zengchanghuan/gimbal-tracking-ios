import CoreML
import CoreVideo
import Foundation
import Vision

final class CoreMLObjectDetector: ObjectDetecting {
    static let modelSHA256 = ObjectDetectionModels.coreMLSHA256
    let modelIdentifier = ObjectDetectionModels.coreMLIdentifier
    let backend: ObjectDetectionBackend
    private let labelPolicy: ObjectDetectionLabelPolicy

    private let request: VNCoreMLRequest
    private var lastTimestampMilliseconds = -1

    init(backend: ObjectDetectionBackend, bundle: Bundle = .main,
         labelPolicy: ObjectDetectionLabelPolicy = .benchmarkSixClasses) throws {
        guard backend == .coreMLCPU || backend == .coreMLAll else {
            throw ObjectDetectionError.unsupportedBackend(backend)
        }
        self.backend = backend
        self.labelPolicy = labelPolicy
        let modelURL = try ObjectDetectionResources.url(
            name: ObjectDetectionModels.coreMLResource, extension: "mlmodelc", bundle: bundle)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = backend == .coreMLCPU ? .cpuOnly : .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs["image"]?.type == .image,
              inputs["confidenceThreshold"]?.type == .double,
              inputs["iouThreshold"]?.type == .double,
              outputs["confidence"]?.type == .multiArray,
              outputs["coordinates"]?.type == .multiArray else {
            throw ObjectDetectionError.invalidModel("YOLOv3 image / threshold / NMS outputs")
        }
        let visionModel = try VNCoreMLModel(for: model)
        visionModel.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
            "confidenceThreshold": Double(ObjectDetectionDefaults.scoreThreshold),
            "iouThreshold": ObjectDetectionDefaults.coreMLNMSIoUThreshold
        ])
        request = VNCoreMLRequest(model: visionModel)
        // Preserve aspect ratio for the quality All backend. Vision maps its
        // recognized-object boxes back to the original image coordinates.
        // CPU and the baseline Tiny model retain their measured input policy.
        request.imageCropAndScaleOption = ObjectDetectionModels.coreMLUsesAspectFit(for: backend) ? .scaleFit : .scaleFill
        if backend == .coreMLCPU { request.usesCPUOnly = true }
    }

    func detect(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int) throws -> [ObjectDetection] {
        try ObjectDetectionResources.validate(pixelBuffer: pixelBuffer, timestamp: timestampMilliseconds,
                                              previousTimestamp: lastTimestampMilliseconds)
        lastTimestampMilliseconds = timestampMilliseconds
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up).perform([request])
        guard let results = request.results else {
            throw ObjectDetectionError.unexpectedResults(ObjectTrackingLocalized("Vision returned no results."))
        }
        guard results.allSatisfy({ $0 is VNRecognizedObjectObservation }) else {
            throw ObjectDetectionError.unexpectedResults(ObjectTrackingLocalized("VNRecognizedObjectObservation with NMS is required."))
        }
        let detections = results.compactMap { observation -> ObjectDetection? in
            guard let object = observation as? VNRecognizedObjectObservation,
                  let category = object.labels.first,
                  labelPolicy.accepts(category.identifier),
                  let box = ObjectDetectionDefaults.normalizedBox(object.boundingBox) else { return nil }
            // Vision normalizes the label distribution; recover the native
            // per-class detection score by combining it with object confidence.
            let score = object.confidence * category.confidence
            return ObjectDetection(label: category.identifier, confidence: score, boundingBox: box)
        }
        return ObjectDetectionDefaults.filtered(detections, labelPolicy: labelPolicy)
    }
}
