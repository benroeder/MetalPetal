#import <Foundation/Foundation.h>
#import "MetalPetal.h"

NS_ASSUME_NONNULL_BEGIN

/// A promise whose resolution throws a C++ `std::out_of_range`.
///
/// Exists so the render graph's exception guard can be tested for the
/// thing it is actually for: a C++ exception thrown deep inside
/// resolution must not unwind into the caller. It cannot be written in
/// Swift — Swift cannot throw a C++ exception — so it lives in its own
/// ObjC++ target.
@interface MTIThrowingTestPromise : NSObject <MTIImagePromise>

/// Throws immediately, with no dependencies: the shallowest case.
- (instancetype)init;

/// Throws only AFTER `dependencies` have been resolved, so the throw
/// unwinds through a partially-built graph — past resolved render
/// targets, ObjC (.m) kernel frames and any open command encoder. That
/// is the shape the field crash had, and the shallow case cannot
/// exercise it.
- (instancetype)initWithDependencies:(NSArray<MTIImage *> *)dependencies;

@end

NS_ASSUME_NONNULL_END
