import Foundation
import CoreGraphics
import Vision

@main
enum ScreenFollowDetectorComputeSmoke {
    static var assertions = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) {
        assertions += 1
        do {
            let passed = try value()
            precondition(passed, label)
        } catch { preconditionFailure("\(label): unexpected error \(error)") }
    }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return context.makeImage()!
    }

    static let face = ScreenFollowRect(x: 0.2, y: 0.3, width: 0.25, height: 0.25)
    static let injectedNEError = NSError(domain: "ScreenFollowComputeFixture.NE", code: 701)
    static let injectedCPUError = NSError(domain: "ScreenFollowComputeFixture.CPU", code: 702)

    static func policyNeverLeavesAnAutomaticOrGPUStage() {
        typealias Kind = ScreenFollowFaceDetector.DeviceKind
        let stages: [String: [Kind]] = [
            "prepare": [.cpu, .gpu, .neuralEngine],
            "main": [.gpu, .neuralEngine, .cpu],
            "finish": [.gpu, .cpu, .other]
        ]
        guard let plan = ScreenFollowFaceDetector.neuralEnginePlan(stages: stages, mainStage: "main") else {
            preconditionFailure("complete safe capabilities must produce a plan")
        }
        expect(plan.count == stages.count && Set(plan.keys) == Set(stages.keys),
               "every advertised compute stage receives an explicit device")
        expect(plan["main"] == .neuralEngine && plan["prepare"] == .cpu && plan["finish"] == .cpu,
               "the detector main stage uses NE and all auxiliary stages explicitly use CPU")
        expect(plan.values.allSatisfy { $0 == .cpu || $0 == .neuralEngine },
               "the plan never selects GPU, unknown devices or an automatic nil stage")

        let rejected: [(String, [String: [Kind]])] = [
            ("no stages", [:]),
            ("missing main", ["prepare": [.cpu, .neuralEngine]]),
            ("no neural engine", ["main": [.cpu, .gpu], "finish": [.cpu]]),
            ("main without CPU fallback", ["main": [.neuralEngine], "finish": [.cpu]]),
            ("GPU-only auxiliary", ["main": [.cpu, .neuralEngine], "finish": [.gpu]]),
            ("NE-only auxiliary", ["main": [.cpu, .neuralEngine], "finish": [.neuralEngine]]),
            ("unknown auxiliary", ["main": [.cpu, .neuralEngine], "finish": [.other]]),
            ("empty auxiliary", ["main": [.cpu, .neuralEngine], "finish": []])
        ]
        for (label, capabilities) in rejected {
            expect(ScreenFollowFaceDetector.neuralEnginePlan(stages: capabilities, mainStage: "main") == nil,
                   "\(label) rejects the entire NE plan instead of leaving a partial automatic/GPU configuration")
        }
        expect(ScreenFollowFaceDetector.neuralEnginePlan(stages: ["main": [.cpu, .neuralEngine]], mainStage: "main")?["main"] == .neuralEngine,
               "a single explicitly supported main stage is sufficient")
    }

    static func defaultAndDisabledRemainCPUOnly() throws {
        for explicitFalse in [false, true] {
            var configured = 0
            var requests: [VNDetectFaceRectanglesRequest] = []
            let configure: (VNDetectFaceRectanglesRequest) throws -> Bool = { _ in
                configured += 1
                throw injectedNEError
            }
            let execute: (VNDetectFaceRectanglesRequest, CGImage) throws -> [ScreenFollowRect] = { request, _ in
                requests.append(request)
                return [face]
            }
            let detector: ScreenFollowFaceDetector
            if explicitFalse {
                detector = ScreenFollowFaceDetector(prefersNeuralEngine: false,
                                                     configureNeuralEngine: configure, performRequest: execute)
            } else {
                detector = ScreenFollowFaceDetector(configureNeuralEngine: configure, performRequest: execute)
            }
            expect(requests.isEmpty && configured == 0, "initialization performs no detection or compute-device probing")
            expect(try detector.perform(image()) == [face], "disabled detector returns its CPU result")
            expect(try detector.perform(image()) == [face], "disabled detector remains usable on the next image")
            expect(configured == 0 && requests.count == 2 && requests.allSatisfy(\.usesCPUOnly),
                   "default false and explicit false never configure or execute NE")
            expect(requests.allSatisfy { $0.revision == VNDetectFaceRectanglesRequest.defaultRevision },
                   "CPU default preserves the existing face-detector revision")
        }
    }

    static func successfulNEPreservesTheResultAndRevision() throws {
        let frame = image()
        var configured: [VNDetectFaceRectanglesRequest] = []
        var performed: [VNDetectFaceRectanglesRequest] = []
        let detector = ScreenFollowFaceDetector(prefersNeuralEngine: true, configureNeuralEngine: { request in
            configured.append(request)
            return true
        }, performRequest: { request, actualImage in
            expect(actualImage === frame, "configured NE uses the exact image supplied by its caller")
            performed.append(request)
            return [face]
        })
        expect(try detector.perform(frame) == [face], "successful NE result is returned unchanged")
        expect(try detector.perform(frame) == [face], "successful NE can process a later call")
        expect(!configured.isEmpty && performed.count == 2 && performed.allSatisfy { !$0.usesCPUOnly },
               "successful explicit NE configuration does not execute a CPU retry")
        expect(performed.allSatisfy { $0.revision == VNDetectFaceRectanglesRequest.defaultRevision },
               "changing compute devices never changes the detector revision")
    }

    static func incompleteOrFailedConfigurationUsesFreshCPURequest() throws {
        for throwsConfiguration in [false, true] {
            let frame = image()
            var configured: [VNDetectFaceRectanglesRequest] = []
            var performed: [VNDetectFaceRectanglesRequest] = []
            let detector = ScreenFollowFaceDetector(prefersNeuralEngine: true, configureNeuralEngine: { request in
                configured.append(request)
                request.usesCPUOnly = false
                if throwsConfiguration { throw injectedNEError }
                return false
            }, performRequest: { request, actualImage in
                expect(actualImage === frame, "configuration fallback does not substitute a different image")
                performed.append(request)
                return [face]
            })
            expect(try detector.perform(frame) == [face], "unsupported or failed NE configuration falls back to CPU")
            expect(configured.count == 1 && performed.count == 1 && performed[0].usesCPUOnly,
                   "partial NE configuration is never executed")
            expect(performed[0] !== configured[0], "CPU fallback uses a fresh request without partial device configuration")
            expect(try detector.perform(frame) == [face], "configuration fallback remains usable")
            expect(configured.count == 1 && performed.allSatisfy(\.usesCPUOnly),
                   "unsupported or failed NE configuration remains CPU-only on subsequent frames")
        }
    }

    static func NEFailureRetriesSameImageOnceThenStaysCPU() throws {
        let frame = image()
        var configured = 0
        var performed: [VNDetectFaceRectanglesRequest] = []
        let detector = ScreenFollowFaceDetector(prefersNeuralEngine: true, configureNeuralEngine: { _ in
            configured += 1
            return true
        }, performRequest: { request, actualImage in
            expect(actualImage === frame, "NE error retries the same image, not the next captured frame")
            performed.append(request)
            if !request.usesCPUOnly { throw injectedNEError }
            return [face]
        })
        expect(try detector.perform(frame) == [face], "one CPU retry recovers an injected NE execution error")
        expect(configured == 1 && performed.count == 2 && !performed[0].usesCPUOnly && performed[1].usesCPUOnly,
               "failed NE execution is followed by exactly one CPU execution")
        expect(performed[0] !== performed[1], "CPU retry never reuses the failed NE request")
        expect(performed.allSatisfy { $0.revision == VNDetectFaceRectanglesRequest.defaultRevision },
               "fallback preserves the same detector revision")
        expect(try detector.perform(frame) == [face], "a subsequent detection succeeds after the fallback")
        expect(configured == 1 && performed.count == 3 && performed[2].usesCPUOnly,
               "subsequent frames do not retry the failed NE backend")
    }

    static func CPUFailuresPropagateWithoutAnUnboundedRetry() {
        for prefersNE in [false, true] {
            let frame = image()
            var configured = 0
            var performed: [VNDetectFaceRectanglesRequest] = []
            let detector = ScreenFollowFaceDetector(prefersNeuralEngine: prefersNE, configureNeuralEngine: { _ in
                configured += 1
                return true
            }, performRequest: { request, actualImage in
                expect(actualImage === frame, "failing backends operate on the original image")
                performed.append(request)
                throw request.usesCPUOnly ? injectedCPUError : injectedNEError
            })
            do {
                _ = try detector.perform(frame)
                preconditionFailure("CPU failure must propagate")
            } catch {
                let actual = error as NSError
                expect(actual.domain == injectedCPUError.domain && actual.code == injectedCPUError.code,
                       "CPU failure is propagated rather than hidden behind the earlier NE error")
            }
            expect(performed.count == (prefersNE ? 2 : 1) && configured == (prefersNE ? 1 : 0),
                   "CPU failure ends the call without another retry")
            do {
                _ = try detector.perform(frame)
                preconditionFailure("subsequent CPU failure must propagate")
            } catch {
                expect((error as NSError).code == injectedCPUError.code, "later CPU errors remain visible")
            }
            expect(performed.count == (prefersNE ? 3 : 2) && performed.last?.usesCPUOnly == true
                   && configured == (prefersNE ? 1 : 0),
                   "even a failed CPU fallback cannot re-enable NE on the next frame")
        }
    }

    static func main() throws {
        policyNeverLeavesAnAutomaticOrGPUStage()
        try defaultAndDisabledRemainCPUOnly()
        try successfulNEPreservesTheResultAndRevision()
        try incompleteOrFailedConfigurationUsesFreshCPURequest()
        try NEFailureRetriesSameImageOnceThenStaysCPU()
        CPUFailuresPropagateWithoutAnUnboundedRetry()
        print("screen_follow_detector_compute=passed assertions=\(assertions) computePolicy=explicitCPUAndNE gpu=forbidden execution=injected fallback=sameImageOnce default=CPU")
    }
}
