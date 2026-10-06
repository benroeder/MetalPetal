#import "MTIThrowingTestPromise.h"

#include <stdexcept>

@implementation MTIThrowingTestPromise {
    NSArray<MTIImage *> *_dependencies;
}

- (instancetype)init {
    return [self initWithDependencies:@[]];
}

- (instancetype)initWithDependencies:(NSArray<MTIImage *> *)dependencies {
    if (self = [super init]) {
        _dependencies = [dependencies copy];
    }
    return self;
}

- (MTITextureDimensions)dimensions {
    return MTITextureDimensionsMake2DFromCGSize(CGSizeMake(16, 16));
}

- (NSArray<MTIImage *> *)dependencies {
    return _dependencies;
}

- (MTIAlphaType)alphaType {
    return MTIAlphaTypeAlphaIsOne;
}

- (MTIImagePromiseRenderTarget *)resolveWithContext:(MTIImageRenderingContext *)renderingContext
                                              error:(NSError **)error {
    //Exactly the exception the field crash reported: std::map::at() on a
    //promise that had left the dependency graph threw St12out_of_range,
    //and nothing caught it.
    throw std::out_of_range("deliberate throw from a test promise");
    return nil;
}

- (instancetype)promiseByUpdatingDependencies:(NSArray<MTIImage *> *)dependencies {
    return [[MTIThrowingTestPromise alloc] initWithDependencies:dependencies];
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (MTIImagePromiseDebugInfo *)debugInfo {
    return [[MTIImagePromiseDebugInfo alloc] initWithPromise:self type:MTIImagePromiseTypeSource content:@"throwing test promise"];
}

@end
