#import "CMNanoTrackTracker.h"
#include <opencv2/dnn.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <memory>

namespace {
// Fixed first-frame NanoTrack V2 template, local search and head decoding from
// gimbal_android 9c722f1 MovingObjectEngine.kt. The caller verifies identity.
struct Box { float x, y, w, h; };

bool validRect(CGRect r) {
    return std::isfinite(r.origin.x) && std::isfinite(r.origin.y) && std::isfinite(r.size.width) &&
        std::isfinite(r.size.height) && r.size.width > 0 && r.size.height > 0 &&
        CGRectGetMinX(r) >= -1e-6 && CGRectGetMinY(r) >= -1e-6 &&
        CGRectGetMaxX(r) <= 1.000001 && CGRectGetMaxY(r) <= 1.000001;
}
float contextSide(float w, float h) {
    const float pad = .5f*(w+h);
    return std::sqrt((w+pad)*(h+pad));
}
Box pixelBox(CGRect r, cv::Size size) {
    return {float(CGRectGetMidX(r)*size.width), float((1-CGRectGetMidY(r))*size.height),
            float(r.size.width*size.width), float(r.size.height*size.height)};
}

// Resize before color conversion so a 4K camera does not allocate a 4K float tensor.
cv::Mat analysisBGR(CVPixelBufferRef pixels) {
    if (CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return {};
    struct Unlock {
        CVPixelBufferRef pixels;
        ~Unlock() { CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly); }
    } lock{pixels};
    const int w = int(CVPixelBufferGetWidth(pixels)), h = int(CVPixelBufferGetHeight(pixels));
    if (w < 2 || h < 2) return {};
    const double s = std::min(1.,640./std::max(w,h));
    const cv::Size size(std::max(2,2*cvRound(w*s/2)),std::max(2,2*cvRound(h*s/2)));
    cv::Mat bgr;
    const auto format = CVPixelBufferGetPixelFormatType(pixels);
    if (format == kCVPixelFormatType_32BGRA) {
        cv::Mat src(h,w,CV_8UC4,CVPixelBufferGetBaseAddress(pixels),CVPixelBufferGetBytesPerRow(pixels)), small;
        if (size == src.size()) small = src; else cv::resize(src,small,size,0,0,cv::INTER_AREA);
        cv::cvtColor(small,bgr,cv::COLOR_BGRA2BGR);
    } else if ((format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) && CVPixelBufferGetPlaneCount(pixels) == 2) {
        cv::Mat y(h,w,CV_8U,CVPixelBufferGetBaseAddressOfPlane(pixels,0),CVPixelBufferGetBytesPerRowOfPlane(pixels,0));
        cv::Mat uv(int(CVPixelBufferGetHeightOfPlane(pixels,1)),int(CVPixelBufferGetWidthOfPlane(pixels,1)),CV_8UC2,
                   CVPixelBufferGetBaseAddressOfPlane(pixels,1),CVPixelBufferGetBytesPerRowOfPlane(pixels,1));
        cv::Mat luma, chroma;
        cv::resize(y,luma,size,0,0,cv::INTER_AREA);
        cv::resize(uv,chroma,size/2,0,0,cv::INTER_AREA);
        if (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            luma.convertTo(luma,CV_8U,219./255,16);
            chroma.convertTo(chroma,CV_8U,224./255,128.-128.*224./255);
        }
        cv::cvtColorTwoPlane(luma,chroma,bgr,cv::COLOR_YUV2BGR_NV12);
    }
    return bgr;
}

struct Localizer {
    cv::dnn::Net search, head;
    cv::Mat features, patch, resized, input;
    cv::Size imageSize;
    cv::Scalar padding;
    Box box{};
    std::array<float,256> hann{};
    float confidence = 0;

    static cv::dnn::Net load(NSString *name) {
        NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"onnx" inDirectory:@"NanoTrack"];
        if (!path) return {};
        auto net = cv::dnn::readNetFromONNX(path.fileSystemRepresentation);
        net.setPreferableBackend(cv::dnn::DNN_BACKEND_OPENCV);
        net.setPreferableTarget(cv::dnn::DNN_TARGET_CPU);
        return net;
    }
    void crop(const cv::Mat &image, int side, int out) {
        const int x = int(std::floor(box.x-(side+1)*.5f+.5f)), y = int(std::floor(box.y-(side+1)*.5f+.5f));
        const cv::Rect region(x,y,side,side), inside = region & cv::Rect({},image.size());
        patch.create(side,side,CV_8UC3);
        patch.setTo(padding);
        if (!inside.empty()) image(inside).copyTo(patch(cv::Rect(inside.x-x,inside.y-y,inside.width,inside.height)));
        cv::resize(patch,resized,{out,out},0,0,cv::INTER_LINEAR_EXACT);
        cv::dnn::blobFromImage(resized,input,1,{},cv::Scalar(),false,false,CV_32F);
    }
    bool seed(const cv::Mat &image, CGRect rect) {
        if (image.empty() || !validRect(rect)) return false;
        imageSize = image.size();
        box = pixelBox(rect,imageSize);
        box.x -= .5f; box.y -= .5f;
        if (std::min(box.w,box.h) < 2) return false;
        auto tmpl = load(@"template");
        search = load(@"search"); head = load(@"head");
        if (tmpl.empty() || search.empty() || head.empty()) return false;
        padding = cv::mean(image);
        for (int c=0;c<3;++c) padding[c]=std::floor(padding[c]);
        crop(image,std::max(2,int(std::round(contextSide(box.w,box.h)))),127);
        tmpl.setInput(input);
        features = tmpl.forward("output").clone();
        if (features.total() != 3072 || !cv::checkRange(features)) return false;
        for (int i=0;i<256;++i) hann[i] = .25*(1-std::cos(2*CV_PI*(i%16)/15))*(1-std::cos(2*CV_PI*(i/16)/15));
        return true;
    }
    CGRect propose(const cv::Mat &image) {
        confidence = 0;
        if (image.empty() || image.size()!=imageSize) return CGRectNull;
        const int side = std::max(2,int(std::round(contextSide(box.w,box.h)*255/127)));
        const float scale = 255.f/side;
        crop(image,side,255);
        search.setInput(input);
        cv::Mat local = search.forward("output");
        if (local.total()!=12288) return CGRectNull;
        head.setInput(features,"input1"); head.setInput(local,"input2");
        std::vector<cv::Mat> maps;
        head.forward(maps,std::vector<cv::String>{"output1","output2"});
        if (maps.size()!=2 || maps[0].total()!=512 || maps[1].total()!=1024 ||
            !cv::checkRange(maps[0]) || !cv::checkRange(maps[1])) return CGRectNull;
        const float *cls=maps[0].ptr<float>(), *reg=maps[1].ptr<float>();
        float best = -1; Box candidate{};
        auto change = [](float v) { return std::max(v,1.f/v); };
        for (int i=0;i<256;++i) {
            const float l=reg[i], t=reg[i+256], r=reg[i+512], b=reg[i+768], w=l+r, h=t+b;
            if (std::min({l,t,r,b})<0 || w<=0 || h<=0) continue;
            const float p = 1.f/(1.f+std::exp(cls[i]-cls[i+256]));
            const float penalty = std::exp(-.150f*(change(contextSide(w,h)/contextSide(box.w*scale,box.h*scale))*
                                                   change((box.w/box.h)/(w/h))-1));
            const float rank = penalty*p*.510f+hann[i]*.490f;
            if (rank<=best) continue;
            best=rank; confidence=p;
            const float lr=penalty*p*.385f;
            candidate={box.x+(-128+(i%16)*16+(r-l)/2)/scale,box.y+(-128+(i/16)*16+(b-t)/2)/scale,
                       box.w*(1-lr)+w/scale*lr,box.h*(1-lr)+h/scale*lr};
        }
        if (best < 0 || confidence<.8f || candidate.w<2 || candidate.h<2 ||
            candidate.w>imageSize.width || candidate.h>imageSize.height) return CGRectNull;
        const CGRect result = CGRectMake((candidate.x-candidate.w/2)/imageSize.width,
            1.-(candidate.y+candidate.h/2)/imageSize.height,candidate.w/imageSize.width,candidate.h/imageSize.height);
        return validRect(result) ? result : CGRectNull;
    }
};
#include "CMNanoTrackAppearance.inc"
}

@implementation CMNanoTrackTracker {
    Localizer _localizer;
    std::unique_ptr<MovingAppearance> _appearance;
    NSDictionary<NSString *,id> *_movingInitializationDiagnostics;
}
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection {
    if (!(self = [super init])) return nil;
    _movingInitializationDiagnostics=@{@"attempted": @NO, @"accepted": @NO, @"reason": @"not_attempted"};
    try { if (!_localizer.seed(analysisBGR(pixels),selection)) return nil; }
    catch (const cv::Exception &) { return nil; }
    return self;
}
- (CGRect)candidateInPixelBuffer:(CVPixelBufferRef)pixels {
    return [self candidateInPixelBuffer:pixels advanceSearch:NO];
}
- (CGRect)candidateInPixelBuffer:(CVPixelBufferRef)pixels advanceSearch:(BOOL)advanceSearch {
    try {
        const auto proposal=_localizer.propose(analysisBGR(pixels));
        if (advanceSearch && !CGRectIsNull(proposal)) _localizer.box=pixelBox(proposal,_localizer.imageSize);
        return proposal;
    } catch (const cv::Exception &) { _localizer.confidence=0; return CGRectNull; }
}
- (BOOL)enableIndependentTrackingWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection {
    // Store evidence from the actual capture buffer. JPEG replay can cross an
    // appearance boundary after resizing/compression and must not stand in for it.
    auto number=[](double value) -> id { return std::isfinite(value) ? @(value) : NSNull.null; };
    NSMutableDictionary *diagnostics=[@{@"attempted": @YES, @"accepted": @NO,
        @"reason": @"empty_analysis_image",
        @"seed_bbox": @[number(selection.origin.x),number(selection.origin.y),number(selection.size.width),number(selection.size.height)],
        @"source_width": @(CVPixelBufferGetWidth(pixels)), @"source_height": @(CVPixelBufferGetHeight(pixels)),
        @"source_pixel_format": @(CVPixelBufferGetPixelFormatType(pixels))} mutableCopy];
    try {
        const auto image=analysisBGR(pixels);
        diagnostics[@"analysis_width"]=@(image.cols);
        diagnostics[@"analysis_height"]=@(image.rows);
        if (image.empty()) { _movingInitializationDiagnostics=[diagnostics copy]; return NO; }
        auto appearance=std::make_unique<MovingAppearance>();
        const bool accepted=appearance->initialize(image,selection);
        const auto &view=appearance->original;
        diagnostics[@"accepted"]=@(accepted);
        diagnostics[@"reason"]=[NSString stringWithUTF8String:appearance->initializationReason];
        diagnostics[@"appearance_mode"]=appearance->tonal ? @"tonal_print" : @"color_print";
        diagnostics[@"hue"]=@(appearance->hue);
        diagnostics[@"hue_support"]=@(appearance->initializationHueSupport);
        diagnostics[@"color_marks"]=@(appearance->initializationColorMarks);
        diagnostics[@"color_print_reversed"]=@(appearance->colorPrintReversed);
        diagnostics[@"weak_color_tonal_consensus"]=@(appearance->weakColorTonalConsensus);
        diagnostics[@"base_fraction"]=number(view.base);
        diagnostics[@"band_fraction"]=number(view.band);
        diagnostics[@"ink_count"]=@(view.inkCount);
        diagnostics[@"span"]=number(view.span);
        diagnostics[@"tile_count"]=@(view.tiles.size());
        diagnostics[@"bright_anchor_fraction"]=number(view.brightAnchor);
        diagnostics[@"anchor_floor"]=@(appearance->anchorFloor);
        diagnostics[@"horizontal"]=@(appearance->horizontal);
        diagnostics[@"reversed"]=@(appearance->reverse);
        _movingInitializationDiagnostics=[diagnostics copy];
        if (!accepted) return NO;
        _appearance=std::move(appearance);
        return YES;
    } catch (const cv::Exception &error) {
        diagnostics[@"reason"]=@"opencv_exception";
        diagnostics[@"opencv_error_code"]=@(error.code);
        _movingInitializationDiagnostics=[diagnostics copy];
        return NO;
    }
}

- (NSDictionary<NSString *,id> *)movingObservationInPixelBuffer:(CVPixelBufferRef)pixels
        searching:(BOOL)searching frameTime:(double)time {
    try {
        const auto image=analysisBGR(pixels);
        if (!_appearance || image.empty() || !std::isfinite(time)) return @{};
        _appearance->duplicateFixedMS=-1;
        _appearance->duplicateCandidateMS=-1;
        const auto proposal=_localizer.propose(image);
        const float score=_localizer.confidence;
        MovingAppearance::Result match;
        if (!CGRectIsNull(proposal)) {
            // The next local search follows the network even when print/identity
            // withholds motor output. The explicit selection's template stays frozen.
            _localizer.box=pixelBox(proposal,image.size());
            match=_appearance->measure(image,proposal,searching,time);
        }
        if (searching && CGRectIsNull(match.box) && !match.ambiguous) {
            // A distractor may have pulled the local search away. Probe the
            // center with the original template and the last measured scale.
            const Box previous=_localizer.box;
            _localizer.box=pixelBox(_appearance->lastVerifiedBox,image.size());
            _localizer.box.x=image.cols*.5f; _localizer.box.y=image.rows*.5f;
            const auto centered=_localizer.propose(image);
            _localizer.box=previous;
            if (!CGRectIsNull(centered)) match=_appearance->measure(image,centered,true,time);
        }
        NSMutableDictionary *out=[@{@"nano_score": @(score), @"detail_score": @(match.score),
            @"ambiguous": @(match.ambiguous)} mutableCopy];
        if (match.ambiguous) out[@"ambiguity_reason"]=[NSString stringWithUTF8String:_appearance->duplicateReason];
        if (_appearance->duplicateFixedMS>=0) {
            out[@"competitor_fixed_ms"]=@(_appearance->duplicateFixedMS);
            out[@"competitor_candidate_ms"]=@(_appearance->duplicateCandidateMS);
        }
        if (!CGRectIsNull(proposal)) out[@"nano_bbox"]=@[@(proposal.origin.x),@(proposal.origin.y),@(proposal.size.width),@(proposal.size.height)];
        if (!CGRectIsNull(match.box)) {
            const auto b=match.box;
            out[@"bbox"]=@[@(b.origin.x),@(b.origin.y),@(b.size.width),@(b.size.height)];
        }
        return out;
    } catch (const cv::Exception &) { return @{}; }
}
- (void)approveMovingFrameAt:(double)time { if (_appearance) _appearance->approve(time); }
- (nullable NSString *)movingAppearanceKind {
    if (!_appearance) return nil;
    return _appearance->tonal ? @"tonal_print" : @"color_print";
}
- (NSDictionary<NSString *,id> *)movingInitializationDiagnostics { return _movingInitializationDiagnostics; }
- (float)confidence { return _localizer.confidence; }
- (void)acceptVerifiedRect:(CGRect)rect {
    if (!validRect(rect)) return;
    _localizer.box=pixelBox(rect,_localizer.imageSize);
}
@end
