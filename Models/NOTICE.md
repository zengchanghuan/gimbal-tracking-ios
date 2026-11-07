# Object detection model provenance

Downloaded from the publishers on 2026-10-16. The exact source URLs, byte sizes,
SHA-256 digests, inspected input/output signatures and model identifiers are in
`models.json`. Run `python3 download_models.py --verify-only` to check the local
files, or `python3 download_models.py` to restore missing/changed model files.
The downloader refuses upstream bytes that no longer match the pinned digest.

These are a **product configuration comparison**. The quality preset uses
EfficientDet-Lite2 float32 and full YOLOv3 FP16. The original EfficientDet-Lite0
float32 / YOLOv3 Tiny FP16 baseline remains pinned for reproducing earlier runs;
baseline files are not bundled in the quality product build. These pairs have
different weights, architectures, input resolutions and postprocessing.
Results must not be presented as evidence that one inference framework is more
accurate. The frozen benchmark restricts both adapters to cup, bottle, cell
phone, cat, dog and car. The camera's discovery-only mode explicitly requests
all existing model labels; manual selection is not restricted by a class label.
This does not add classes the pretrained models have not learned.
The 0.35 score threshold and top 20 are development defaults, not calibrated
precision/recall operating points.

The quality models were selected as one capacity increase per existing model
family, before their iPhone regression results were available. Reusing the
previously analyzed 140-image set is an optimization regression, not an
independent holdout or proof of generalization. A larger model does not establish
acceptable tracking coverage, latency, sustained temperature or memory use.

## Quality preset: EfficientDet-Lite2 float32 v1

- Official versioned asset:
  https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite2/float32/1/efficientdet_lite2.tflite
- SHA-256: `ad2abbf2b4e10585e15176fd7b5ef03c28dda959ae26fc142549fdd1814db91d`.
  Source file size: 23,096,891 bytes; RGB float32 input 448x448, compared with
  the baseline's 13,836,895 bytes and 320x320 input. These are source file sizes,
  not installed application size or runtime memory.
- The official catalog describes Lite2 as a larger, generally more accurate
  and slower alternative to Lite0:
  https://ai.google.dev/edge/mediapipe/solutions/vision/object_detector
- The same MediaPipe 0.10.35 adapter uses embedded normalization and decoder
  metadata, native NMS, threshold 0.35 and the six-category/top20 contract.
  No `truck`-to-`car` or other label aliases are added for the regression.
- As with the baseline, embedded author/version metadata does not independently
  establish the exact converted weights' license. Retain the publisher terms,
  COCO provenance and the license boundary described in the Lite0 section below;
  the SDK's Apache 2.0 source license is not a separate model-weight grant.

## Quality preset: Apple YOLOv3 FP16

- Official versioned asset:
  https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3/YOLOv3FP16.mlmodel
- SHA-256: `276afae53da362e25ad21c827f8a929a8512254b1343433d970e725a0de57d8f`.
  Source file size: 124,207,764 bytes, compared with the Tiny baseline's
  17,769,580 bytes. Both use a 416x416 RGB image input; full YOLOv3 increases
  model capacity rather than input resolution.
- This is a different pretrained network, not a framework-only or compute-unit
  optimization. Keep the actual model identifier and digest in every run.
- The source model retains the publisher's Darknet license reference. The
  preserved Darknet license texts and provenance limits in the Tiny section
  also apply to the documentation of this model family; do not infer a new
  license grant from the filename or Core ML framework.

## MediaPipe EfficientDet-Lite0 float32 v1

- Baseline versioned asset, retained for reproducibility:
  https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float32/1/efficientdet_lite0.tflite
- Official catalog: https://ai.google.dev/edge/mediapipe/solutions/vision/object_detector
- Official sample uses the identical versioned URL:
  https://github.com/google-ai-edge/mediapipe-samples-web/blob/main/src/tasks/object-detector.ts
- The installed SDK is MediaPipeTasksVision 0.10.35. Its full license text is
  preserved as `MEDIAPIPE-APACHE-2.0.txt`, copied unchanged from the installed Pod.
  Source: https://github.com/google-ai-edge/mediapipe/blob/v0.10.35/LICENSE
- The downloaded model's embedded metadata identifies author `MediaPipe`, version
  `1`, and has no license string. The TensorFlow EfficientDet upstream model
  family publishes Apache 2.0 terms:
  https://www.kaggle.com/models/tensorflow/efficientdet
  This does not establish byte-for-byte provenance of this MediaPipe conversion.
  Keep the publisher links and this uncertainty with the artifact; do not claim
  that the SDK's source-code license independently grants rights to these exact
  pretrained weights. Distribution review must retain the model's applicable
  publisher terms and COCO data provenance.
- The embedded label file contains 90 positions including placeholders for
  sparse COCO category IDs. The adapter uses category names, not an assumed
  dense 80-index table.
- This exact asset has two raw output tensors and `DETECTOR_METADATA`. Although
  the 0.10.35 Objective-C header describes only four-output models, the actual
  0.10.35 DetectionPostprocessingGraph supports both two-output models with
  decoder metadata and four-output models with in-model NMS:
  https://github.com/google-ai-edge/mediapipe/blob/v0.10.35/mediapipe/tasks/cc/components/processors/detection_postprocessing_graph.cc
- CPU and GPU are distinct requested configurations. The public SDK API exposes
  no Apple Neural Engine option; failure is reported rather than silently
  switching a benchmark to another backend. Individual operator placement is
  controlled by the SDK.
- The simulator GPU configuration is rejected before SDK initialization because
  a simulator Metal texture failure in this SDK can abort the process instead
  of returning a Swift error. GPU evaluation requires a physical device.
  Physical-device GPU inputs are preflighted with `CVMetalTextureCache` before
  entering MediaPipe. Pixel-buffer producers should request an IOSurface and
  `kCVPixelBufferMetalCompatibilityKey: true`; a successful actual texture map,
  not merely the requested attribute, determines compatibility. This preflight
  is part of the measured detector call. It does not guarantee that every SDK
  internal allocation will succeed under later memory pressure.

## Apple YOLOv3 Tiny FP16

- Baseline versioned asset, retained for reproducibility:
  https://ml-assets.apple.com/coreml/models/Image/ObjectDetection/YOLOv3Tiny/YOLOv3TinyFP16.mlmodel
- Official catalog: https://developer.apple.com/machine-learning/models/
- Embedded model author: Joseph Redmon, Ali Farhadi.
- Embedded model version: `YOLOv3-tiny`; Apple's creator metadata version: `2.0`.
- Embedded license field: `Please see https://github.com/pjreddie/darknet for license information.`
- Preserved upstream texts: `DARKNET-LICENSE.txt` (public-domain statement),
  `DARKNET-META-LICENSE.txt` (license selection), `DARKNET-MIT-LICENSE.txt` (MIT,
  copyright 2017 Joseph Redmon). Sources retrieved 2026-10-16:
  https://github.com/pjreddie/darknet/blob/master/LICENSE
  https://github.com/pjreddie/darknet/blob/master/LICENSE.meta
  https://github.com/pjreddie/darknet/blob/master/LICENSE.mit
- `coremlcompiler` successfully compiled this asset. Its metadata reports minimum
  iOS 12, a 416x416 RGB image input, and a neural-network + NMS pipeline. The app
  targets iOS 15. Runtime operator placement and sustained performance still
  require the selected iPhone and OS to be tested.
- Add the `.mlmodel` to the app target so Xcode compiles a `.mlmodelc` resource.
  The adapter loads dynamically and does not need generated model classes.
- Core ML `.all` permits runtime placement on supported hardware; the UI calls
  it automatic acceleration and does not claim exclusive Neural Engine use.

## Coordinate and execution contract

Adapters take the physical BGRA pixel-buffer image with orientation `.up`.
They return boxes normalized to that same image, with a lower-left origin.
MediaPipe top-left pixel boxes are converted once; Vision already returns
normalized lower-left boxes. Camera orientation and preview mirroring belong
to the caller's display/control transform. Both adapters reject non-BGRA data
and non-increasing timestamps, and must be used on one serial inference queue.

MediaPipe uses synchronous video mode; the coordinator owns frame scheduling.
The quality Core ML All backend uses Vision `scaleFit` to preserve aspect ratio;
Core ML CPU and the baseline Tiny model retain `scaleFill`. Vision already maps
recognized-object boxes to the original image; no second padding correction is
applied. All Core ML variants use the shipped model's NMS. MediaPipe preprocessing,
box decoding and NMS follow the frozen SDK/model metadata. These differences
must remain visible in evaluation records. Retain these notices in distributed
artifacts alongside the existing dependency acknowledgements.
