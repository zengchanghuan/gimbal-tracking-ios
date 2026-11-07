#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Capture-queue confined. User-selected texture with independently gated appearance updates.
@interface CMPhysicalObjectPatchTracker : NSObject
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection;
/// Only an already accepted ordinary texture may recover its frozen identity.
/// Color silhouettes and locked foreground features never fall back to texture.
@property(nonatomic, readonly) BOOL supportsCenterRecovery;
/// After a rejected normal observation, search the unchanged original texture.
/// Three distinct, strong, globally unique central observations are required.
/// Only a confirmed result has accepted=YES and recovered_original_template=YES.
- (NSDictionary<NSString *, id> *)recoverPixelBuffer:(CVPixelBufferRef)pixels NS_SWIFT_NAME(recoverPixelBuffer(_:));
/// During an independently verified parts bridge, advance a fresh observation
/// without running normal tracking or updating its frozen identity.
- (NSDictionary<NSString *, id> *)recoverFrozenPixelBuffer:(CVPixelBufferRef)pixels
                                               frameToken:(double)frameToken
    NS_SWIFT_NAME(recoverFrozenPixelBuffer(_:frameToken:));
/// Break confirmation when a bridge frame does not search the frozen identity.
/// Preserves the frozen template and its learned-state counters.
- (void)resetFrozenRecoveryConfirmation;
/// Fixed-template route retained for controlled replay comparisons.
- (NSDictionary<NSString *, id> *)trackPixelBuffer:(CVPixelBufferRef)pixels;
/// Independent Vision observations may authorize appearance refresh and seed
/// local features. After verified foreground/background motion separation,
/// bidirectionally matched feature identities can measure the same target.
/// Missing foreground holds without reacquiring background or a new target.
- (NSDictionary<NSString *, id> *)trackPixelBuffer:(CVPixelBufferRef)pixels
                                  referenceRect:(CGRect)referenceRect
                            referenceConfidence:(float)referenceConfidence;
@end
/// Capture-queue confined, bounded original-identity memory for stopped search.
/// Initial explicit selection remains immutable; later views need independent
/// Safety-ready authorization and canonical feature/color verification.
@interface CMPhysicalObjectReacquirer : NSObject
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection;
@property(nonatomic, readonly) NSInteger templateCount;
/// Caller supplies only distinct, fresh frames after three strong ready frames.
/// The tracker rectangle is a cross-check; it cannot redefine original geometry.
- (NSDictionary<NSString *, id> *)addTrustedPixelBuffer:(CVPixelBufferRef)pixels
                                                 rect:(CGRect)rect
    NS_SWIFT_NAME(addTrustedPixelBuffer(_:rect:));
/// Search never learns. Only three distinct, consistent current image matches
/// set accepted and recovered_verified_identity; no center-of-screen restriction.
- (NSDictionary<NSString *, id> *)findPixelBuffer:(CVPixelBufferRef)pixels
                                           frameToken:(double)frameToken
    NS_SWIFT_NAME(findPixelBuffer(_:frameToken:));
/// Break confirmation after skipped/rejected/stale frames or a new search.
/// Leaves all immutable identity views and the monotonic token boundary intact.
- (void)resetSearchConfirmation;
@end
/// Capture-queue confined. The explicit selection owns the only reference photo.
@interface CMPhysicalObjectPhotoReference : NSObject
- (nullable instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixels selection:(CGRect)selection;
/// Unique subject area measured from the selection photo. CGRectNull if two original landmarks are unavailable.
@property(nonatomic, readonly) CGRect landmarkSeedRect;
/// Veto a proposed current box when an original target-specific hue is missing.
/// A positive result alone provides no position or identity evidence.
- (BOOL)matchesColorCueInPixelBuffer:(CVPixelBufferRef)pixels rect:(CGRect)rect
    NS_SWIFT_NAME(matchesColorCue(_:rect:));
/// Current-frame evidence from separated regions of the original photo.
/// The caller owns temporal confirmation and motor eligibility.
- (nullable NSDictionary<NSString *, id> *)movingPartsInPixelBuffer:(CVPixelBufferRef)pixels
    NS_SWIFT_NAME(movingParts(_:));
/// Keep the photo and timestamp boundary, restart full-frame confirmation.
- (void)beginSearch;
/// A proposal is a spatial hint in normalized Vision coordinates. Only a match
/// to the photo produces a box. Frame tokens are monotonic capture times in seconds.
- (NSDictionary<NSString *, id> *)measurePixelBuffer:(CVPixelBufferRef)pixels
                                           proposal:(CGRect)proposal
                                         confidence:(float)confidence
                                         frameToken:(double)frameToken
    NS_SWIFT_NAME(measure(_:proposal:confidence:frameToken:));
/// Permit a current independent localizer proposal during full-frame search.
/// The original photo verifier and complete competitor scan still decide acceptance.
- (NSDictionary<NSString *, id> *)measurePixelBuffer:(CVPixelBufferRef)pixels
                                           proposal:(CGRect)proposal
                                         confidence:(float)confidence
                                         frameToken:(double)frameToken
                                allowSearchProposal:(BOOL)allowSearchProposal
    NS_SWIFT_NAME(measure(_:proposal:confidence:frameToken:allowSearchProposal:));
@end
NS_ASSUME_NONNULL_END
