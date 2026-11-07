// Compiled by CMPhysicalObjectPatchTracker.mm so the existing target and bridge
// link the experiment. Images and rectangles below use top-left pixel coordinates.
namespace {
using PhotoClock = std::chrono::steady_clock;

static cv::Rect photoPixels(CGRect box, cv::Size size) {
    if (!std::isfinite(box.origin.x) || !std::isfinite(box.origin.y) ||
        !std::isfinite(box.size.width) || !std::isfinite(box.size.height) ||
        box.size.width <= 0 || box.size.height <= 0 ||
        CGRectGetMinX(box) < -1e-6 || CGRectGetMinY(box) < -1e-6 ||
        CGRectGetMaxX(box) > 1.000001 || CGRectGetMaxY(box) > 1.000001) return {};
    const int x = cvRound(CGRectGetMinX(box) * size.width);
    const int y = cvRound((1 - CGRectGetMaxY(box)) * size.height);
    return cv::Rect(x, y, cvRound(CGRectGetMaxX(box) * size.width) - x,
                    cvRound((1 - CGRectGetMinY(box)) * size.height) - y) & cv::Rect({}, size);
}

static bool samePhotoLocation(cv::Rect a, cv::Rect b) {
    const double common = (a & b).area();
    return common > 0 && common / (a.area() + b.area() - common) >= .40 &&
        std::abs((a.x + .5*a.width) - (b.x + .5*b.width)) < .4*std::min(a.width, b.width) &&
        std::abs((a.y + .5*a.height) - (b.y + .5*b.height)) < .4*std::min(a.height, b.height);
}

static double photoCorrelation(const cv::Mat &a, const cv::Mat &b) {
    cv::Mat score;
    cv::matchTemplate(a, b, score, cv::TM_CCOEFF_NORMED);
    return score.at<float>(0, 0);
}

struct PhotoMatch {
    cv::Rect box;
    double score;
    bool geometric = false;
};

#include "CMPhysicalObjectMotionLandmarks.inc"
NS_ASSUME_NONNULL_BEGIN

// A color that is present in the middle of the selected subject but uncommon
// just outside it helps veto a neighboring object with a similar overall hue.
// It can reject a local track; it can never locate or accept one by itself.
struct PhotoColorCue {
    using Histogram = std::array<double,180>;
    int hue = -1;
    double minimum = 0;

    static Histogram histogram(const cv::Mat &hsv, cv::Rect region, cv::Rect excluded = {}) {
        Histogram bins{};
        int samples = 0;
        for (int y = 0; y < 36; ++y) for (int x = 0; x < 36; ++x) {
            const cv::Point point(region.x + (2*x+1)*region.width/72, region.y + (2*y+1)*region.height/72);
            if (excluded.contains(point)) continue;
            ++samples;
            const auto color = hsv.at<cv::Vec3b>(point);
            if (color[1] >= 62 && color[2] >= 45) ++bins[color[0]];
        }
        for (auto &value : bins) value /= std::max(1,samples);
        return bins;
    }

    static double mass(const Histogram &bins, int center) {
        double total = 0;
        for (int offset = -6; offset <= 6; ++offset) total += bins[(180+center+offset)%180];
        return total;
    }

    static cv::Rect core(cv::Rect box) {
        const int dx = box.width * .15, dy = box.height * .12;
        return {box.x+dx,box.y+dy,box.width-2*dx,box.height-2*dy};
    }

    void learn(const cv::Mat &hsv, cv::Rect box) {
        if (hsv.empty()) return;
        const int dx = std::max(2,cvRound(.4*box.width)), dy = std::max(2,cvRound(.4*box.height));
        const auto outer = cv::Rect(box.x-dx,box.y-dy,box.width+2*dx,box.height+2*dy) & cv::Rect({},hsv.size());
        if (outer.area() < 1.5 * box.area()) return;
        const auto inside = histogram(hsv,core(box));
        const auto outside = histogram(hsv,outer,box);
        double best = 3; // Only use a cue substantially enriched on the subject.
        for (int h = 0; h < 180; h += 3) {
            const double support = mass(inside,h);
            const double contrast = support / (.008 + mass(outside,h));
            if (support >= .04 && contrast > best) {
                best = contrast; hue = h; minimum = std::max(.012,.20*support);
            }
        }
    }

    bool agrees(CVPixelBufferRef pixels, CGRect normalized) const {
        if (hue < 0) return true;
        const cv::Size size((int)CVPixelBufferGetWidth(pixels),(int)CVPixelBufferGetHeight(pixels));
        auto box = photoPixels(CGRectIntersection(normalized,CGRectMake(0,0,1,1)),size);
        if (box.width < 4 || box.height < 4 || CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
            return false;
        bool pass = false;
        try {
            cv::Mat bgr, small, hsv;
            if (CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA) {
                cv::Mat src(size,CV_8UC4,CVPixelBufferGetBaseAddress(pixels),CVPixelBufferGetBytesPerRow(pixels));
                cv::resize(src(box),small,{48,48},0,0,cv::INTER_AREA);
                cv::cvtColor(small,bgr,cv::COLOR_BGRA2BGR);
            } else if (CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                       CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                // Sample only this ROI. Full-size NV12 conversion on every
                // local observation would defeat the cheap continuity route.
                box.x &= ~1; box.y &= ~1; box.width &= ~1; box.height &= ~1;
                cv::Mat y(size,CV_8U,CVPixelBufferGetBaseAddressOfPlane(pixels,0),CVPixelBufferGetBytesPerRowOfPlane(pixels,0));
                cv::Mat uv((int)CVPixelBufferGetHeightOfPlane(pixels,1),(int)CVPixelBufferGetWidthOfPlane(pixels,1),
                    CV_8UC2,CVPixelBufferGetBaseAddressOfPlane(pixels,1),CVPixelBufferGetBytesPerRowOfPlane(pixels,1));
                cv::Mat chroma;
                cv::resize(y(box),small,{48,48},0,0,cv::INTER_AREA);
                cv::resize(uv(cv::Rect(box.x/2,box.y/2,box.width/2,box.height/2)),chroma,{24,24},0,0,cv::INTER_AREA);
                cv::cvtColorTwoPlane(small,chroma,bgr,cv::COLOR_YUV2BGR_NV12);
            }
            if (!bgr.empty()) {
                cv::cvtColor(bgr,hsv,cv::COLOR_BGR2HSV);
                pass = mass(histogram(hsv,core(cv::Rect({},hsv.size()))),hue) >= minimum;
            }
        } catch (const cv::Exception &) { pass = false; }
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
        return pass;
    }
};

struct PhotoReference {
    // Only initialize() writes these identity fields. The camera buffers can be
    // reused immediately. No pixel from a measured frame enters the template.
    cv::Mat crop, detail, color;
    PhotoColorCue colorCue;
    CMPhotoMotionLandmarks movingLandmarks;
    // A single view, extracted from the same photo. Never add trusted views
    // here: later frames may localize this identity but cannot teach a new one.
    std::unique_ptr<CMCanonicalRecovery> geometry;
    cv::Size imageSize;
    cv::Rect lastBox, pendingBox;
    bool searching = false;
    int confirmations = 0;
    double lastToken = -INFINITY;
    double firstVoteToken = -INFINITY;

    void beginSearch() {
        searching = true;
        confirmations = 0;
        firstVoteToken = -INFINITY;
        pendingBox = {};
    }

    static bool hasTexture(const cv::Mat &image) {
        cv::Scalar mean, deviation;
        cv::meanStdDev(image, mean, deviation);
        return deviation[0] >= 8;
    }

    bool initialize(CVPixelBufferRef pixels, CGRect selection) {
        const cv::Mat gray = CMTrackingGray(pixels);
        if (gray.empty()) return false;
        imageSize = gray.size();
        lastBox = photoPixels(selection, imageSize);
        if (lastBox.width < 16 || lastBox.height < 16) return false;
        crop = gray(lastBox).clone();
        cv::resize(crop, detail, {40,40}, 0, 0, cv::INTER_AREA);
        // If all useful contrast is outside the centre, the visible background
        // alone would be able to authorize a match after the item was removed.
        if (!hasTexture(detail) || !hasTexture(detail(cv::Rect(7,7,26,26)))) return false;
        const cv::Mat hsv = CMTrackingHSV(pixels, imageSize);
        colorCue.learn(hsv,lastBox);
        movingLandmarks.learn(gray,hsv,lastBox);
        if (!hsv.empty()) {
            cv::resize(hsv(lastBox), color, {12,12}, 0, 0, cv::INTER_NEAREST);
            int chromatic = 0;
            for (const auto &v : cv::Mat_<cv::Vec3b>(color)) chromatic += v[1] >= 65 && v[2] >= 40;
            if (chromatic < 15) color.release();
        }
        if (!color.empty()) {
            auto identity = std::make_unique<CMCanonicalRecovery>();
            CMRecoveryFrame seed;
            seed.gray = gray; seed.hsv = hsv;
            if (identity->describe(seed) && identity->initialize(seed, selection))
                geometry = std::move(identity);
        }
        return true;
    }

    bool colorMatches(const cv::Mat &hsv, cv::Rect box) const {
        if (color.empty()) return true;
        if (hsv.empty()) return false;
        cv::Mat candidate;
        cv::resize(hsv(box), candidate, color.size(), 0, 0, cv::INTER_NEAREST);
        int agreed = 0, compared = 0;
        for (int y = 0; y < color.rows; ++y) for (int x = 0; x < color.cols; ++x) {
            const auto original = color.at<cv::Vec3b>(y,x);
            if (original[1] < 65 || original[2] < 40) continue;
            const auto sample = candidate.at<cv::Vec3b>(y,x);
            const int hue = std::abs(original[0] - sample[0]);
            ++compared;
            agreed += std::min(hue,180-hue) <= 15 && sample[1] >= 35 && sample[2] >= 25;
        }
        return agreed >= .66*compared;
    }

    double verify(const cv::Mat &gray, const cv::Mat &hsv, cv::Rect box) const {
        cv::Mat sample;
        cv::resize(gray(box), sample, detail.size(), 0, 0, cv::INTER_AREA);
        const cv::Rect center(7,7,26,26);
        if (!hasTexture(sample(center))) return 0;
        const double whole = photoCorrelation(sample, detail);
        const double core = photoCorrelation(sample(center), detail(center));
        if (whole < .68 || core < .65 || !colorMatches(hsv, box)) return 0;
        return std::min(whole, .4*whole + .6*core);
    }

    static NSDictionary *reject(NSString *reason) {
        return @{@"accepted": @NO, @"recovered_original_template": @NO, @"quality": @0, @"reason": reason};
    }

    NSDictionary *accept(PhotoMatch match, bool recovered) {
        lastBox = match.box;
        searching = false;
        confirmations = 0;
        NSMutableDictionary *result = [@{@"accepted": @YES, @"recovered_original_template": @(recovered), @"quality": @(match.score),
            @"reason": recovered ? @"recovered_photo" : @"tracking_photo",
            @"photo_evidence": match.geometric ? @"original_features_color" : @"original_patch",
            @"bbox": @[@(double(lastBox.x)/imageSize.width),
                       @(1.-double(lastBox.y+lastBox.height)/imageSize.height),
                       @(double(lastBox.width)/imageSize.width), @(double(lastBox.height)/imageSize.height)]} mutableCopy];
        if (recovered) result[@"confirmation_started_at"] = @(firstVoteToken);
        return result;
    }

    // Bound work across the entire multiscale scan, not separately per scale:
    // repetitive backgrounds can produce many cheap luma peaks at one scale.
    // A partial scan can never authorize a patch match.
    NSDictionary *measure(CVPixelBufferRef pixels, CGRect proposal, float confidence, double token, bool allowSearchProposal = false) {
        if (!std::isfinite(token) || token <= lastToken) {
            beginSearch();
            return reject(@"non_monotonic_frame");
        }
        if (std::isfinite(lastToken) && token-lastToken > .40) beginSearch();
        lastToken = token;
        const auto started = PhotoClock::now();
        const auto budget = std::chrono::milliseconds(searching ? 80 : 45);
        auto timedOut = [&] { return PhotoClock::now() - started > budget; };
        auto lost = [&](NSString *reason) { beginSearch(); return reject(reason); };
        const cv::Mat gray = CMTrackingGray(pixels);
        if (gray.empty() || gray.size() != imageSize) return lost(@"image_geometry");
        const cv::Mat hsv = color.empty() ? cv::Mat() : CMTrackingHSV(pixels, imageSize);
        if (!color.empty() && hsv.empty()) return lost(@"no_color_sample");

        const double down = std::min(1., 352. / std::max(gray.cols, gray.rows));
        cv::Mat coarse;
        cv::resize(gray, coarse, {}, down, down, cv::INTER_AREA);
        const double sx = double(coarse.cols)/gray.cols, sy = double(coarse.rows)/gray.rows;
        const cv::Rect imageBounds({}, imageSize);
        cv::Rect window = imageBounds;
        std::vector<double> scales;
        const double lastScale = double(lastBox.width)/crop.cols;
        std::vector<PhotoMatch> matches;
        auto consider = [&](cv::Rect box) {
            if (box.width < 12 || box.height < 12 || (box & imageBounds) != box) return;
            const double score = verify(gray,hsv,box);
            if (score >= .68) matches.push_back({box,score});
        };
        if (searching) {
            scales = {.50,.63,.79,.89,1.,1.12,1.26,1.59,2.,lastScale};
        } else {
            const int dx = std::max(12,cvRound(lastBox.width*.58));
            const int dy = std::max(12,cvRound(lastBox.height*.58));
            window = cv::Rect(lastBox.x-dx,lastBox.y-dy,lastBox.width+2*dx,lastBox.height+2*dy) & imageBounds;
            scales = {lastScale*.86,lastScale,lastScale*1.16};
        }
        // A fresh independent NanoTrack hint may locate the original photo
        // after local identity confirmation is lost. It cannot bypass verify,
        // the full-scene competitor scan, its budget, or recovery confirmation.
        if (!searching || allowSearchProposal) {
            const cv::Rect hint = photoPixels(proposal,imageSize);
            if (std::isfinite(confidence) && confidence >= .35 && !hint.empty() && (hint & window) == hint) {
                const double scale = double(hint.width)/crop.cols;
                const double ratio = (double(hint.width)/hint.height)/(double(crop.cols)/crop.rows);
                if (ratio >= .82 && ratio <= 1.22 && scale >= lastScale*.75 && scale <= lastScale*1.33) {
                    consider(hint);
                    scales.push_back(scale);
                }
            }
        }
        const cv::Rect area(cv::Point(cvRound(window.x*sx),cvRound(window.y*sy)),
                            cv::Point(cvRound((window.x+window.width)*sx),cvRound((window.y+window.height)*sy)));
        std::vector<cv::Size> examined;
        int examinedPeaks = 0;
        bool patchScanComplete = true;
        for (double scale : scales) {
            if (timedOut()) return lost(@"photo_budget_exceeded");
            const cv::Size size(cvRound(crop.cols*scale*sx),cvRound(crop.rows*scale*sy));
            if (size.width < 8 || size.height < 8 || size.width > area.width || size.height > area.height ||
                std::find(examined.begin(),examined.end(),size) != examined.end()) continue;
            examined.push_back(size);
            cv::Mat pattern, scores;
            cv::resize(crop,pattern,size,0,0,cv::INTER_AREA);
            if (!hasTexture(pattern)) continue;
            cv::matchTemplate(coarse(area),pattern,scores,cv::TM_CCOEFF_NORMED);
            for (;;) {
                if (timedOut()) return lost(@"photo_budget_exceeded");
                double peak = 0;
                cv::Point point;
                cv::minMaxLoc(scores,nullptr,&peak,nullptr,&point);
                if (!std::isfinite(peak) || peak < .65) break;
                if (++examinedPeaks > 64) { patchScanComplete = false; break; }
                const int left = cvRound((area.x+point.x)/sx), top = cvRound((area.y+point.y)/sy);
                consider(cv::Rect(cv::Point(left,top),cv::Point(cvRound((area.x+point.x+size.width)/sx),
                                                               cvRound((area.y+point.y+size.height)/sy))));
                const int rx = std::max(1,cvRound(size.width*.30)), ry = std::max(1,cvRound(size.height*.30));
                scores(cv::Rect(point.x-rx,point.y-ry,2*rx+1,2*ry+1) & cv::Rect({},scores.size())).setTo(-1);
            }
            if (!patchScanComplete) break;
        }
        if (timedOut()) return lost(@"photo_budget_exceeded");
        const auto strongest = std::max_element(matches.begin(),matches.end(),
            [](const PhotoMatch &a, const PhotoMatch &b) { return a.score < b.score; });
        PhotoMatch best{{},0};
        if (patchScanComplete && strongest != matches.end() && strongest->score >= (searching ? .90 : .76)) {
            best = *strongest;
            for (const auto &other : matches)
                if (!samePhotoLocation(best.box,other.box) && best.score-other.score < .075)
                    return lost(@"ambiguous_photo_match");
        } else {
            // Rotation or partial cover can break full-crop correlation. Only
            // accept geometry from original colored keypoints after the full
            // scene competitor check. A partial patch scan is not evidence for
            // accepting a location; any conflicting verified patch vetoes it.
            if (!geometry) return lost(!patchScanComplete ? @"too_many_photo_peaks" :
                                       (matches.empty() ? @"no_photo_match" : @"weak_photo_match"));
            CMRecoveryFrame current;
            current.gray = gray; current.hsv = hsv;
            CMRecoveryCandidate candidate;
            geometry->resetOperationMetrics();
            if (!geometry->describe(current) || !geometry->find(current,started,candidate) ||
                !geometry->competitorCheckComplete || !CMCanonicalRecovery::withinBudget(started))
                return lost(!CMCanonicalRecovery::withinBudget(started) ? @"photo_budget_exceeded" :
                    (geometry->clusterCount > 1 ? @"ambiguous_photo_features" : @"no_verified_photo_features"));
            best = {cv::Rect(candidate.rect), .95, true};
            if (best.box.empty() || (best.box & imageBounds) != best.box) return lost(@"incomplete_photo_geometry");
            for (const auto &other : matches)
                if (other.score >= .80 && !samePhotoLocation(best.box,other.box)) return lost(@"conflicting_photo_evidence");
            // A geometric match outside the current track is a new return,
            // even if the local patch failed for the first time on this frame.
            if (!searching && !samePhotoLocation(best.box,lastBox)) beginSearch();
        }
        if (!searching) return accept(best,false);
        if (confirmations && samePhotoLocation(best.box,pendingBox)) {
            ++confirmations;
        } else {
            confirmations = 1;
            firstVoteToken = token;
        }
        pendingBox = best.box;
        if (confirmations < 3) return reject(@"confirming_photo");
        return accept(best,true);
    }
};
}

@implementation CMPhysicalObjectPhotoReference {
    std::unique_ptr<PhotoReference> _photo;
}
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection {
    if (!(self = [super init])) return nil;
    _photo = std::make_unique<PhotoReference>();
    try {
        if (!_photo->initialize(pixels, selection)) return nil;
    } catch (const cv::Exception &) { return nil; }
    return self;
}
- (CGRect)landmarkSeedRect { return _photo->movingLandmarks.seedRect(); }
- (void)beginSearch { _photo->beginSearch(); }
- (BOOL)matchesColorCueInPixelBuffer:(CVPixelBufferRef)pixels rect:(CGRect)rect {
    return _photo->colorCue.agrees(pixels,rect);
}
- (nullable NSDictionary<NSString *,id> *)movingPartsInPixelBuffer:(CVPixelBufferRef)pixels {
    if (!_photo->movingLandmarks.available()) return nil;
    try {
        const auto gray = CMTrackingGray(pixels);
        if (gray.empty()) return nil;
        const auto hsv = CMTrackingHSV(pixels,gray.size());
        CMPhotoMotionLandmarks::Match proposal;
        const auto outcome = _photo->movingLandmarks.find(gray,hsv,proposal);
        if (outcome == CMPhotoMotionLandmarks::Outcome::ambiguous) return @{@"ambiguous": @YES};
        if (outcome != CMPhotoMotionLandmarks::Outcome::unique) return nil;
        const auto &b = proposal.box;
        return @{@"score": @(proposal.score), @"bbox": @[@(double(b.x)/gray.cols),
            @(1.-double(b.y+b.height)/gray.rows), @(double(b.width)/gray.cols), @(double(b.height)/gray.rows)]};
    } catch (const cv::Exception &) { return nil; }
}
- (NSDictionary<NSString *,id> *)measurePixelBuffer:(CVPixelBufferRef)pixels proposal:(CGRect)proposal
                                         confidence:(float)confidence frameToken:(double)frameToken {
    return [self measurePixelBuffer:pixels proposal:proposal confidence:confidence frameToken:frameToken allowSearchProposal:NO];
}
- (NSDictionary<NSString *,id> *)measurePixelBuffer:(CVPixelBufferRef)pixels proposal:(CGRect)proposal
                                         confidence:(float)confidence frameToken:(double)frameToken
                                allowSearchProposal:(BOOL)allowSearchProposal {
    try { return _photo->measure(pixels,proposal,confidence,frameToken,allowSearchProposal); }
    catch (const cv::Exception &) {
        _photo->beginSearch();
        return PhotoReference::reject(@"photo_opencv_error");
    }
}
@end
NS_ASSUME_NONNULL_END
