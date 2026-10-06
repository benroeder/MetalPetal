//
//  MTIImageRenderingContext+Internal.h
//  MetalPetal
//
//  Created by Yu Ao on 2020/1/20.
//

#if __has_include(<MetalPetal/MetalPetal.h>)
#import <MetalPetal/MTIImageRenderingContext.h>
#else
#import "MTIImageRenderingContext.h"
#endif

NS_ASSUME_NONNULL_BEGIN

@protocol MTIImagePromiseResolution <NSObject>

@property (nonatomic,readonly) id<MTLTexture> texture;

- (void)markAsConsumedBy:(id)consumer;

@end

@interface MTIImageRenderingContext (Internal)

- (instancetype)initWithContext:(MTIContext *)context;

- (nullable id<MTIImagePromiseResolution>)resolutionForImage:(MTIImage *)image error:(NSError **)error;

/// As `resolutionForImage:error:` but WITHOUT the C++ exception guard.
/// For the recursive descent only, which runs inside the guarded
/// outermost call — paying a try/catch per graph node buys nothing.
- (nullable id<MTIImagePromiseResolution>)unguardedResolutionForImage:(MTIImage *)image error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
