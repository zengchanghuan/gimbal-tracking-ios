#import "CMPhysicalObjectPatchTracker.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib3d.hpp>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <memory>
#include <vector>

static cv::Mat CMTrackingGray(CVPixelBufferRef pixels) {
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    cv::Mat gray;
    try {
        const int w = (int)CVPixelBufferGetWidth(pixels), h = (int)CVPixelBufferGetHeight(pixels);
        if (CVPixelBufferGetPlaneCount(pixels) > 0) {
            cv::Mat y(h, w, CV_8UC1, CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
                      CVPixelBufferGetBytesPerRowOfPlane(pixels, 0));
            cv::resize(y, gray, cv::Size(), std::min(1., 640. / std::max(w, h)),
                       std::min(1., 640. / std::max(w, h)), cv::INTER_AREA);
        } else if (CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA) {
            cv::Mat bgra(h, w, CV_8UC4, CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetBytesPerRow(pixels));
            cv::Mat small;
            const double s = std::min(1., 640. / std::max(w, h));
            cv::resize(bgra, small, cv::Size(), s, s, cv::INTER_AREA);
            cv::cvtColor(small, gray, cv::COLOR_BGRA2GRAY);
        }
    } catch (const cv::Exception &) { gray.release(); }
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    return gray;
}

/// Persistent local details seeded by Vision/patch agreement, then propagated
/// between accepted frames. Forward/backward matching and geometric consensus
/// preserve correspondences without freezing their old appearance. A briefly
/// unmatched point retains its last measured pixels, never predicted pixels.
/// Only Vision/patch agreement may introduce new points.
class CMTextureAnchors {
public:
    std::vector<cv::Point2f> positions, candidatePositions;
    std::vector<cv::Mat> references;
    std::vector<cv::Point> origins;
    std::vector<size_t> candidateIndices;
    std::vector<size_t> candidateOutliers;
    std::vector<bool> foregroundIdentities;
    cv::Point2d center;
    cv::Point2d velocity;
    cv::Size2d size;
    cv::Size imageSize;
    cv::Mat candidateTransform;
    CGRect candidateBox = CGRectNull;
    int matches = 0, inliers = 0, backwardRejected = 0, removedOutliers = 0;
    double meanScore = 0, meanError = 0;
    double spreadWidth = 0, spreadHeight = 0;
    bool motionFiltered = false, foregroundLocked = false;

    void initialize(const cv::Mat &image, cv::Point2d c, cv::Size2d s) {
        positions.clear(); candidatePositions.clear(); references.clear(); origins.clear();
        foregroundLocked = false;
        foregroundIdentities.clear(); velocity = cv::Point2d();
        center = c; size = s; imageSize = image.size();
        const cv::Rect interior(5, 5, image.cols - 10, image.rows - 10);
        cv::Rect roi((int)std::round(c.x - s.width * .35), (int)std::round(c.y - s.height * .35),
                     (int)std::round(s.width * .7), (int)std::round(s.height * .7));
        roi &= interior;
        if (roi.empty()) return;
        cv::Mat mask = cv::Mat::zeros(image.size(), CV_8U);
        mask(roi).setTo(255);
        std::vector<cv::Point2f> corners;
        cv::goodFeaturesToTrack(image, corners, 40, .02, 5, mask, 3);
        for (const auto &p : corners) {
            const cv::Point point((int)std::round(p.x), (int)std::round(p.y));
            if (!interior.contains(point)) continue;
            positions.emplace_back(point);
            cv::Rect context(point.x - 25, point.y - 25, 51, 51);
            context &= cv::Rect(0, 0, image.cols, image.rows);
            references.push_back(image(context).clone()); origins.push_back(point - context.tl());
            foregroundIdentities.push_back(false);
        }
    }

    static bool match(const cv::Mat &patch, const cv::Mat &image, cv::Point around,
                      cv::Point &location, double &score, cv::Point motion = cv::Point()) {
        // Cover both the last measured and predicted positions. A target that
        // suddenly stops must remain searchable, with one uniqueness test over
        // the complete window rather than competing unchecked fallbacks.
        cv::Rect window(around.x - 25 + std::min(0, motion.x), around.y - 25 + std::min(0, motion.y),
                        51 + std::abs(motion.x), 51 + std::abs(motion.y));
        window &= cv::Rect(0, 0, image.cols, image.rows);
        if (window.width < 11 || window.height < 11) return false;
        cv::Mat scores;
        cv::matchTemplate(image(window), patch, scores, cv::TM_CCOEFF_NORMED);
        double competitor; cv::Point peak;
        cv::minMaxLoc(scores, nullptr, &score, nullptr, &peak);
        cv::Rect suppressed(peak.x - 3, peak.y - 3, 7, 7);
        suppressed &= cv::Rect(0, 0, scores.cols, scores.rows);
        scores(suppressed).setTo(-1);
        cv::minMaxLoc(scores, nullptr, &competitor);
        if (!std::isfinite(score) || score < .85 || score - competitor < .1) return false;
        location = cv::Point(window.x + peak.x + 5, window.y + peak.y + 5);
        return true;
    }

    bool measure(const cv::Mat &image, CGRect referenceRect, float referenceConfidence) {
        matches = inliers = backwardRejected = removedOutliers = 0; meanScore = meanError = 0;
        candidatePositions.clear(); candidateIndices.clear();
        candidateOutliers.clear(); motionFiltered = false; spreadWidth = spreadHeight = 0;
        candidateBox = CGRectNull; candidateTransform.release();
        const int minimumPoints = foregroundLocked ? 6 : 8;
        if (positions.size() < minimumPoints || image.size() != imageSize) return false;
        std::vector<cv::Point2f> from, to;
        std::vector<double> qualities;
        std::vector<size_t> matchedIndices;
        for (size_t i = 0; i < positions.size(); ++i) {
            // Unmatched points keep their pixels, but cannot vote as foreground
            // unless they participated in the independently confirmed cluster.
            if (foregroundLocked && !foregroundIdentities[i]) continue;
            const cv::Point p((int)std::round(positions[i].x), (int)std::round(positions[i].y));
            const cv::Point origin = origins[i];
            const cv::Rect oldPatch(origin.x - 5, origin.y - 5, 11, 11);
            cv::Point next, returned; double score, backwardScore;
            // Last measured motion guides the SEARCH only. Output positions
            // still require unique forward/backward image correspondences.
            const cv::Point motion = foregroundLocked ? cv::Point((int)std::round(velocity.x), (int)std::round(velocity.y)) : cv::Point();
            if (!match(references[i](oldPatch), image, p, next, score, motion)) continue;
            const cv::Rect newPatch(next.x - 5, next.y - 5, 11, 11);
            if (!match(image(newPatch), references[i], origin, returned, backwardScore) ||
                cv::norm(returned - origin) > 1.5) { ++backwardRejected; continue; }
            from.push_back(positions[i]);
            to.emplace_back(next);
            qualities.push_back(score);
            matchedIndices.push_back(i);
        }
        matches = (int)from.size();
        if (matches < minimumPoints) return false;
        cv::Mat mask;
        cv::Mat transform = cv::estimateAffinePartial2D(from, to, mask, cv::RANSAC, 2, 1000, .99, 10);
        if (transform.empty() || !cv::checkRange(transform)) return false;
        std::vector<cv::Point2f> supported;
        for (size_t i = 0; i < from.size(); ++i) {
            if (!mask.at<uchar>((int)i)) continue;
            ++inliers; meanScore += qualities[i]; supported.push_back(from[i]);
            candidatePositions.push_back(to[i]);
            candidateIndices.push_back(matchedIndices[i]);
            const cv::Point2d predicted(
                transform.at<double>(0, 0) * from[i].x + transform.at<double>(0, 1) * from[i].y + transform.at<double>(0, 2),
                transform.at<double>(1, 0) * from[i].x + transform.at<double>(1, 1) * from[i].y + transform.at<double>(1, 2));
            meanError += cv::norm(predicted - cv::Point2d(to[i]));
        }
        if (inliers == 0) return false;
        meanScore /= inliers; meanError /= inliers;
        const cv::Rect spread = cv::boundingRect(supported);
        const double scale = std::hypot(transform.at<double>(0, 0), transform.at<double>(1, 0));
        const double angle = std::abs(std::atan2(transform.at<double>(1, 0), transform.at<double>(0, 0)));
        const double x = transform.at<double>(0, 0) * center.x + transform.at<double>(0, 1) * center.y + transform.at<double>(0, 2);
        const double y = transform.at<double>(1, 0) * center.x + transform.at<double>(1, 1) * center.y + transform.at<double>(1, 2);
        const CGRect measuredBox = CGRectMake((x - size.width * scale * .5) / image.cols,
            1 - (y + size.height * scale * .5) / image.rows, size.width * scale / image.cols, size.height * scale / image.rows);
        spreadWidth = spread.width / size.width; spreadHeight = spread.height / size.height;
        const bool normalConsensus = inliers >= matches * .7 && spreadWidth >= .3 && spreadHeight >= .3;
        const double wr = measuredBox.size.width / referenceRect.size.width;
        const double hr = measuredBox.size.height / referenceRect.size.height;
        const bool referenceSupports = std::isfinite(referenceConfidence) && referenceConfidence >= .5 &&
            std::isfinite(wr) && std::isfinite(hr) && wr >= (2. / 3.) && wr <= 1.5 && hr >= (2. / 3.) && hr <= 1.5 &&
            std::abs(CGRectGetMidX(measuredBox) - CGRectGetMidX(referenceRect)) <= std::max(measuredBox.size.width, referenceRect.size.width) * .2 &&
            std::abs(CGRectGetMidY(measuredBox) - CGRectGetMidY(referenceRect)) <= std::max(measuredBox.size.height, referenceRect.size.height) * .2;
        // Depth motion can separate real foreground points from background
        // points inside a loose selection. Require independent Vision agreement
        // before accepting that dominant, strong foreground motion cluster.
        const bool corroboratedCluster = referenceSupports && inliers >= 12 && inliers >= matches * .5 &&
            meanScore >= .9 && meanError <= .75 &&
            spread.width >= std::min(size.width, referenceRect.size.width * image.cols) * .3 &&
            spread.height >= std::min(size.height, referenceRect.size.height * image.rows) * .3;
        if (inliers < minimumPoints || (!normalConsensus && !corroboratedCluster) || meanScore < .88 || meanError > 1 ||
            scale < .8 || scale > 1.25 || angle > CV_PI / 12) return false;
        motionFiltered = !normalConsensus && corroboratedCluster;
        if (motionFiltered) {
            for (size_t i = 0; i < matchedIndices.size(); ++i)
                if (!mask.at<uchar>((int)i)) candidateOutliers.push_back(matchedIndices[i]);
        }
        candidateBox = measuredBox;
        candidateTransform = transform;
        return true;
    }

    void commit(const cv::Mat &image) {
        if (candidateTransform.empty()) return;
        // Predict search centers for unmatched points, but retain their old
        // image evidence. They cannot vote again until measured in both ways.
        cv::transform(positions, positions, candidateTransform);
        for (size_t j = 0; j < candidateIndices.size(); ++j) {
            const size_t i = candidateIndices[j];
            const cv::Point p((int)std::round(candidatePositions[j].x), (int)std::round(candidatePositions[j].y));
            cv::Rect context(p.x - 25, p.y - 25, 51, 51);
            context &= cv::Rect(0, 0, image.cols, image.rows);
            positions[i] = candidatePositions[j];
            references[i] = image(context).clone(); origins[i] = p - context.tl();
        }
        const cv::Point2d nextCenter(CGRectGetMidX(candidateBox) * image.cols, (1 - CGRectGetMidY(candidateBox)) * image.rows);
        velocity = nextCenter - center;
        center = nextCenter;
        size = cv::Size2d(candidateBox.size.width * image.cols, candidateBox.size.height * image.rows);
        if (motionFiltered) {
            for (size_t i : candidateIndices) foregroundIdentities[i] = true;
            // Remove only MEASURED points following a different motion. A
            // temporarily unmatched point still retains its old image evidence.
            for (auto it = candidateOutliers.rbegin(); it != candidateOutliers.rend(); ++it) {
                positions.erase(positions.begin() + *it);
                references.erase(references.begin() + *it);
                origins.erase(origins.begin() + *it);
                foregroundIdentities.erase(foregroundIdentities.begin() + *it);
            }
            foregroundLocked = true;
            removedOutliers = (int)candidateOutliers.size();
        }
    }
};

// Additional identity evidence for an ordinary texture with a colored detail.
// Only accepted tracking frames supply the reference; lost candidates never do.
struct CMCenterRecoveryColorEvidence {
    std::array<float, 24 * 8> histogram{};
    std::array<float, 4 * 4 * 24> layout{};
    double fraction = 0;
    bool valid = false;

    static CMCenterRecoveryColorEvidence read(const cv::Mat &hsv, cv::Rect crop) {
        CMCenterRecoveryColorEvidence result;
        if (hsv.empty() || crop.empty() || (crop & cv::Rect(0, 0, hsv.cols, hsv.rows)) != crop) return result;
        std::vector<int> columns(crop.width);
        for (int x = 0; x < crop.width; ++x) columns[x] = x * 4 / crop.width;
        int count = 0;
        for (int y = 0; y < crop.height; ++y) {
            const cv::Vec3b *row = hsv.ptr<cv::Vec3b>(crop.y + y) + crop.x;
            const int cellRow = y * 4 / crop.height;
            for (int x = 0; x < crop.width; ++x) {
                if (row[x][1] < 64 || row[x][2] < 35) continue;
                const int hue = row[x][0] * 24 / 180, saturation = row[x][1] * 8 / 256;
                ++result.histogram[hue * 8 + saturation];
                ++result.layout[(cellRow * 4 + columns[x]) * 24 + hue];
                ++count;
            }
        }
        result.fraction = (double)count / crop.area();
        result.valid = count >= 16 && result.fraction >= .08;
        if (count) {
            for (float &value : result.histogram) value /= count;
            for (float &value : result.layout) value /= count;
        }
        return result;
    }

    bool matches(const CMCenterRecoveryColorEvidence &candidate, double &histogramScore, double &layoutScore) const {
        histogramScore = layoutScore = 0;
        if (!valid || !candidate.valid || candidate.fraction < fraction * .5 || candidate.fraction > fraction * 2) return false;
        for (size_t i = 0; i < histogram.size(); ++i) histogramScore += std::min(histogram[i], candidate.histogram[i]);
        if (histogramScore < .85) return false;
        for (size_t i = 0; i < layout.size(); ++i) layoutScore += std::min(layout[i], candidate.layout[i]);
        return layoutScore >= .75;
    }
};

class CMPatchMatcher {
public:
    cv::Mat _patch;
    cv::Size _peakSize;
    cv::Size _imageSize;
    cv::Size2d _selectionSize;
    cv::Point2d _center;
    cv::Point2d _patchOffset;
    double _scale;
    std::vector<float> _referenceConfidences;
    NSUInteger _templateUpdates = 0;
    NSUInteger _observations = 0;
    double _scoreThreshold = .8, _marginThreshold = .05;
    bool _allowRefresh = true;
    CMTextureAnchors _anchors;
    int _featureAgreements = 0;
    bool _featureMeasurementLocked = false;
    cv::Mat _centerRecoveryPatch;
    double _centerRecoveryScale = 0;
    cv::Point2d _centerRecoveryCandidate;
    double _centerRecoveryCandidateScale = 0;
    NSUInteger _centerRecoveryObservation = 0;
    int _centerRecoveryConfirmations = 0;
    CMCenterRecoveryColorEvidence _lastAcceptedRecoveryColor, _centerRecoveryColor;

    void cacheCenterRecoveryColor(const cv::Mat &hsv) {
        _lastAcceptedRecoveryColor = CMCenterRecoveryColorEvidence();
        if (!_allowRefresh || _featureMeasurementLocked || _anchors.foregroundLocked) return;
        const cv::Size size((int)std::round(_patch.cols * _scale), (int)std::round(_patch.rows * _scale));
        const cv::Point2d center = _center + _patchOffset * _scale;
        const cv::Rect crop((int)std::round(center.x - size.width * .5),
                            (int)std::round(center.y - size.height * .5), size.width, size.height);
        _lastAcceptedRecoveryColor = CMCenterRecoveryColorEvidence::read(hsv, crop);
    }

    bool usesCenterRecoveryColor() const {
        return _centerRecoveryPatch.empty() ? _lastAcceptedRecoveryColor.valid : _centerRecoveryColor.valid;
    }

    void clearCenterRecovery() {
        _centerRecoveryPatch.release();
        _centerRecoveryScale = 0;
        _centerRecoveryConfirmations = 0;
        _centerRecoveryObservation = 0;
        _centerRecoveryColor = CMCenterRecoveryColorEvidence();
    }

    // This is a separate evidence path, never a relaxed normal-track gate.
    // Freeze the last accepted appearance and scale throughout a missing span.
    // Searching a new position cannot train the template or move its center
    // until three distinct observations independently identify the same peak.
    NSDictionary<NSString *, id> *recoverCenter(const cv::Mat &image, const cv::Mat &hsv = cv::Mat()) {
        if (!_allowRefresh || _featureMeasurementLocked || _anchors.foregroundLocked)
            return @{ @"accepted": @NO, @"reason": @"center_recovery_unsupported" };
        if (image.empty() || image.size() != _imageSize) {
            _centerRecoveryConfirmations = 0;
            return @{ @"accepted": @NO, @"reason": @"center_recovery_geometry" };
        }
        if (_centerRecoveryObservation == _observations)
            return @{ @"accepted": @NO, @"reason": @"center_recovery_duplicate_observation",
                      @"recovery_confirmations": @(_centerRecoveryConfirmations) };
        const bool consecutive = _centerRecoveryObservation + 1 == _observations;
        _centerRecoveryObservation = _observations;
        if (_centerRecoveryPatch.empty()) {
            _centerRecoveryPatch = _patch.clone();
            _centerRecoveryScale = _scale;
            _centerRecoveryColor = _lastAcceptedRecoveryColor;
        }
        try {
            const auto started = std::chrono::steady_clock::now();
            const bool useColor = _centerRecoveryColor.valid;
            if (useColor && (hsv.empty() || hsv.size() != image.size())) {
                _centerRecoveryConfirmations = 0;
                return @{ @"accepted": @NO, @"reason": @"center_recovery_color_unavailable" };
            }
            cv::Mat colorfulIntegral;
            if (useColor) {
                cv::Mat colorful(image.size(), CV_8U);
                for (int y = 0; y < hsv.rows; ++y) {
                    const cv::Vec3b *source = hsv.ptr<cv::Vec3b>(y);
                    uchar *destination = colorful.ptr<uchar>(y);
                    for (int x = 0; x < hsv.cols; ++x) destination[x] = source[x][1] >= 64 && source[x][2] >= 35;
                }
                cv::integral(colorful, colorfulIntegral, CV_32S);
            }
            int colorChecks = 0;
            int64_t colorPixels = 0;
            bool budgetExceeded = false;
            auto withinBudget = [&]() {
                if (std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count() > 120)
                    budgetExceeded = true;
                return !budgetExceeded;
            };
            auto matchesColor = [&](cv::Point location, cv::Size size, double &histogramScore, double &layoutScore) {
                const int left = location.x, top = location.y, right = left + size.width, bottom = top + size.height;
                const int count = colorfulIntegral.at<int>(bottom, right) - colorfulIntegral.at<int>(top, right) -
                    colorfulIntegral.at<int>(bottom, left) + colorfulIntegral.at<int>(top, left);
                const double fraction = (double)count / size.area();
                if (fraction < .08 || fraction < _centerRecoveryColor.fraction * .5 || fraction > _centerRecoveryColor.fraction * 2) return false;
                colorPixels += size.area();
                if (++colorChecks > 8192 || colorPixels > 32000000 || !withinBudget()) { budgetExceeded = true; return false; }
                return _centerRecoveryColor.matches(CMCenterRecoveryColorEvidence::read(hsv, cv::Rect(location, size)), histogramScore, layoutScore);
            };
            const double factors[] = {1., .85, .90, .95, 1.05, 1.10, 1.18};
            if (useColor) {
                // Most missing frames have no eligible central candidate. Test
                // only the image pixels needed for those response positions
                // before paying for the full-image uniqueness search. This
                // preflight never accepts a match or advances confirmation.
                bool possibleCandidate = false;
                for (double factor : factors) {
                    if (possibleCandidate || !withinBudget()) break;
                    const double scale = _centerRecoveryScale * factor;
                    if (scale < .4 || scale > 2.5) continue;
                    const cv::Size size((int)std::round(_centerRecoveryPatch.cols * scale),
                                        (int)std::round(_centerRecoveryPatch.rows * scale));
                    if (size.width < 4 || size.height < 4 || size.width > image.cols || size.height > image.rows) continue;
                    const cv::Point2d offset = _patchOffset * scale - cv::Point2d(size.width * .5, size.height * .5);
                    const int x = (int)std::ceil(image.cols * .25 + offset.x);
                    const int y = (int)std::ceil(image.rows * .25 + offset.y);
                    cv::Rect central(x, y, (int)std::floor(image.cols * .75 + offset.x) - x + 1,
                                          (int)std::floor(image.rows * .75 + offset.y) - y + 1);
                    central &= cv::Rect(0, 0, image.cols - size.width + 1, image.rows - size.height + 1);
                    if (central.empty()) continue;
                    // A response at (x,y) consumes [x,x+w) x [y,y+h).
                    // This crop therefore returns exactly the central response
                    // rectangle, with its origin restored below for HSV reads.
                    const cv::Rect input(central.x, central.y,
                        central.width + size.width - 1, central.height + size.height - 1);
                    cv::Mat patch, scores;
                    cv::resize(_centerRecoveryPatch, patch, size, 0, 0, cv::INTER_LINEAR);
                    cv::matchTemplate(image(input), patch, scores, cv::TM_CCOEFF_NORMED);
                    for (int rowIndex = 0; rowIndex < scores.rows && !possibleCandidate && withinBudget(); ++rowIndex) {
                        const float *row = scores.ptr<float>(rowIndex);
                        for (int column = 0; column < scores.cols && !possibleCandidate && !budgetExceeded; ++column) {
                            const double score = row[column];
                            // Cropped and full OpenCV response maps can differ
                            // by floating-point rounding. Borderline results
                            // must reach the unchanged full-image .90 gate.
                            if (!std::isfinite(score) || score < .90 - 1e-4) continue;
                            const cv::Point location = central.tl() + cv::Point(column, rowIndex);
                            const cv::Point2d candidate = cv::Point2d(location.x, location.y) - offset;
                            const double width = _selectionSize.width * scale, height = _selectionSize.height * scale;
                            const double left = candidate.x - width * .5, top = candidate.y - height * .5;
                            const double visibleWidth = std::max(0., std::min((double)image.cols, left + width) - std::max(0., left));
                            const double visibleHeight = std::max(0., std::min((double)image.rows, top + height) - std::max(0., top));
                            const double areaRatio = scale * scale / (_centerRecoveryScale * _centerRecoveryScale);
                            if (areaRatio < .5 || areaRatio > 2 || visibleWidth * visibleHeight < width * height * .85) continue;
                            double histogram = -1, layout = -1;
                            possibleCandidate = matchesColor(location, size, histogram, layout);
                        }
                    }
                }
                if (!withinBudget()) {
                    _centerRecoveryConfirmations = 0;
                    return @{ @"accepted": @NO, @"reason": @"center_recovery_budget", @"recovery_color_checks": @(colorChecks) };
                }
                if (!possibleCandidate) {
                    _centerRecoveryConfirmations = 0;
                    return @{ @"accepted": @NO, @"reason": @"center_recovery_no_candidate" };
                }
            }
            struct Response { cv::Mat scores; cv::Size size; double scale; };
            std::vector<Response> responses;
            double best = -1, second = -1, bestScale = _centerRecoveryScale;
            cv::Point2d bestCenter;
            double bestColorHistogram = -1, bestColorLayout = -1;
            // Bounded scale variation around the last trusted size. Full-image
            // response maps retain competitors outside the central return area.
            for (double factor : factors) {
                if (!withinBudget()) break;
                const double scale = _centerRecoveryScale * factor;
                if (scale < .4 || scale > 2.5) continue;
                cv::Size size((int)std::round(_centerRecoveryPatch.cols * scale),
                              (int)std::round(_centerRecoveryPatch.rows * scale));
                if (size.width < 4 || size.height < 4 || size.width > image.cols || size.height > image.rows) continue;
                cv::Mat patch, scores;
                cv::resize(_centerRecoveryPatch, patch, size, 0, 0, cv::INTER_LINEAR);
                cv::matchTemplate(image, patch, scores, cv::TM_CCOEFF_NORMED);
                const cv::Point2d offset = _patchOffset * scale - cv::Point2d(size.width * .5, size.height * .5);
                const int x = (int)std::ceil(image.cols * .25 + offset.x);
                const int y = (int)std::ceil(image.rows * .25 + offset.y);
                cv::Rect central(x, y, (int)std::floor(image.cols * .75 + offset.x) - x + 1,
                                      (int)std::floor(image.rows * .75 + offset.y) - y + 1);
                central &= cv::Rect(0, 0, scores.cols, scores.rows);
                if (!central.empty()) {
                    auto consider = [&](double score, cv::Point location) {
                        if (!std::isfinite(score) || score <= best || (useColor && score < .90)) return;
                        const cv::Point2d candidate = cv::Point2d(location.x, location.y) - offset;
                        const double width = _selectionSize.width * scale, height = _selectionSize.height * scale;
                        const double left = candidate.x - width * .5, top = candidate.y - height * .5;
                        const double visibleWidth = std::max(0., std::min((double)image.cols, left + width) - std::max(0., left));
                        const double visibleHeight = std::max(0., std::min((double)image.rows, top + height) - std::max(0., top));
                        const double areaRatio = scale * scale / (_centerRecoveryScale * _centerRecoveryScale);
                        if (areaRatio < .5 || areaRatio > 2 || visibleWidth * visibleHeight < width * height * .85) return;
                        double histogram = -1, layout = -1;
                        if (useColor && !matchesColor(location, size, histogram, layout)) return;
                        best = score; bestScale = scale; bestCenter = candidate;
                        bestColorHistogram = histogram; bestColorLayout = layout;
                    };
                    if (useColor) {
                        // A color-incompatible high grayscale peak must not
                        // hide a lower, still-strong central identity match.
                        for (int y = central.y; y < central.y + central.height && withinBudget(); ++y) {
                            const float *row = scores.ptr<float>(y);
                            for (int x = central.x; x < central.x + central.width && !budgetExceeded; ++x)
                                consider(row[x], cv::Point(x, y));
                        }
                    } else {
                        double score; cv::Point location;
                        cv::minMaxLoc(scores(central), nullptr, &score, nullptr, &location);
                        consider(score, location + central.tl());
                    }
                }
                responses.push_back({scores, size, scale});
            }
            if (!withinBudget()) {
                _centerRecoveryConfirmations = 0;
                return @{ @"accepted": @NO, @"reason": @"center_recovery_budget", @"recovery_color_checks": @(colorChecks) };
            }
            if (best < 0) {
                _centerRecoveryConfirmations = 0;
                return @{ @"accepted": @NO, @"reason": @"center_recovery_no_candidate" };
            }
            for (auto &response : responses) {
                if (!withinBudget()) break;
                const cv::Point2d p = bestCenter + _patchOffset * response.scale -
                    cv::Point2d(response.size.width * .5, response.size.height * .5);
                const double rx = std::max(6., _peakSize.width * bestScale * .5);
                const double ry = std::max(6., _peakSize.height * bestScale * .25);
                const int x = (int)std::ceil(p.x - rx), y = (int)std::ceil(p.y - ry);
                cv::Rect suppressed(x, y, std::max(0, (int)std::floor(p.x + rx) - x + 1),
                                          std::max(0, (int)std::floor(p.y + ry) - y + 1));
                suppressed &= cv::Rect(0, 0, response.scores.cols, response.scores.rows);
                if (!suppressed.empty()) response.scores(suppressed).setTo(-1);
                if (useColor) {
                    // Check EVERY potentially disqualifying position across
                    // the full image and every scale, including outside center.
                    // Scores below best-.12 provably cannot violate the margin.
                    for (int y = 0; y < response.scores.rows && withinBudget(); ++y) {
                        const float *row = response.scores.ptr<float>(y);
                        for (int x = 0; x < response.scores.cols && !budgetExceeded; ++x) {
                            const double score = row[x];
                            if (!std::isfinite(score) || score < best - .12 || score <= second) continue;
                            double histogram = -1, layout = -1;
                            if (matchesColor(cv::Point(x, y), response.size, histogram, layout)) second = score;
                        }
                    }
                } else {
                    double competitor;
                    cv::minMaxLoc(response.scores, nullptr, &competitor);
                    if (std::isfinite(competitor)) second = std::max(second, competitor);
                }
            }
            if (!withinBudget()) {
                _centerRecoveryConfirmations = 0;
                return @{ @"accepted": @NO, @"reason": @"center_recovery_budget", @"recovery_color_checks": @(colorChecks) };
            }
            // With color verification this is a conservative lower bound when
            // no compatible competitor reaches the required margin boundary.
            const double margin = useColor && second < best - .12 ? .12 : best - second;
            const bool strong = best >= .90 && margin >= .12;
            const double consistencyDistance = std::max(4., std::min(_selectionSize.width, _selectionSize.height) * bestScale * .2);
            const double scaleRatio = _centerRecoveryCandidateScale > 0 ? bestScale / _centerRecoveryCandidateScale : 0;
            const bool consistent = consecutive && _centerRecoveryConfirmations > 0 &&
                cv::norm(bestCenter - _centerRecoveryCandidate) <= consistencyDistance && scaleRatio >= .90 && scaleRatio <= 1.10;
            _centerRecoveryConfirmations = strong ? (consistent ? _centerRecoveryConfirmations + 1 : 1) : 0;
            _centerRecoveryCandidate = bestCenter;
            _centerRecoveryCandidateScale = bestScale;
            const bool accepted = _centerRecoveryConfirmations >= 3;
            const double width = _selectionSize.width * bestScale, height = _selectionSize.height * bestScale;
            NSString *reason = accepted ? @"center_recovery_matched" : (strong ? @"center_recovery_confirming" :
                (best < .90 ? @"center_recovery_correlation" : @"center_recovery_ambiguous"));
            NSMutableDictionary *result = [@{ @"accepted": @(accepted), @"reason": reason,
                @"score": @(best), @"margin": @(margin), @"scale": @(bestScale),
                @"recovery_confirmations": @(_centerRecoveryConfirmations),
                @"recovery_color_verified": @(useColor), @"recovery_color_checks": @(colorChecks),
                @"recovery_color_histogram": @(bestColorHistogram), @"recovery_color_layout": @(bestColorLayout),
                @"recovery_color_fraction": @(_centerRecoveryColor.fraction),
                @"recovery_margin_is_lower_bound": @(useColor && second < best - .12),
                @"template_refreshed": @NO, @"template_updates": @(_templateUpdates),
                @"measurement_source": @"frozen_texture_center_recovery",
                @"bbox": @[@((bestCenter.x - width * .5) / image.cols),
                            @(1 - (bestCenter.y + height * .5) / image.rows),
                            @(width / image.cols), @(height / image.rows)] } mutableCopy];
            if (accepted) {
                _center = bestCenter; _scale = bestScale;
                _referenceConfidences.clear(); _featureAgreements = 0;
                _anchors = CMTextureAnchors();
                result[@"recovered_original_template"] = @YES;
                clearCenterRecovery();
            }
            return result;
        } catch (const cv::Exception &) {
            _centerRecoveryConfirmations = 0;
            return @{ @"accepted": @NO, @"reason": @"center_recovery_opencv_error" };
        }
    }

    // Once independently separated from background motion, keep following the
    // same measured feature identities. Missing features hold; they never
    // silently fall back to the background patch or introduce new points.
    NSDictionary<NSString *, id> *featureMeasurement(const cv::Mat &image, bool valid,
                                                    CGRect reference, float confidence) {
        const CGRect box = _anchors.candidateBox;
        const double scale = box.size.width * image.cols / _selectionSize.width;
        const double dx = std::abs(CGRectGetMidX(box) * image.cols - _center.x) / image.cols;
        const double dy = std::abs((1 - CGRectGetMidY(box)) * image.rows - _center.y) / image.rows;
        const double maxDX = std::max(.04, _selectionSize.width * _scale / image.cols * .5);
        const double maxDY = std::max(.04, _selectionSize.height * _scale / image.rows * .5);
        const CGRect intersection = CGRectIntersection(box, reference);
        const double overlap = CGRectIsNull(intersection) ? 0 : intersection.size.width * intersection.size.height;
        const double boxArea = box.size.width * box.size.height;
        const double referenceArea = reference.size.width * reference.size.height;
        const bool referenceSupports = std::isfinite(confidence) && (confidence < .6 ||
            (std::isfinite(referenceArea) && referenceArea > 0 &&
             (overlap / (boxArea + referenceArea - overlap) >= .5 ||
              (overlap / referenceArea >= .9 && reference.size.width >= box.size.width / 3 &&
               reference.size.height >= box.size.height / 3 &&
               std::abs(CGRectGetMidX(reference) - CGRectGetMidX(box)) <= box.size.width * .3 &&
               std::abs(CGRectGetMidY(reference) - CGRectGetMidY(box)) <= box.size.height * .3))));
        NSMutableArray<NSString *> *rejections = [NSMutableArray array];
        if (!valid || _anchors.inliers < 6 || _anchors.inliers < _anchors.matches * .8 ||
            _anchors.meanScore < .9 || _anchors.meanError > .75) [rejections addObject:@"feature_evidence"];
        if (!referenceSupports) [rejections addObject:@"feature_reference_conflict"];
        if (!std::isfinite(scale) || scale < .4 || scale > 2.5) [rejections addObject:@"feature_scale"];
        if (!std::isfinite(dx) || !std::isfinite(dy) || dx > maxDX || dy > maxDY)
            [rejections addObject:@"feature_displacement"];
        const bool accepted = rejections.count == 0;
        if (accepted) {
            _anchors.commit(image);
            _center = _anchors.center; _scale = scale;
        }
        return @{ @"accepted": @(accepted), @"measurement_source": @"foreground_features",
                  @"reason": accepted ? @"matched_features" : [rejections componentsJoinedByString:@","],
                  @"rejections": rejections, @"score": @(_anchors.meanScore), @"margin": @(-1),
                  @"appearance_measured": @NO, @"appearance_score": @(-1), @"appearance_accepted": @NO,
                  @"template_refreshed": @NO, @"template_updates": @(_templateUpdates),
                  @"feature_measurement_locked": @YES, @"feature_reference_agrees": @(referenceSupports),
                  @"anchor_count": @(_anchors.positions.size()), @"anchor_matches": @(_anchors.matches),
                  @"anchor_inliers": @(_anchors.inliers), @"anchor_mean_score": @(_anchors.meanScore),
                  @"anchor_mean_error_px": @(_anchors.meanError), @"anchor_backward_rejected": @(_anchors.backwardRejected),
                  @"anchor_foreground_locked": @(_anchors.foregroundLocked), @"anchor_motion_filtered": @(_anchors.motionFiltered),
                  @"anchor_removed_outliers": @(_anchors.removedOutliers),
                  @"anchor_spread_width": @(_anchors.spreadWidth), @"anchor_spread_height": @(_anchors.spreadHeight),
                  @"dx": @(std::isfinite(dx) ? dx : -1), @"dy": @(std::isfinite(dy) ? dy : -1),
                  @"max_dx": @(maxDX), @"max_dy": @(maxDY), @"scale": @(std::isfinite(scale) ? scale : -1),
                  @"bbox": CGRectIsNull(box) ? @[] : @[@(box.origin.x), @(box.origin.y), @(box.size.width), @(box.size.height)] };
    }
    bool initialize(const cv::Mat &image, CGRect selection, double fraction = .7, bool appearance = true) {
        _allowRefresh = appearance;
        if (!appearance) { _scoreThreshold = .72; _marginThreshold = .15; }
    try {
        if (image.empty() || !std::isfinite(selection.origin.x) || !std::isfinite(selection.origin.y) ||
            !std::isfinite(selection.size.width) || !std::isfinite(selection.size.height) ||
            selection.size.width <= 0 || selection.size.height <= 0) return false;
        _imageSize = image.size();
        _selectionSize = cv::Size2d(selection.size.width * image.cols, selection.size.height * image.rows);
        _center = cv::Point2d(CGRectGetMidX(selection) * image.cols, (1 - CGRectGetMidY(selection)) * image.rows);
        // Inner texture reduces unrelated background at a loose manual box edge.
        cv::Rect crop((int)std::round(_center.x - _selectionSize.width * fraction * .5),
                      (int)std::round(_center.y - _selectionSize.height * fraction * .5),
                      (int)std::round(_selectionSize.width * fraction), (int)std::round(_selectionSize.height * fraction));
        if (crop.width < 8 || crop.height < 8 || (crop & cv::Rect(0, 0, image.cols, image.rows)) != crop) return false;
        _patch = image(crop).clone();
        _peakSize = _allowRefresh ? _patch.size() : cv::boundingRect(_patch).size();
        cv::Scalar mean, deviation;
        cv::meanStdDev(_patch, mean, deviation);
        if (deviation[0] < 12) return false;
        _patchOffset = cv::Point2d(crop.x + crop.width * .5, crop.y + crop.height * .5) - _center;
        _scale = 1;
    } catch (const cv::Exception &) { return false; }
    return true;
}
    NSDictionary<NSString *, id> *track(const cv::Mat &image, CGRect referenceRect = CGRectNull, float referenceConfidence = 0) {
    try {
        if (image.empty() || image.size() != _imageSize) return @{ @"accepted": @NO, @"reason": @"geometry" };
        ++_observations;
        if (_featureMeasurementLocked) {
            const bool valid = _anchors.measure(image, referenceRect, referenceConfidence);
            return featureMeasurement(image, valid, referenceRect, referenceConfidence);
        }
        double mx = std::max(50., _selectionSize.width * _scale * .8);
        double my = std::max(50., _selectionSize.height * _scale * .8);
        cv::Rect window((int)std::floor(_center.x - mx), (int)std::floor(_center.y - my),
                        (int)std::ceil(2 * mx), (int)std::ceil(2 * my));
        window &= cv::Rect(0, 0, image.cols, image.rows);
        if (window.empty()) return @{ @"accepted": @NO, @"reason": @"outside" };
        double best = -1, bestScale = 1, second = -1;
        cv::Point2d bestCenter;
        // A verified Vision observation supplies an independent geometric
        // sample. Appearance updates must not silently absorb zoom while the
        // displayed box remains at its previous size.
        const bool trustedReferenceHistory = _allowRefresh && _referenceConfidences.size() == 3 &&
            *std::min_element(_referenceConfidences.begin(), _referenceConfidences.end()) >= .65 &&
            (_referenceConfidences[0] + _referenceConfidences[1] + _referenceConfidences[2]) / 3 >= .75;
        const double referenceScale = referenceRect.size.width * image.cols / _selectionSize.width;
        const double referenceHeightScale = referenceRect.size.height * image.rows / _selectionSize.height;
        const bool usableReferenceScale = trustedReferenceHistory && std::isfinite(referenceConfidence) && referenceConfidence >= .85 &&
            std::isfinite(referenceScale) && std::isfinite(referenceHeightScale) &&
            std::isfinite(referenceRect.origin.x) && std::isfinite(referenceRect.origin.y) &&
            CGRectGetMidX(referenceRect) >= 0 && CGRectGetMidX(referenceRect) <= 1 &&
            CGRectGetMidY(referenceRect) >= 0 && CGRectGetMidY(referenceRect) <= 1 &&
            referenceScale >= _scale * .85 && referenceScale <= _scale * 1.18 &&
            referenceHeightScale / referenceScale >= .95 && referenceHeightScale / referenceScale <= 1.05;
        bool referenceScaleSelected = false;
        struct Response { cv::Mat scores; cv::Size size; double scale; };
        std::vector<Response> responses;
        // Always test the unchanged size first. The old 17-point grid omitted
        // 1.0, forcing resampling/size drift even on a perfectly static target.
        for (int i = -1; i < 18; ++i) {
            if (i == 17 && !usableReferenceScale) continue;
            double scale = i == 17 ? referenceScale : (i == -1 ? _scale : _scale * (.85 + .33 * i / 16.));
            if (scale < .4 || scale > 2.5) continue;
            cv::Size size((int)std::round(_patch.cols * scale), (int)std::round(_patch.rows * scale));
            if (size.width < 4 || size.height < 4 || size.width > window.width || size.height > window.height) continue;
            cv::Mat patch, scores;
            cv::resize(_patch, patch, size, 0, 0, cv::INTER_LINEAR);
            cv::matchTemplate(image(window), patch, scores, cv::TM_CCOEFF_NORMED);
            double score; cv::Point location;
            cv::Rect peakWindow(0, 0, scores.cols, scores.rows);
            if (i == 17) {
                const cv::Point2d expected(CGRectGetMidX(referenceRect) * image.cols,
                    (1 - CGRectGetMidY(referenceRect)) * image.rows);
                const cv::Point2d origin = expected + _patchOffset * scale -
                    cv::Point2d(window.x + size.width * .5, window.y + size.height * .5);
                peakWindow &= cv::Rect((int)std::round(origin.x) - 2, (int)std::round(origin.y) - 2, 5, 5);
            }
            if (peakWindow.empty()) continue;
            cv::minMaxLoc(scores(peakWindow), nullptr, &score, nullptr, &location);
            location += peakWindow.tl();
            const cv::Point2d candidateCenter = cv::Point2d(window.x + location.x + size.width * .5,
                window.y + location.y + size.height * .5) - _patchOffset * scale;
            const bool samePeak = std::abs(candidateCenter.x - bestCenter.x) <= std::max(2., _selectionSize.width * _scale * .1) &&
                std::abs(candidateCenter.y - bestCenter.y) <= std::max(2., _selectionSize.height * _scale * .1);
            // Require actual strong texture at the proposed size and position.
            // Keep the FULL response map below for competing-target rejection.
            if (std::isfinite(score) && ((i != 17 && score > best) || (i == 17 && score >= .9 && samePeak))) {
                best = score; bestScale = scale;
                bestCenter = candidateCenter;
                referenceScaleSelected = i == 17;
            }
            responses.push_back({scores, size, scale});
        }
        // A competing spatial peak at ANY tested scale must be clearly worse.
        for (auto &response : responses) {
            cv::Mat &scores = response.scores;
            const cv::Point2d p = bestCenter + _patchOffset * response.scale -
                cv::Point2d(window.x + response.size.width * .5, window.y + response.size.height * .5);
            const double rx = std::max(6., _peakSize.width * bestScale * .5), ry = std::max(6., _peakSize.height * bestScale * .25);
            const int x = (int)std::ceil(p.x - rx), y = (int)std::ceil(p.y - ry);
            cv::Rect suppressed(x, y, std::max(0, (int)std::floor(p.x + rx) - x + 1),
                                std::max(0, (int)std::floor(p.y + ry) - y + 1));
            suppressed &= cv::Rect(0, 0, scores.cols, scores.rows);
            if (!suppressed.empty()) scores(suppressed).setTo(-1);
            double competitor;
            cv::minMaxLoc(scores, nullptr, &competitor);
            if (std::isfinite(competitor)) second = std::max(second, competitor);
        }
        const double width = _selectionSize.width * bestScale, height = _selectionSize.height * bestScale;
        CGRect box = CGRectMake((bestCenter.x - width * .5) / image.cols,
                                1 - (bestCenter.y + height * .5) / image.rows, width / image.cols, height / image.rows);
        const double dx = std::abs(bestCenter.x - _center.x) / image.cols;
        const double dy = std::abs(bestCenter.y - _center.y) / image.rows;
        const double maxDX = std::max(.04, _selectionSize.width * _scale / image.cols * .5);
        const double maxDY = std::max(.04, _selectionSize.height * _scale / image.rows * .5);
        const bool accepted = best >= _scoreThreshold && best - second >= _marginThreshold && dx <= maxDX && dy <= maxDY;
        // Preserve every failed gate: a strong peak outside continuity bounds is
        // different from an appearance mismatch or a competing background peak.
        NSMutableArray<NSString *> *rejections = [NSMutableArray array];
        if (best < _scoreThreshold) [rejections addObject:@"correlation"];
        if (best - second < _marginThreshold) [rejections addObject:@"ambiguous_peak"];
        if (dx > maxDX) [rejections addObject:@"horizontal_displacement"];
        if (dy > maxDY) [rejections addObject:@"vertical_displacement"];
        bool referenceAgrees = false, referenceOverlaps = false, referenceIsContainedDetail = false;
        if (std::isfinite(referenceConfidence) && referenceConfidence >= .5 &&
            std::isfinite(referenceRect.origin.x) && std::isfinite(referenceRect.origin.y) &&
            std::isfinite(referenceRect.size.width) && std::isfinite(referenceRect.size.height) &&
            referenceRect.size.width > 0 && referenceRect.size.height > 0) {
            const double wr = box.size.width / referenceRect.size.width;
            const double hr = box.size.height / referenceRect.size.height;
            const CGRect intersection = CGRectIntersection(box, referenceRect);
            const double unionArea = box.size.width * box.size.height +
                referenceRect.size.width * referenceRect.size.height -
                (CGRectIsNull(intersection) ? 0 : intersection.size.width * intersection.size.height);
            referenceOverlaps = !CGRectIsNull(intersection) && unionArea > 0 &&
                intersection.size.width * intersection.size.height / unionArea >= .5;
            // Vision may narrow onto a stable detail as distance changes. A
            // substantial, central sub-box is not a conflicting target. This
            // only removes a veto on existing features; it cannot seed points
            // or independently authorize learning from that smaller region.
            referenceIsContainedDetail = !CGRectIsNull(intersection) &&
                wr >= 1 && wr <= 3 && hr >= 1 && hr <= 3 &&
                intersection.size.width * intersection.size.height /
                    (referenceRect.size.width * referenceRect.size.height) >= .9 &&
                std::abs(CGRectGetMidX(box) - CGRectGetMidX(referenceRect)) <= box.size.width * .3 &&
                std::abs(CGRectGetMidY(box) - CGRectGetMidY(referenceRect)) <= box.size.height * .3;
            referenceAgrees = wr >= (2. / 3.) && wr <= 1.5 && hr >= (2. / 3.) && hr <= 1.5 &&
                std::abs(CGRectGetMidX(box) - CGRectGetMidX(referenceRect)) <= std::max(box.size.width, referenceRect.size.width) * .2 &&
                std::abs(CGRectGetMidY(box) - CGRectGetMidY(referenceRect)) <= std::max(box.size.height, referenceRect.size.height) * .2;
        }
        if (accepted && referenceAgrees) {
            _referenceConfidences.push_back(referenceConfidence);
            if (_referenceConfidences.size() > 3) _referenceConfidences.erase(_referenceConfidences.begin());
        } else {
            _referenceConfidences.clear();
        }
        // Same three-frame, minimum .5 / mean .6 reference evidence used by
        // physical-follow recovery; this alone does not authorize a refresh.
        const bool referenceConfirmed = _referenceConfidences.size() == 3 &&
            (_referenceConfidences[0] + _referenceConfidences[1] + _referenceConfidences[2]) / 3 >= .6;
        // Depth motion separates foreground and background feature motion in
        // a loose box. A stronger independent Vision history may maintain a
        // distinctive, accepted template even without local rigid consensus.
        const bool strongReferenceConfirmed = referenceConfirmed &&
            *std::min_element(_referenceConfidences.begin(), _referenceConfidences.end()) >= .65 &&
            (_referenceConfidences[0] + _referenceConfidences[1] + _referenceConfidences[2]) / 3 >= .75;
        const bool referenceRefreshAuthorized = strongReferenceConfirmed && best >= .85 && best - second >= .15;
        // Preserve the explicitly selected appearance during acquisition if
        // the first two measured frames both have very strong independent
        // Vision agreement. This updates pixels only; control and feature
        // initialization still require their existing three-frame gates.
        const bool bootstrapRefreshAuthorized = _observations == 2 && _templateUpdates == 0 &&
            _referenceConfidences.size() == 2 &&
            *std::min_element(_referenceConfidences.begin(), _referenceConfidences.end()) >= .9 &&
            accepted && best - second >= .15;
        bool featureAgrees = false, featureGeometryAgrees = false;
        const bool featuresValid = _allowRefresh && _anchors.measure(image, referenceRect, referenceConfidence);
        if (featuresValid) {
            const CGRect feature = _anchors.candidateBox;
            const double wr = box.size.width / feature.size.width, hr = box.size.height / feature.size.height;
            featureGeometryAgrees = wr >= .8 && wr <= 1.25 && hr >= .8 && hr <= 1.25 &&
                std::abs(CGRectGetMidX(box) - CGRectGetMidX(feature)) <= std::max(2. / image.cols, box.size.width * .1) &&
                std::abs(CGRectGetMidY(box) - CGRectGetMidY(feature)) <= std::max(2. / image.rows, box.size.height * .1);
            featureAgrees = accepted && featureGeometryAgrees;
        }
        if (_anchors.foregroundLocked && _featureAgreements == 3 && featuresValid && _anchors.inliers >= 12 &&
            featureGeometryAgrees && accepted && best - second >= .08 && dx <= maxDX && dy <= maxDY) {
            NSMutableDictionary *measurement = [featureMeasurement(image, true, referenceRect, referenceConfidence) mutableCopy];
            if ([measurement[@"accepted"] boolValue]) {
                _featureMeasurementLocked = true;
                measurement[@"appearance_measured"] = @YES;
                measurement[@"appearance_score"] = @(best);
                measurement[@"appearance_accepted"] = @(accepted);
                measurement[@"appearance_margin"] = @(best - second);
                return measurement;
            }
        }
        _featureAgreements = featureAgrees ? std::min(3, _featureAgreements + 1) : 0;
        // A slightly offset or central detail box may still refer to the same
        // object. Keep strict agreement for seeding new feature identities.
        const bool featureConfirmed = _featureAgreements == 3 &&
            std::isfinite(referenceConfidence) && (referenceConfidence < .6 || referenceAgrees ||
                referenceOverlaps || referenceIsContainedDetail);
        // A changing transparent surface can lower whole-patch correlation
        // while many independently matched details still locate it precisely.
        // Require stronger support for this refresh; match acceptance stays .8.
        // When BOTH the independent Vision history and local features agree,
        // refresh before an accepted but changing surface reaches the .8 loss
        // boundary. Feature-only support retains the stricter .85 floor.
        // Independent Vision confirmation also permits the normal geometric
        // residual (1 px). Feature-only refresh retains the tighter 0.5 px.
        const bool featureRefreshAuthorized = ((featureConfirmed && best >= .85 && _anchors.meanError <= .5) ||
            (featureAgrees && referenceConfirmed && accepted && _anchors.meanError <= 1)) &&
            _anchors.inliers >= 12 && _anchors.meanScore >= .9 && best - second >= .08;
        bool refreshed = false;
        if (accepted) {
            _center = bestCenter;
            _scale = bestScale;
            // Refresh only a still-strong, spatially unique measured texture,
            // with three consecutive Vision agreements or bidirectional-feature
            // agreements. Never learn from a held, ambiguous, or missing target.
            // Near-identical frames need no resampling (avoids static blur).
            if (_allowRefresh && (((referenceConfirmed || featureConfirmed) && best >= .9) ||
                featureRefreshAuthorized || referenceRefreshAuthorized || bootstrapRefreshAuthorized) &&
                best < .98 && best - second >= .08) {
                cv::Size size((int)std::round(_patch.cols * bestScale), (int)std::round(_patch.rows * bestScale));
                cv::Point2d patchCenter = bestCenter + _patchOffset * bestScale;
                cv::Rect crop((int)std::round(patchCenter.x - size.width * .5),
                              (int)std::round(patchCenter.y - size.height * .5), size.width, size.height);
                if (crop.width >= 8 && crop.height >= 8 &&
                    (crop & cv::Rect(0, 0, image.cols, image.rows)) == crop) {
                    cv::Mat candidate;
                    cv::resize(image(crop), candidate, _patch.size(), 0, 0, cv::INTER_LINEAR);
                    cv::Scalar mean, deviation;
                    cv::meanStdDev(candidate, mean, deviation);
                    if (deviation[0] >= 12) {
                        _patch = candidate;
                        ++_templateUpdates;
                        refreshed = true;
                    }
                }
            }
        }
        // Only a trusted Vision agreement may introduce/replenish points.
        // Otherwise propagate only bidirectionally verified inliers, and only
        // after the whole patch independently accepts the same position.
        // Three independent Vision/patch agreements may establish features
        // before whole-template refresh is warranted. This prevents the first
        // viewpoint change from closing the feature-initialization window.
        if (_allowRefresh && accepted && referenceConfirmed && best - second >= .08 && !_anchors.foregroundLocked &&
            !(featureAgrees && _anchors.inliers >= 12 && _anchors.motionFiltered)) {
            _anchors.initialize(image, bestCenter, cv::Size2d(width, height));
        } else if (featureAgrees) {
            _anchors.commit(image);
        }
        return @{ @"accepted": @(accepted), @"reason": accepted ? @"matched" : [rejections componentsJoinedByString:@","],
                  @"template_refreshed": @(refreshed), @"template_updates": @(_templateUpdates),
                  @"reference_agrees": @(referenceAgrees), @"reference_confirmed": @(referenceConfirmed),
                  @"reference_overlaps": @(referenceOverlaps),
                  @"reference_is_contained_detail": @(referenceIsContainedDetail),
                  @"strong_reference_confirmed": @(strongReferenceConfirmed),
                  @"reference_refresh_authorized": @(referenceRefreshAuthorized),
                  @"bootstrap_refresh_authorized": @(bootstrapRefreshAuthorized),
                  @"reference_scale_selected": @(referenceScaleSelected),
                  @"feature_bbox": CGRectIsNull(_anchors.candidateBox) ? @[] : @[@(_anchors.candidateBox.origin.x), @(_anchors.candidateBox.origin.y), @(_anchors.candidateBox.size.width), @(_anchors.candidateBox.size.height)],
                  @"feature_reference_agrees": @(featureAgrees), @"feature_reference_confirmed": @(featureConfirmed),
                  @"feature_refresh_authorized": @(featureRefreshAuthorized),
                  @"anchor_count": @(_anchors.positions.size()), @"anchor_matches": @(_anchors.matches),
                  @"anchor_inliers": @(_anchors.inliers), @"anchor_mean_score": @(_anchors.meanScore),
                  @"anchor_mean_error_px": @(_anchors.meanError),
                  @"anchor_backward_rejected": @(_anchors.backwardRejected),
                  @"anchor_motion_filtered": @(_anchors.motionFiltered),
                  @"anchor_foreground_locked": @(_anchors.foregroundLocked),
                  @"anchor_removed_outliers": @(_anchors.removedOutliers),
                  @"anchor_spread_width": @(_anchors.spreadWidth), @"anchor_spread_height": @(_anchors.spreadHeight),
                  @"rejections": rejections, @"score": @(best), @"margin": @(best - second),
                  @"dx": @(dx), @"dy": @(dy), @"max_dx": @(maxDX), @"max_dy": @(maxDY),
                  @"search_window": @[@(window.x), @(window.y), @(window.width), @(window.height)],
                  @"scale": @(bestScale), @"bbox": @[@(box.origin.x), @(box.origin.y), @(box.size.width), @(box.size.height)] };
    } catch (const cv::Exception &) { return @{ @"accepted": @NO, @"reason": @"opencv_error" }; }
}
};

static cv::Mat CMTrackingHSV(CVPixelBufferRef pixels, cv::Size size) {
    CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    cv::Mat hsv;
    try {
        const int w = (int)CVPixelBufferGetWidth(pixels), h = (int)CVPixelBufferGetHeight(pixels);
        cv::Mat bgr, small;
        if (CVPixelBufferGetPlaneCount(pixels) == 2) {
            cv::Mat y(h, w, CV_8UC1, CVPixelBufferGetBaseAddressOfPlane(pixels, 0), CVPixelBufferGetBytesPerRowOfPlane(pixels, 0));
            cv::Mat uv(h / 2, w / 2, CV_8UC2, CVPixelBufferGetBaseAddressOfPlane(pixels, 1), CVPixelBufferGetBytesPerRowOfPlane(pixels, 1));
            cv::cvtColorTwoPlane(y, uv, bgr, cv::COLOR_YUV2BGR_NV12);
        } else if (CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA) {
            cv::Mat bgra(h, w, CV_8UC4, CVPixelBufferGetBaseAddress(pixels), CVPixelBufferGetBytesPerRow(pixels));
            cv::resize(bgra, small, size, 0, 0, cv::INTER_AREA);
            cv::cvtColor(small, bgr, cv::COLOR_BGRA2BGR);
        }
        if (!bgr.empty()) {
            cv::resize(bgr, small, size, 0, 0, cv::INTER_AREA);
            cv::cvtColor(small, hsv, cv::COLOR_BGR2HSV);
        }
    } catch (const cv::Exception &) { hsv.release(); }
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    return hsv;
}

static cv::Mat CMColorHistogram(const cv::Mat &hsv, const cv::Mat &mask) {
    int channels[] = {0, 1}, bins[] = {24, 8};
    float hue[] = {0, 180}, saturation[] = {0, 256};
    const float *ranges[] = {hue, saturation};
    cv::Mat hist;
    cv::calcHist(&hsv, 1, channels, mask, hist, 2, bins, ranges);
    const double total = cv::sum(hist)[0];
    if (total > 0) hist /= total;
    return hist;
}

static cv::Mat CMColorModel(const cv::Mat &foreground, const cv::Mat &background) {
    cv::Mat model = foreground / (foreground + 3 * background + .005);
    // Near-gray pixels do not define a distinctive color identity. Those
    // selections retain the existing texture route instead of learning skin,
    // shirt, wall or illumination changes as a colored target.
    model.colRange(0, 2).setTo(0);
    return model;
}

static cv::Mat CMColorMask(const cv::Mat &hsv, const cv::Mat &model) {
    cv::Mat mask = cv::Mat::zeros(hsv.size(), CV_8UC1);
    for (int y = 0; y < hsv.rows; ++y) {
        const cv::Vec3b *pixels = hsv.ptr<cv::Vec3b>(y);
        uchar *out = mask.ptr<uchar>(y);
        for (int x = 0; x < hsv.cols; ++x) {
            const auto &v = pixels[x];
            out[x] = v[2] >= 35 && model.at<float>(v[0] * 24 / 180, v[1] * 8 / 256) > .7 ? 255 : 0;
        }
    }
    cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, cv::Mat::ones(3, 3, CV_8U));
    return mask;
}

/// A compact colored surface can contain moving reflection/label gaps. Match
/// its envelope rather than treating those gaps as permanent texture. Work on
/// each connected component separately: two targets must never become one hull.
/// Sparse/strongly concave components keep their measured shape.
static cv::Mat CMColorSilhouette(const cv::Mat &mask) {
    cv::Mat silhouette = mask.clone(), labels, stats, centers;
    const int count = cv::connectedComponentsWithStats(mask, labels, stats, centers);
    for (int i = 1; i < count; ++i) {
        const int area = stats.at<int>(i, cv::CC_STAT_AREA);
        if (area < 16) continue;
        const cv::Rect bounds(stats.at<int>(i, cv::CC_STAT_LEFT), stats.at<int>(i, cv::CC_STAT_TOP),
                              stats.at<int>(i, cv::CC_STAT_WIDTH), stats.at<int>(i, cv::CC_STAT_HEIGHT));
        std::vector<cv::Point> points, hull;
        cv::findNonZero(labels(bounds) == i, points);
        cv::convexHull(points, hull);
        if (hull.size() < 3) continue;
        cv::Mat envelope = cv::Mat::zeros(bounds.size(), CV_8U);
        cv::fillConvexPoly(envelope, hull, cv::Scalar(255));
        if (area >= cv::countNonZero(envelope) * .65) {
            cv::bitwise_or(silhouette(bounds), envelope, silhouette(bounds));
        }
    }
    return silhouette;
}

/// Derive a color identity from one central connected foreground component,
/// excluding colors that are common immediately outside the manual selection.
/// The model remains frozen for the entire request; there is no later reacquisition.
static cv::Mat CMInitialColorModel(const cv::Mat &hsv, CGRect selection) {
    if (hsv.empty()) return {};
    const cv::Rect bounds(0, 0, hsv.cols, hsv.rows);
    cv::Point2d center(CGRectGetMidX(selection) * hsv.cols, (1 - CGRectGetMidY(selection)) * hsv.rows);
    cv::Size2d size(selection.size.width * hsv.cols, selection.size.height * hsv.rows);
    auto crop = [&](double scale) {
        int x = (int)std::floor(center.x - size.width * scale * .5);
        int y = (int)std::floor(center.y - size.height * scale * .5);
        return cv::Rect(x, y, (int)std::ceil(center.x + size.width * scale * .5) - x,
                            (int)std::ceil(center.y + size.height * scale * .5) - y) & bounds;
    };
    cv::Rect inside = crop(1), outside = crop(1.8);
    if (inside.empty() || inside.area() < 64) return {};
    cv::Mat fg = cv::Mat::zeros(hsv.size(), CV_8U), bg = fg.clone();
    fg(inside).setTo(255); bg(outside).setTo(255); bg(inside).setTo(0);
    cv::Mat background = CMColorHistogram(hsv, bg);
    cv::Mat model = CMColorModel(CMColorHistogram(hsv, fg), background);
    cv::Mat mask = CMColorMask(hsv, model);
    cv::bitwise_and(mask, fg, mask);
    cv::Mat labels, stats, centers;
    int count = cv::connectedComponentsWithStats(mask, labels, stats, centers);
    int selected = -1, area = 0, secondArea = 0;
    for (int i = 1; i < count; ++i) {
        if (std::abs(centers.at<double>(i, 0) - center.x) > size.width * .35 ||
            std::abs(centers.at<double>(i, 1) - center.y) > size.height * .35) continue;
        int candidateArea = stats.at<int>(i, cv::CC_STAT_AREA);
        if (candidateArea > area) { secondArea = area; area = candidateArea; selected = i; }
        else secondArea = std::max(secondArea, candidateArea);
    }
    if (selected < 0 || area < inside.area() * .08 || area > inside.area() * .85 || secondArea > area * .5) return {};
    cv::Mat selectedMask = labels == selected;
    return CMColorModel(CMColorHistogram(hsv, selectedMask), background);
}

@implementation CMPhysicalObjectPatchTracker {
    std::unique_ptr<CMPatchMatcher> _texture;
    std::unique_ptr<CMPatchMatcher> _foreground;
    cv::Mat _colorModel;
    cv::Size _size;
    bool _foregroundDecided;
    bool _foregroundLocked;
    bool _textureHasAccepted;
    bool _lastTrackingAccepted;
    double _lastFrozenFrameToken;
}
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection {
    if (!(self = [super init])) return nil;
    if (!std::isfinite(selection.origin.x) || !std::isfinite(selection.origin.y) ||
        !std::isfinite(selection.size.width) || !std::isfinite(selection.size.height) ||
        selection.size.width <= 0 || selection.size.height <= 0) return nil;
    try {
        cv::Mat gray = CMTrackingGray(pixels);
        if (gray.empty()) return nil;
        _size = gray.size();
        _texture = std::make_unique<CMPatchMatcher>();
        if (!_texture->initialize(gray, selection)) _texture.reset();
        cv::Mat hsv = CMTrackingHSV(pixels, _size);
        _colorModel = CMInitialColorModel(hsv, selection);
        if (!_colorModel.empty()) {
            _foreground = std::make_unique<CMPatchMatcher>();
            if (!_foreground->initialize(CMColorSilhouette(CMColorMask(hsv, _colorModel)), selection, .9, false)) _foreground.reset();
        }
    } catch (const cv::Exception &) { _foreground.reset(); }
    return _texture || _foreground ? self : nil;
}
- (NSDictionary<NSString *, id> *)trackPixelBuffer:(CVPixelBufferRef)pixels {
    cv::Mat gray = CMTrackingGray(pixels);
    NSDictionary *result = _texture ? _texture->track(gray) : @{ @"accepted": @NO, @"reason": @"texture_unavailable" };
    _lastTrackingAccepted = [result[@"accepted"] boolValue];
    if (_lastTrackingAccepted) {
        _textureHasAccepted = true;
        _texture->cacheCenterRecoveryColor(CMTrackingHSV(pixels, gray.size()));
        _texture->clearCenterRecovery();
    }
    return result;
}
- (BOOL)supportsCenterRecovery {
    return _textureHasAccepted && !_foregroundLocked && _texture && _texture->_allowRefresh &&
        !_texture->_featureMeasurementLocked && !_texture->_anchors.foregroundLocked;
}
- (NSDictionary<NSString *, id> *)recoverPixelBuffer:(CVPixelBufferRef)pixels {
    if (!self.supportsCenterRecovery || _lastTrackingAccepted)
        return @{ @"accepted": @NO, @"reason": @"center_recovery_unsupported" };
    const cv::Mat gray = CMTrackingGray(pixels);
    const cv::Mat hsv = _texture->usesCenterRecoveryColor() ? CMTrackingHSV(pixels, gray.size()) : cv::Mat();
    NSDictionary *result = _texture->recoverCenter(gray, hsv);
    if ([result[@"accepted"] boolValue]) _lastTrackingAccepted = true;
    return result;
}
- (void)resetFrozenRecoveryConfirmation {
    if (_texture) _texture->_centerRecoveryConfirmations = 0;
}
- (NSDictionary<NSString *, id> *)recoverFrozenPixelBuffer:(CVPixelBufferRef)pixels frameToken:(double)frameToken {
    if (!self.supportsCenterRecovery || !std::isfinite(frameToken) || frameToken <= _lastFrozenFrameToken)
        return @{ @"accepted": @NO, @"reason": @"frozen_recovery_invalid_observation" };
    _lastFrozenFrameToken = frameToken;
    // The parts bridge owns motion. Do not run track() here: it could absorb
    // the old background while the original object is somewhere else.
    ++_texture->_observations;
    _lastTrackingAccepted = false;
    return [self recoverPixelBuffer:pixels];
}
- (NSDictionary<NSString *, id> *)trackPixelBuffer:(CVPixelBufferRef)pixels
                                  referenceRect:(CGRect)referenceRect
                            referenceConfidence:(float)referenceConfidence {
    cv::Mat gray = CMTrackingGray(pixels);
    NSDictionary *texture = _texture ? _texture->track(gray, referenceRect, referenceConfidence)
        : @{ @"accepted": @NO, @"reason": @"texture_unavailable" };
    NSDictionary *foreground = nil;
    if (_foreground && gray.size() == _size) {
        try {
            cv::Mat hsv = CMTrackingHSV(pixels, _size);
            if (!hsv.empty()) foreground = _foreground->track(CMColorSilhouette(CMColorMask(hsv, _colorModel)));
        } catch (const cv::Exception &) { foreground = @{ @"accepted": @NO, @"reason": @"color_error" }; }
    }
    // A distinctive, frozen foreground silhouette measures target motion
    // independently of background changes and grayscale detail/motion blur.
    // It must satisfy its own score, uniqueness, displacement and scale gates.
    if (!_foregroundDecided) {
        _foregroundDecided = true;
        _foregroundLocked = [foreground[@"accepted"] boolValue];
        if (!_foregroundLocked) _foreground.reset();
        else _texture.reset(); // The locked foreground route never consumes background texture.
    }
    // Once established, a missing/ambiguous foreground holds the same target;
    // never fall back to a texture that may have stayed on its old background.
    bool useForeground = _foregroundLocked;
    if (useForeground && !foreground) foreground = @{ @"accepted": @NO, @"reason": @"foreground_unavailable" };
    NSMutableDictionary *result = [(useForeground ? foreground : texture) mutableCopy];
    _lastTrackingAccepted = [result[@"accepted"] boolValue];
    if (!useForeground && _lastTrackingAccepted) {
        _textureHasAccepted = true;
        _texture->cacheCenterRecoveryColor(CMTrackingHSV(pixels, gray.size()));
        _texture->clearCenterRecovery();
    }
    result[@"measurement_source"] = useForeground ? @"foreground_color_shape" : (texture[@"measurement_source"] ?: @"texture");
    result[@"foreground_available"] = @(_foreground != nullptr);
    result[@"foreground_accepted"] = @([foreground[@"accepted"] boolValue]);
    result[@"foreground_score"] = foreground[@"score"] ?: @(-1);
    result[@"foreground_reason"] = foreground[@"reason"] ?: @"unavailable";
    result[@"texture_accepted"] = texture[@"appearance_accepted"] ?: @([texture[@"accepted"] boolValue]);
    result[@"texture_score"] = texture[@"appearance_score"] ?: texture[@"score"] ?: @(-1);
    return result;
}
@end

// Independent recovery identity. Existing tracker appearance and its local
// motion rules remain separate from this bounded, explicitly selected gallery.
#include <opencv2/features2d.hpp>
#include <limits>
#include <optional>

namespace {
using CMRecoveryClock = std::chrono::steady_clock;
struct CMRecoveryScopedMilliseconds {
    double &total;
    CMRecoveryClock::time_point start = CMRecoveryClock::now();
    explicit CMRecoveryScopedMilliseconds(double &total) : total(total) {}
    ~CMRecoveryScopedMilliseconds() {
        total += std::chrono::duration<double, std::milli>(CMRecoveryClock::now() - start).count();
    }
};

// Removing current-image query rows does not change their nearest neighbours
// in the same frozen view. Preserve ratioMatches' <2-row behavior. Invalid
// mappings return no result so the caller rejects the entire identity search,
// rather than mistaking missing cache data for absence of a competing object.
static std::optional<std::vector<int>> CMRecoverySubsetReverseMatches(const std::vector<int> &fullReverse,
                                                                     const std::vector<int> &originalRows,
                                                                     int remainingRows, int viewRows) {
    if (remainingRows < 0 || viewRows < 0 || originalRows.size() != size_t(remainingRows)) return std::nullopt;
    for (const int row : originalRows)
        if (row < 0 || size_t(row) >= fullReverse.size()) return std::nullopt;
    std::vector<int> result(remainingRows, -1);
    if (remainingRows < 2 || viewRows < 2) return result;
    for (size_t i = 0; i < originalRows.size(); ++i) result[i] = fullReverse[originalRows[i]];
    return result;
}
struct CMRecoveryFrame {
    cv::Mat gray, hsv, descriptors;
    std::vector<cv::KeyPoint> features;
};
struct CMRecoveryView {
    cv::Mat hsv, descriptors;
    std::vector<cv::Point2f> points;
    std::array<cv::Point2f, 4> quad;
    cv::Rect2d rect;
    int identifier = 0;
};
struct CMRecoveryCandidate {
    cv::Rect2d rect;
    std::array<cv::Point2f, 4> quad;
    int view = 0, inliers = 0, matches = 0, colorPixels = 0;
    double colorAgreement = 0, histogramAgreement = 0, medianError = 0;
};

class CMCanonicalRecovery {
    cv::Ptr<cv::SIFT> sift = cv::SIFT::create(2200, 3, .012, 10, 1.2);
    cv::BFMatcher matcher{cv::NORM_L2};
    int nextIdentifier = 1;
    static bool colorful(const cv::Vec3b &p) { return p[1] >= 64 && p[2] >= 35; }
    static bool colorCompatible(const cv::Vec3b &a, const cv::Vec3b &b) {
        const int rawHue = std::abs(int(a[0]) - int(b[0]));
        return std::min(rawHue, 180 - rawHue) <= 12 && std::abs(int(a[1]) - int(b[1])) <= 80;
    }
    static cv::Rect integerBounds(const cv::Rect2d &r, cv::Size size) {
        const int x0 = std::max(0, int(std::ceil(r.x))), y0 = std::max(0, int(std::ceil(r.y)));
        const int x1 = std::min(size.width, int(std::floor(r.x + r.width)));
        const int y1 = std::min(size.height, int(std::floor(r.y + r.height)));
        return cv::Rect(x0, y0, std::max(0, x1 - x0), std::max(0, y1 - y0));
    }
    static cv::Point2f transformed(const cv::Mat &m, cv::Point2f p) {
        return cv::Point2f(float(m.at<double>(0, 0) * p.x + m.at<double>(0, 1) * p.y + m.at<double>(0, 2)),
                           float(m.at<double>(1, 0) * p.x + m.at<double>(1, 1) * p.y + m.at<double>(1, 2)));
    }
    static std::vector<cv::Vec3b> patchColors(const cv::Mat &hsv, cv::Point2f p) {
        const int x = int(std::nearbyint(p.x)), y = int(std::nearbyint(p.y));
        std::vector<cv::Vec3b> colors;
        const cv::Rect r = cv::Rect(x - 4, y - 4, 9, 9) & cv::Rect(0, 0, hsv.cols, hsv.rows);
        for (int yy = r.y; yy < r.y + r.height; ++yy)
            for (int xx = r.x; xx < r.x + r.width; ++xx) {
                const auto c = hsv.at<cv::Vec3b>(yy, xx);
                if (colorful(c)) colors.push_back(c);
            }
        return colors;
    }
    static bool compatibleSupport(const cv::Mat &a, cv::Point2f pa, const cv::Mat &b, cv::Point2f pb) {
        const auto aa = patchColors(a, pa), bb = patchColors(b, pb);
        if (aa.size() < 8 || bb.size() < 8) return false;
        size_t matchedA = 0, matchedB = 0;
        for (const auto &v : aa) {
            bool hit = false;
            for (const auto &u : bb) if (colorCompatible(v, u)) { hit = true; break; }
            matchedA += hit;
        }
        for (const auto &v : bb) {
            bool hit = false;
            for (const auto &u : aa) if (colorCompatible(v, u)) { hit = true; break; }
            matchedB += hit;
        }
        return matchedA >= .75 * aa.size() && matchedB >= .75 * bb.size();
    }
    static bool supportedColors(const CMRecoveryView &view, const cv::Mat &current,
                                const cv::Mat &m, const std::vector<cv::Point2f> &inliers,
                                CMRecoveryCandidate &result) {
        cv::Mat mask = cv::Mat::zeros(view.hsv.size(), CV_8U);
        for (const auto &p : inliers)
            cv::circle(mask, cv::Point(int(std::nearbyint(p.x)), int(std::nearbyint(p.y))), 5, 255, -1);
        std::vector<cv::Point> samples;
        const auto bounds = integerBounds(view.rect, view.hsv.size());
        for (int y = bounds.y; y < bounds.y + bounds.height; ++y)
            for (int x = bounds.x; x < bounds.x + bounds.width; ++x)
                if (mask.at<uchar>(y, x) && colorful(view.hsv.at<cv::Vec3b>(y, x))) samples.emplace_back(x, y);
        const size_t count = std::min(size_t(2048), samples.size());
        int matched = 0, usable = 0;
        std::array<double, 192> ah{}, bh{};
        for (size_t i = 0; i < count; ++i) {
            const size_t j = samples.size() <= 2048 ? i : size_t(double(i) * double(samples.size() - 1) / 2047.);
            const auto p = samples[j];
            const auto q = transformed(m, cv::Point2f(p));
            const int x = int(std::nearbyint(q.x)), y = int(std::nearbyint(q.y));
            if (x < 0 || y < 0 || x >= current.cols || y >= current.rows) continue;
            const auto a = view.hsv.at<cv::Vec3b>(p), b = current.at<cv::Vec3b>(y, x);
            ++usable;
            matched += colorCompatible(a, b) && b[1] >= 48 && b[2] >= 35;
            ++ah[(int(a[0]) * 24 / 180) * 8 + int(a[1]) * 8 / 256];
            ++bh[(int(b[0]) * 24 / 180) * 8 + int(b[1]) * 8 / 256];
        }
        result.colorPixels = usable;
        result.colorAgreement = usable ? double(matched) / usable : 0;
        double intersection = 0;
        for (size_t i = 0; i < ah.size(); ++i) intersection += std::min(ah[i], bh[i]);
        result.histogramAgreement = usable ? intersection / usable : 0;
        return usable >= 80 && result.colorAgreement >= .85;
    }
    std::vector<int> ratioMatches(const cv::Mat &a, const cv::Mat &b) {
        std::vector<int> result(a.rows, -1);
        if (a.rows < 2 || b.rows < 2) return result;
        std::vector<std::vector<cv::DMatch>> matches;
        ++knnMatchCalls;
        CMRecoveryScopedMilliseconds timing(knnMatchingMS);
        matcher.knnMatch(a, b, matches, 2);
        for (size_t i = 0; i < matches.size(); ++i)
            if (matches[i].size() == 2 && matches[i][0].distance < .70 * matches[i][1].distance)
                result[i] = matches[i][0].trainIdx;
        return result;
    }
    bool makeView(const CMRecoveryFrame &frame, const cv::Rect2d &rect,
                  const std::array<cv::Point2f, 4> &quad, bool canonicalFilter, CMRecoveryView &view) {
        const auto roi = integerBounds(rect, frame.hsv.size());
        if (roi.empty()) return false;
        cv::Mat saturated;
        cv::inRange(frame.hsv, cv::Scalar(0, 64, 35), cv::Scalar(179, 255, 255), saturated);
        const int colored = cv::countNonZero(saturated(roi));
        if (colored < 16 || colored < .08 * roi.area()) return false;
        cv::dilate(saturated, saturated, cv::Mat::ones(3, 3, CV_8U));
        cv::Mat toInitial;
        if (canonicalFilter) toInitial = cv::getAffineTransform(quad.data(), views.front().quad.data());
        for (size_t i = 0; i < frame.features.size(); ++i) {
            const auto p = frame.features[i].pt;
            const cv::Point pixel(int(p.x), int(p.y));
            if (!roi.contains(pixel) || !saturated.at<uchar>(pixel)) continue;
            if (canonicalFilter) {
                const auto mapped = transformed(toInitial, p);
                const int x = int(std::nearbyint(mapped.x)), y = int(std::nearbyint(mapped.y));
                const auto &initial = views.front();
                if (!initial.rect.contains(cv::Point2d(x, y)) || x < 2 || y < 2 ||
                    x >= initial.hsv.cols - 2 || y >= initial.hsv.rows - 2) continue;
                const int cx = std::max(0, std::min(frame.hsv.cols - 1, int(std::nearbyint(p.x))));
                const int cy = std::max(0, std::min(frame.hsv.rows - 1, int(std::nearbyint(p.y))));
                const auto current = frame.hsv.at<cv::Vec3b>(cy, cx);
                if (current[1] < 48 || current[2] < 35) continue;
                bool agrees = false;
                for (int yy = y - 2; yy <= y + 2 && !agrees; ++yy)
                    for (int xx = x - 2; xx <= x + 2; ++xx) {
                        const auto original = initial.hsv.at<cv::Vec3b>(yy, xx);
                        if (colorful(original) && colorCompatible(original, current)) { agrees = true; break; }
                    }
                if (!agrees) continue;
            }
            view.points.push_back(p);
            view.descriptors.push_back(frame.descriptors.row(int(i)));
        }
        if (view.points.size() < 6) return false;
        view.hsv = frame.hsv.clone(); view.rect = rect; view.quad = quad;
        return true;
    }
    static bool safeRect(const cv::Rect2d &r, cv::Size size) {
        if (!std::isfinite(r.x) || !std::isfinite(r.y) || !std::isfinite(r.width) || !std::isfinite(r.height) ||
            r.width < .002 * size.width || r.height < .002 * size.height ||
            r.width > size.width || r.height > size.height) return false;
        const double area = (r & cv::Rect2d(0, 0, size.width, size.height)).area();
        const auto center = r.tl() + cv::Point2d(r.width * .5, r.height * .5);
        return area >= .85 * r.area() && center.x >= 0 && center.y >= 0 &&
               center.x <= size.width && center.y <= size.height;
    }
    void candidates(const CMRecoveryView &view, const CMRecoveryFrame &frame,
                    CMRecoveryClock::time_point start, std::vector<CMRecoveryCandidate> &found,
                    std::vector<int> &reverse, bool reuseReverse = false) {
        const auto forward = ratioMatches(view.descriptors, frame.descriptors);
        if (!reuseReverse) reverse = ratioMatches(frame.descriptors, view.descriptors);
        if (reverse.size() != size_t(frame.descriptors.rows)) return;
        std::vector<cv::Point2f> source, target;
        for (size_t i = 0; i < forward.size(); ++i) {
            const int j = forward[i];
            if (j < 0 || reverse[j] != int(i)) continue;
            if (!compatibleSupport(view.hsv, view.points[i], frame.hsv, frame.features[j].pt)) continue;
            source.push_back(view.points[i]); target.push_back(frame.features[j].pt);
        }
        maxMatches = std::max(maxMatches, int(source.size()));
        for (int attempt = 0; attempt < 3 && source.size() >= 6; ++attempt) {
            if (!withinBudget(start)) return;
            cv::Mat mask;
            const auto m = cv::estimateAffinePartial2D(source, target, mask, cv::RANSAC, 2.5, 2000, .999, 10);
            if (m.empty() || !cv::checkRange(m)) return;
            std::vector<cv::Point2f> supported, remainingSource, remainingTarget;
            std::vector<double> errors;
            for (size_t i = 0; i < source.size(); ++i) {
                if (mask.at<uchar>(int(i))) {
                    supported.push_back(source[i]); errors.push_back(cv::norm(transformed(m, source[i]) - target[i]));
                } else { remainingSource.push_back(source[i]); remainingTarget.push_back(target[i]); }
            }
            const size_t matchCount = source.size();
            source = std::move(remainingSource); target = std::move(remainingTarget);
            if (supported.size() < 6) return;
            if (supported.size() < .75 * matchCount) continue;
            std::sort(errors.begin(), errors.end());
            const double median = (errors[(errors.size() - 1) / 2] + errors[errors.size() / 2]) * .5;
            if (median > 1.5 || errors.back() > 3) continue;
            double minX = supported[0].x, maxX = minX, minY = supported[0].y, maxY = minY;
            cv::Point2d mean;
            for (const auto &p : supported) { minX = std::min(minX, double(p.x)); maxX = std::max(maxX, double(p.x));
                minY = std::min(minY, double(p.y)); maxY = std::max(maxY, double(p.y)); mean += cv::Point2d(p); }
            mean *= 1. / supported.size();
            double xx = 0, yy = 0, xy = 0;
            for (const auto &p : supported) { const double dx = p.x - mean.x, dy = p.y - mean.y; xx += dx * dx; yy += dy * dy; xy += dx * dy; }
            const double n = supported.size() - 1; xx /= n; yy /= n; xy /= n;
            const double eigenMin = (xx + yy - std::hypot(xx - yy, 2 * xy)) * .5;
            if (maxX - minX < std::max(8., .12 * view.rect.width) ||
                maxY - minY < std::max(6., .06 * view.rect.height) || eigenMin < 4) continue;
            const double determinant = m.at<double>(0, 0) * m.at<double>(1, 1) - m.at<double>(0, 1) * m.at<double>(1, 0);
            if (determinant < .25 * .25 || determinant > 4 * 4) continue;
            CMRecoveryCandidate candidate;
            candidate.view = view.identifier; candidate.inliers = int(supported.size()); candidate.matches = int(matchCount);
            candidate.medianError = median;
            double x0 = std::numeric_limits<double>::infinity(), y0 = x0, x1 = -x0, y1 = -x0;
            for (size_t i = 0; i < view.quad.size(); ++i) {
                const auto p = transformed(m, view.quad[i]); candidate.quad[i] = p;
                x0 = std::min(x0, double(p.x)); y0 = std::min(y0, double(p.y));
                x1 = std::max(x1, double(p.x)); y1 = std::max(y1, double(p.y));
            }
            candidate.rect = cv::Rect2d(x0, y0, x1 - x0, y1 - y0);
            if (!safeRect(candidate.rect, frame.gray.size()) || !supportedColors(view, frame.hsv, m, supported, candidate)) continue;
            found.push_back(candidate);
        }
    }
public:
    std::vector<CMRecoveryView> views;
    cv::Size imageSize;
    int maxMatches = 0, clusterCount = 0, streak = 0;
    int knnMatchCalls = 0, reverseKNNCallsSaved = 0, reverseRowsReused = 0;
    double extractionMS = 0, knnMatchingMS = 0, primarySearchMS = 0, competitorSearchMS = 0;
    bool competitorCheckComplete = false;
    double lastFrameToken = -std::numeric_limits<double>::infinity();
    CMRecoveryCandidate previous;
    bool hasPrevious = false;
    void resetOperationMetrics() {
        maxMatches = clusterCount = knnMatchCalls = reverseKNNCallsSaved = reverseRowsReused = 0;
        extractionMS = knnMatchingMS = primarySearchMS = competitorSearchMS = 0;
        competitorCheckComplete = false;
    }
    static bool withinBudget(CMRecoveryClock::time_point start) {
        return std::chrono::duration<double>(CMRecoveryClock::now() - start).count() <= .120;
    }
    static bool same(const CMRecoveryCandidate &a, const CMRecoveryCandidate &b) {
        const auto ca = a.rect.tl() + cv::Point2d(a.rect.width * .5, a.rect.height * .5);
        const auto cb = b.rect.tl() + cv::Point2d(b.rect.width * .5, b.rect.height * .5);
        const double side = std::min(std::min(a.rect.width, a.rect.height), std::min(b.rect.width, b.rect.height));
        const double areaRatio = a.rect.area() / b.rect.area();
        return cv::norm(ca - cb) <= std::max(10., .25 * side) && areaRatio >= .6 && areaRatio <= 1.67;
    }
    bool extract(CVPixelBufferRef pixels, CMRecoveryFrame &frame) {
        CMRecoveryScopedMilliseconds timing(extractionMS);
        frame.gray = CMTrackingGray(pixels);
        if (frame.gray.empty()) return false;
        frame.hsv = CMTrackingHSV(pixels, frame.gray.size());
        return describe(frame);
    }
    bool describe(CMRecoveryFrame &frame) {
        if (frame.gray.empty() || frame.hsv.empty()) return false;
        sift->detectAndCompute(frame.gray, cv::noArray(), frame.features, frame.descriptors);
        return frame.features.size() >= 6 && frame.descriptors.rows == int(frame.features.size());
    }
    static cv::Rect2d pixelRect(CGRect normalized, cv::Size size) {
        return cv::Rect2d(normalized.origin.x * size.width,
                         (1 - normalized.origin.y - normalized.size.height) * size.height,
                         normalized.size.width * size.width, normalized.size.height * size.height);
    }
    bool initialize(const CMRecoveryFrame &frame, CGRect selection) {
        const auto rect = pixelRect(selection, frame.gray.size());
        if (!safeRect(rect, frame.gray.size())) return false;
        const std::array<cv::Point2f, 4> quad = {cv::Point2f(rect.x, rect.y), cv::Point2f(rect.x + rect.width, rect.y),
            cv::Point2f(rect.x + rect.width, rect.y + rect.height), cv::Point2f(rect.x, rect.y + rect.height)};
        CMRecoveryView view;
        if (!makeView(frame, rect, quad, false, view)) return false;
        imageSize = frame.gray.size(); views.push_back(std::move(view)); return true;
    }
    bool find(const CMRecoveryFrame &frame, CMRecoveryClock::time_point start, CMRecoveryCandidate &result) {
        maxMatches = clusterCount = 0;
        competitorCheckComplete = false;
        if (frame.gray.size() != imageSize) return false;
        std::vector<CMRecoveryCandidate> found;
        // This cache belongs only to this find call and this frozen view order.
        // It never survives a new image, history import or confirmation frame.
        std::vector<std::vector<int>> reverseByView(views.size());
        std::vector<CMRecoveryCandidate> clusters;
        {
            CMRecoveryScopedMilliseconds timing(primarySearchMS);
            for (size_t i = 0; i < views.size(); ++i) {
                if (!withinBudget(start)) return false;
                candidates(views[i], frame, start, found, reverseByView[i]);
            }
            if (!withinBudget(start)) return false;
            std::stable_sort(found.begin(), found.end(), [](const auto &a, const auto &b) {
                return a.inliers != b.inliers ? a.inliers > b.inliers : a.histogramAgreement > b.histogramAgreement;
            });
            for (const auto &candidate : found) {
                bool joined = false;
                for (const auto &cluster : clusters) if (same(candidate, cluster)) { joined = true; break; }
                if (!joined) clusters.push_back(candidate);
            }
            clusterCount = int(clusters.size());
            if (clusters.size() != 1) return false;
        }
        // A global ratio test may select only the slightly better-rendered
        // instance of two identical objects. One surviving RANSAC cluster
        // therefore does not establish scene-wide uniqueness. Remove the
        // winning instance's feature centers and independently verify all
        // remaining pixels against every frozen view, without extracting or
        // learning any new descriptors. The same gates and total budget apply.
        CMRecoveryScopedMilliseconds timing(competitorSearchMS);
        CMRecoveryFrame remaining;
        remaining.gray = frame.gray; remaining.hsv = frame.hsv;
        std::vector<int> originalRows;
        for (size_t i = 0; i < frame.features.size(); ++i) {
            if (clusters.front().rect.contains(cv::Point2d(frame.features[i].pt))) continue;
            remaining.features.push_back(frame.features[i]);
            remaining.descriptors.push_back(frame.descriptors.row(int(i)));
            originalRows.push_back(int(i));
        }
        for (size_t i = 0; i < views.size(); ++i) {
            if (!withinBudget(start)) return false;
            const auto &view = views[i];
            auto reverse = CMRecoverySubsetReverseMatches(reverseByView[i], originalRows,
                remaining.descriptors.rows, view.descriptors.rows);
            if (!reverse) return false;
            if (remaining.descriptors.rows >= 2 && view.descriptors.rows >= 2) {
                ++reverseKNNCallsSaved;
                reverseRowsReused += remaining.descriptors.rows;
            }
            std::vector<CMRecoveryCandidate> competitors;
            // The forward search must be recomputed: deleting train rows can
            // change both neighbours and the ratio test for a view descriptor.
            candidates(view, remaining, start, competitors, *reverse, true);
            for (const auto &competitor : competitors) {
                if (!same(clusters.front(), competitor)) {
                    clusterCount = 2;
                    competitorCheckComplete = true;
                    return false;
                }
            }
        }
        if (!withinBudget(start)) return false;
        competitorCheckComplete = true;
        result = clusters.front(); return true;
    }
    bool addTrusted(const CMRecoveryFrame &frame, CGRect observed, CMRecoveryClock::time_point start,
                    CMRecoveryCandidate &candidate, NSString *__strong &reason) {
        if (!find(frame, start, candidate)) { reason = clusterCount > 1 ? @"ambiguous_identity" : @"unverified_identity"; return false; }
        const auto roi = pixelRect(observed, frame.gray.size());
        if (!safeRect(roi, frame.gray.size())) { reason = @"invalid_trusted_roi"; return false; }
        const double intersection = (candidate.rect & roi).area();
        const auto ca = candidate.rect.tl() + cv::Point2d(candidate.rect.width * .5, candidate.rect.height * .5);
        const auto cb = roi.tl() + cv::Point2d(roi.width * .5, roi.height * .5);
        if (intersection < .60 * std::min(candidate.rect.area(), roi.area()) ||
            cv::norm(ca - cb) > .35 * std::max(candidate.rect.width, roi.width)) {
            reason = @"trusted_roi_disagrees"; return false;
        }
        CMRecoveryView view;
        if (!makeView(frame, candidate.rect, candidate.quad, true, view)) { reason = @"insufficient_canonical_support"; return false; }
        if (!withinBudget(start)) { reason = @"recovery_budget_exceeded"; return false; }
        view.identifier = nextIdentifier++;
        views.push_back(std::move(view));
        if (views.size() > 8) views.erase(views.begin() + 1);
        reason = @"trusted_view_added"; return true;
    }
    void resetConfirmation() { streak = 0; hasPrevious = false; }
};
static NSDictionary<NSString *, id> *CMRecoveryMetrics(const CMCanonicalRecovery &engine,
                                                      const CMRecoveryCandidate *candidate,
                                                      CMRecoveryClock::time_point start,
                                                      NSString *reason, bool accepted, bool measured) {
    NSMutableDictionary *result = [@{ @"accepted": @(accepted), @"quality": @(accepted ? .95 : 0),
        @"recovered_verified_identity": @(accepted), @"reason": reason,
        @"identity_match": @(measured), @"template_count": @(engine.views.size()),
        @"confirmation_streak": @(engine.streak), @"max_mutual_matches": @(engine.maxMatches),
        @"candidate_clusters": @(engine.clusterCount),
        @"competitor_check_complete": @(engine.competitorCheckComplete),
        @"knn_match_calls": @(engine.knnMatchCalls),
        @"reverse_knn_calls_saved": @(engine.reverseKNNCallsSaved),
        @"reverse_rows_reused": @(engine.reverseRowsReused),
        @"extraction_ms": @(engine.extractionMS),
        @"knn_matching_ms": @(engine.knnMatchingMS),
        @"primary_search_ms": @(engine.primarySearchMS),
        @"competitor_search_ms": @(engine.competitorSearchMS),
        @"perform_ms": @(std::chrono::duration<double, std::milli>(CMRecoveryClock::now() - start).count()) } mutableCopy];
    if (candidate) {
        const auto r = candidate->rect; const auto size = engine.imageSize;
        result[@"bbox"] = @[@(r.x / size.width), @(1 - (r.y + r.height) / size.height),
                             @(r.width / size.width), @(r.height / size.height)];
        result[@"view_id"] = @(candidate->view); result[@"inliers"] = @(candidate->inliers);
        result[@"mutual_matches"] = @(candidate->matches); result[@"color_agreement"] = @(candidate->colorAgreement);
        result[@"color_pixels"] = @(candidate->colorPixels); result[@"median_error_px"] = @(candidate->medianError);
    }
    return result;
}
}

@implementation CMPhysicalObjectReacquirer {
    std::unique_ptr<CMCanonicalRecovery> _identity;
}
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection {
    if (!(self = [super init])) return nil;
    try {
        _identity = std::make_unique<CMCanonicalRecovery>();
        CMRecoveryFrame frame;
        if (!_identity->extract(pixels, frame) || !_identity->initialize(frame, selection)) return nil;
    } catch (const cv::Exception &) { return nil; }
    return self;
}
- (NSInteger)templateCount { return _identity ? NSInteger(_identity->views.size()) : 0; }
- (void)resetSearchConfirmation { if (_identity) _identity->resetConfirmation(); }
- (NSDictionary<NSString *, id> *)addTrustedPixelBuffer:(CVPixelBufferRef)pixels rect:(CGRect)rect {
    const auto start = CMRecoveryClock::now();
    _identity->resetOperationMetrics();
    CMRecoveryCandidate candidate;
    NSString *reason = @"unavailable_image";
    bool added = false;
    try {
        CMRecoveryFrame frame;
        if (_identity->extract(pixels, frame)) added = _identity->addTrusted(frame, rect, start, candidate, reason);
    } catch (const cv::Exception &) { reason = @"opencv_error"; }
    NSMutableDictionary *result = [CMRecoveryMetrics(*_identity, added ? &candidate : nullptr, start, reason, false, added) mutableCopy];
    result[@"added"] = @(added);
    return result;
}
- (NSDictionary<NSString *, id> *)findPixelBuffer:(CVPixelBufferRef)pixels frameToken:(double)frameToken {
    const auto start = CMRecoveryClock::now();
    _identity->resetOperationMetrics();
    if (!std::isfinite(frameToken) || frameToken <= _identity->lastFrameToken) {
        _identity->resetConfirmation();
        return CMRecoveryMetrics(*_identity, nullptr, start, @"non_monotonic_frame", false, false);
    }
    if (frameToken - _identity->lastFrameToken > .25) _identity->resetConfirmation();
    _identity->lastFrameToken = frameToken;
    CMRecoveryCandidate candidate;
    bool measured = false;
    NSString *reason = @"unavailable_image";
    try {
        CMRecoveryFrame frame;
        if (_identity->extract(pixels, frame)) {
            measured = _identity->find(frame, start, candidate);
            reason = !CMCanonicalRecovery::withinBudget(start) ? @"recovery_budget_exceeded" :
                (_identity->clusterCount > 1 ? @"ambiguous_identity" : @"no_verified_identity");
        }
    } catch (const cv::Exception &) { reason = @"opencv_error"; }
    if (!measured) {
        _identity->resetConfirmation();
        return CMRecoveryMetrics(*_identity, nullptr, start, reason, false, false);
    }
    _identity->streak = _identity->hasPrevious && CMCanonicalRecovery::same(_identity->previous, candidate) ? _identity->streak + 1 : 1;
    _identity->previous = candidate; _identity->hasPrevious = true;
    const bool accepted = _identity->streak >= 3;
    return CMRecoveryMetrics(*_identity, &candidate, start,
        accepted ? @"verified_original_identity" : @"confirming_original_identity", accepted, true);
}
@end

#include "CMPhysicalObjectPhotoReference.inc"
