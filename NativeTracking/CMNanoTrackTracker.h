#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// One explicit selection, owned by the capture queue. Rectangles use Vision coordinates.
@interface CMNanoTrackTracker : NSObject
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection;
/// A proposal never changes the template or the search center. CGRectNull means no current match.
- (CGRect)candidateInPixelBuffer:(CVPixelBufferRef)pixels NS_SWIFT_NAME(candidate(in:));
/// Optionally advance only the private search center. A candidate still carries
/// no identity or motor authority, and never updates the original template.
- (CGRect)candidateInPixelBuffer:(CVPixelBufferRef)pixels advanceSearch:(BOOL)advanceSearch
    NS_SWIFT_NAME(candidate(in:advanceSearch:));
- (void)acceptVerifiedRect:(CGRect)rect;
/// Enables independent localization for a selection with identifiable print
/// and a second, separated foreground color region.
- (BOOL)enableIndependentTrackingWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection
    NS_SWIFT_NAME(enableIndependentTracking(_:selection:));
- (NSDictionary<NSString *,id> *)movingObservationInPixelBuffer:(CVPixelBufferRef)pixels
    searching:(BOOL)searching frameTime:(double)time NS_SWIFT_NAME(movingObservation(_:searching:frameTime:));
/// Only a fresh, motion-eligible decision from the active selection may approve its view.
- (void)approveMovingFrameAt:(double)time NS_SWIFT_NAME(approveMovingFrame(at:));
@property(nonatomic, readonly, nullable) NSString *movingAppearanceKind;
/// Exact capture-buffer initialization evidence, retained even when appearance eligibility fails.
@property(nonatomic, readonly) NSDictionary<NSString *,id> *movingInitializationDiagnostics;
@property(nonatomic, readonly) float confidence;
@end
NS_ASSUME_NONNULL_END
